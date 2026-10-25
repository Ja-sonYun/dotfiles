use crate::state::{agent_label, now, Agent, Location, Report, Snapshot};
use anyhow::{bail, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;

#[derive(Clone, Deserialize)]
pub struct Settings {
    pub command: String,
    pub title: String,
    pub messages: BTreeMap<String, String>,
    pub summary_interval_seconds: u64,
}

struct Pending {
    due: u64,
    agent: String,
    kind: String,
    details: BTreeSet<String>,
    chat_detail: String,
}

pub struct Notice {
    pub notification: String,
    pub chat: String,
}

pub struct Alerts {
    settings: Option<Settings>,
    fresh_since: u64,
    pub version: u64,
    pending: BTreeMap<String, Pending>,
    completed_at: BTreeMap<String, u64>,
    deferred: BTreeMap<String, (Report, Option<Agent>, Agent)>,
    turns: BTreeMap<String, (Location, u64)>,
}

pub fn excerpt(text: &str) -> String {
    let text: String = text
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .filter(|character| !character.is_control())
        .collect();
    if text.chars().count() > 240 {
        format!("{}…", text.chars().take(239).collect::<String>())
    } else {
        text
    }
}

fn progress(agent: &Agent) -> Value {
    let mut value = serde_json::to_value(agent).unwrap();
    for field in ["last_seen", "last_hook", "last_report"] {
        value.as_object_mut().unwrap().remove(field);
    }
    for field in ["tasks", "steps"] {
        for item in value[field].as_object_mut().unwrap().values_mut() {
            if let Some(object) = item.as_object_mut() {
                object.remove("reported_at");
            }
        }
    }
    value
}

impl Alerts {
    pub fn new(settings: Option<Settings>, fresh_since: u64) -> Self {
        Self {
            settings,
            fresh_since,
            version: 0,
            pending: BTreeMap::new(),
            completed_at: BTreeMap::new(),
            deferred: BTreeMap::new(),
            turns: BTreeMap::new(),
        }
    }

    pub fn receive(&mut self, report: &Report, before: Option<&Agent>, after: &Agent, live: bool) {
        if self.turns.get(&after.id).is_some_and(|(location, _)| {
            location.scope != after.location.scope
                || location.process_id != after.location.process_id
                || location.process_started != after.location.process_started
        }) {
            self.turns.remove(&after.id);
        }
        if report.kind == "hook"
            && report.data["event"] == "UserPromptSubmit"
            && report.at >= after.last_hook
        {
            self.turns
                .insert(after.id.clone(), (after.location.clone(), report.at));
        }
        let before = before.filter(|agent| {
            agent.location.scope == after.location.scope
                && agent.location.process_id == after.location.process_id
                && agent.location.process_started == after.location.process_started
        });
        if live {
            let deferred = self.deferred.remove(&after.id);
            self.observe(
                report,
                match &deferred {
                    Some((_, before, _)) => before.as_ref(),
                    None => before,
                },
                after,
            );
        } else if self.settings.is_some() && after.location.process_id != 0 {
            if self
                .deferred
                .get(&after.id)
                .is_some_and(|(_, _, agent)| agent.location != after.location)
            {
                self.deferred.remove(&after.id);
            }
            let entry = self
                .deferred
                .entry(after.id.clone())
                .or_insert_with(|| (report.clone(), before.cloned(), after.clone()));
            entry.0 = report.clone();
            entry.2 = after.clone();
        }
    }

    pub fn observed(
        &mut self,
        sampled: &BTreeMap<String, Agent>,
        states: &Value,
        live: &BTreeSet<String>,
    ) {
        let ready: Vec<_> = self
            .deferred
            .iter()
            .filter(|(id, (_, _, after))| {
                sampled
                    .get(*id)
                    .is_some_and(|agent| agent.location == after.location)
                    && states[*id].is_boolean()
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in ready {
            let (report, before, after) = self.deferred.remove(&id).unwrap();
            if live.contains(&id) {
                self.observe(&report, before.as_ref(), &after);
            }
        }
    }

    pub fn observe(&mut self, report: &Report, before: Option<&Agent>, after: &Agent) {
        if self.settings.is_none()
            || report.at < self.fresh_since
            || before.is_some_and(|agent| progress(agent) == progress(after))
        {
            return;
        }
        self.version += 1;
        if report.kind == "hook" && report.data["event"] == "UserPromptSubmit" {
            self.completed_at.remove(&after.id);
        }
        let previous = before.map(|agent| agent.status.as_str()).unwrap_or("");
        let status = if previous != after.status {
            after.status.as_str()
        } else if before.and_then(|agent| agent.task_status.as_ref()) != after.task_status.as_ref()
            && after.task_status.as_deref() != Some(after.status.as_str())
        {
            after.task_status.as_deref().unwrap_or("")
        } else {
            ""
        };
        if matches!(status, "approval" | "waiting" | "error" | "cancelled") {
            self.pending.remove(&format!("{}:completion", after.id));
            self.queue(report, after, status, "", false);
        }
        if matches!(report.kind.as_str(), "report_task" | "report_step") {
            let previous_item = before.and_then(|agent| {
                if report.kind == "report_task" {
                    agent
                        .tasks
                        .get(report.data["task_id"].as_str().unwrap_or(""))
                } else {
                    agent.steps.get(&format!(
                        "{}:{}",
                        report.data["task_id"].as_str().unwrap_or(""),
                        report.data["step_id"].as_str().unwrap_or("")
                    ))
                }
            });
            if previous_item.is_none_or(|item| item["status"] != report.data["status"]) {
                let kind = match report.data["status"].as_str() {
                    Some("failed") => Some("error"),
                    Some("cancelled") => Some("cancelled"),
                    _ => None,
                };
                if let Some(kind) = kind {
                    self.pending.remove(&format!("{}:completion", after.id));
                    self.queue(
                        report,
                        after,
                        kind,
                        report.data["title"].as_str().unwrap_or(""),
                        false,
                    );
                }
            }
        }
        if report.kind == "hook"
            && report.data["event"] == "Stop"
            && after.status == "idle"
            && previous != "idle"
            && self
                .completed_at
                .get(&after.id)
                .is_none_or(|at| now().saturating_sub(*at) >= 5000)
        {
            self.queue(report, after, "turn_complete", "", true);
        }
        if report.kind == "report_task" && report.data["status"] == "completed" {
            let task = report.data["task_id"].as_str().unwrap_or("");
            if before
                .and_then(|agent| agent.tasks.get(task))
                .is_none_or(|task| task["status"] != "completed")
            {
                self.queue(
                    report,
                    after,
                    "task_completed",
                    report.data["title"].as_str().unwrap_or(""),
                    true,
                );
            }
        }
    }

    fn chat_detail(&self, report: &Report, agent: &Agent) -> String {
        let since = self.turns.get(&agent.id).map(|(_, at)| *at);
        let recent = |at: u64| since.is_some_and(|start| at >= start && at <= report.at);
        if let Some(title) = report.data["title"].as_str().filter(|title| {
            matches!(report.kind.as_str(), "report_task" | "report_step") && !title.is_empty()
        }) {
            let step = agent
                .steps
                .values()
                .filter(|step| {
                    step["task_id"] == report.data["task_id"]
                        && recent(step["reported_at"].as_u64().unwrap_or(0))
                })
                .max_by_key(|step| step["reported_at"].as_u64().unwrap_or(0))
                .and_then(|step| step["title"].as_str())
                .filter(|step| *step != title);
            return excerpt(&match step {
                Some(step) => format!("{title} — {step}"),
                None => title.into(),
            });
        }
        for field in ["response_excerpt", "summary"] {
            if let Some(text) = report.data[field]
                .as_str()
                .filter(|text| !text.trim().is_empty())
            {
                return excerpt(text);
            }
        }
        if recent(agent.summary_at) && !agent.summary.trim().is_empty() {
            return excerpt(&agent.summary);
        }
        agent
            .steps
            .values()
            .chain(agent.tasks.values())
            .filter(|item| recent(item["reported_at"].as_u64().unwrap_or(0)))
            .max_by_key(|item| item["reported_at"].as_u64().unwrap_or(0))
            .and_then(|item| {
                item["title"].as_str().map(|title| {
                    excerpt(&format!(
                        "{title} ({})",
                        item["status"].as_str().unwrap_or("unknown")
                    ))
                })
            })
            .unwrap_or_else(|| "Details unavailable".into())
    }

    fn queue(
        &mut self,
        report: &Report,
        agent: &Agent,
        kind: &str,
        detail: &str,
        completion: bool,
    ) {
        let chat_detail = self.chat_detail(report, agent);
        let key = format!(
            "{}:{}",
            agent.id,
            if completion { "completion" } else { kind }
        );
        let entry = self.pending.entry(key).or_insert_with(|| Pending {
            due: now() + if completion { 1000 } else { 0 },
            agent: agent_label(agent),
            kind: kind.into(),
            details: BTreeSet::new(),
            chat_detail: String::new(),
        });
        if entry.kind != "task_completed" || kind == "task_completed" {
            entry.chat_detail = chat_detail;
        }
        if kind == "task_completed" {
            entry.kind = kind.into();
        }
        if !detail.is_empty() {
            entry.details.insert(detail.to_string());
        }
    }

    pub fn due(&mut self) -> Vec<Notice> {
        let Some(settings) = &self.settings else {
            return Vec::new();
        };
        let keys: Vec<_> = self
            .pending
            .iter()
            .filter(|(_, item)| item.due <= now())
            .map(|(key, _)| key.clone())
            .collect();
        keys.into_iter()
            .map(|key| {
                let item = self.pending.remove(&key).unwrap();
                if let Some(agent) = key.strip_suffix(":completion") {
                    self.completed_at.insert(agent.to_string(), now());
                }
                let label = settings
                    .messages
                    .get(&item.kind)
                    .map(String::as_str)
                    .unwrap_or(&item.kind);
                let details = item.details.into_iter().collect::<Vec<_>>().join(", ");
                let notification = if details.is_empty() {
                    format!("{}: {label}", item.agent)
                } else {
                    format!("{}: {label} — {details}", item.agent)
                };
                Notice {
                    notification,
                    chat: format!("{}: {label}\n{}", item.agent, item.chat_detail),
                }
            })
            .collect()
    }
}

pub fn active(snapshot: &Snapshot) -> bool {
    snapshot.agents.values().any(|agent| {
        !agent.stale && matches!(agent.status.as_str(), "running" | "approval" | "waiting")
    })
}

pub async fn send(settings: &Settings, text: &str) -> Result<()> {
    if text.trim().is_empty() {
        bail!("Notification text must not be empty");
    }
    let text: String = text.chars().take(2000).collect();
    let mut child = Command::new(&settings.command)
        .arg(json!({"type":"desktop-notification", "title":settings.title, "message":text, "sound":"Frog"}).to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .kill_on_drop(true)
        .spawn()?;
    let group = child
        .id()
        .ok_or_else(|| anyhow::anyhow!("Notification process has no pid"))? as i32;
    let status = match tokio::time::timeout(Duration::from_secs(5), child.wait()).await {
        Ok(result) => result?,
        Err(error) => {
            unsafe {
                libc::kill(-group, libc::SIGTERM);
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
            if unsafe { libc::kill(-group, 0) } == 0 {
                unsafe {
                    libc::kill(-group, libc::SIGKILL);
                }
            }
            let _ = child.wait().await;
            return Err(error.into());
        }
    };
    if !status.success() {
        bail!("Desktop notification request failed: {status}");
    }
    Ok(())
}

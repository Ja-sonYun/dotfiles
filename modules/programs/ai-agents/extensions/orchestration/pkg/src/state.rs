use crate::lifecycle::{self, ReconcileRequest};
use anyhow::{bail, Context, Result};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[derive(Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct Location {
    #[serde(default)]
    pub socket: String,
    #[serde(default)]
    pub session: String,
    #[serde(default)]
    pub window: String,
    #[serde(default)]
    pub pane: String,
    #[serde(default)]
    pub server: String,
    #[serde(default)]
    pub scope: String,
    #[serde(default)]
    pub process_id: u32,
    #[serde(default)]
    pub process_started: String,
}

#[derive(Clone, Default, Deserialize, Serialize, PartialEq)]
pub struct Agent {
    pub id: String,
    pub session_id: String,
    pub client: String,
    pub title: String,
    pub cwd: String,
    pub parent: Option<String>,
    pub location: Location,
    pub status: String,
    pub task_status: Option<String>,
    pub summary: String,
    #[serde(default)]
    pub summary_at: u64,
    pub last_seen: u64,
    pub last_hook: u64,
    pub last_report: Option<u64>,
    pub stale: bool,
    pub tasks: BTreeMap<String, Value>,
    pub steps: BTreeMap<String, Value>,
    pub relations: Vec<Value>,
    #[serde(default)]
    pub native_agent_id: String,
    #[serde(default)]
    pub provisional: bool,
    #[serde(default)]
    pub run_id: String,
    #[serde(default)]
    pub transcript_path: String,
    #[serde(default)]
    pub observed_at: u64,
    #[serde(default)]
    pub reconcile: Option<ReconcileRequest>,
}

pub fn agent_label(agent: &Agent) -> String {
    let suffix: String = agent
        .session_id
        .chars()
        .rev()
        .take(8)
        .collect::<String>()
        .chars()
        .rev()
        .collect();
    format!("{} · {suffix}", agent.client)
}

#[derive(Clone, Deserialize, Serialize)]
pub struct Report {
    pub id: String,
    pub at: u64,
    pub client: String,
    pub session_id: String,
    #[serde(default)]
    pub parent: Option<String>,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    pub location: Location,
    pub kind: String,
    #[serde(default)]
    pub data: Value,
}

#[derive(Clone, Default, Deserialize, Serialize, PartialEq)]
pub struct Snapshot {
    pub agents: BTreeMap<String, Agent>,
    #[serde(default)]
    pub history: BTreeMap<String, Agent>,
    #[serde(default)]
    pub history_chat: Vec<Value>,
    #[serde(default)]
    pub scope: String,
    #[serde(default)]
    pub runtime: String,
    pub events: Vec<Value>,
    pub chat: Vec<Value>,
    pub pi_status: String,
    pub pi_text: String,
    pub revision: u64,
}

pub struct Store {
    db: Connection,
    fresh_since: u64,
    pub snapshot: Snapshot,
    pub live: BTreeSet<String>,
}

impl Store {
    pub fn open(path: &Path, fresh_since: u64) -> Result<Self> {
        let db = Connection::open(path)?;
        db.execute_batch(
            "PRAGMA journal_mode=WAL;
             CREATE TABLE IF NOT EXISTS agents (id TEXT PRIMARY KEY, body TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, at INTEGER, body TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS chat (id INTEGER PRIMARY KEY, body TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS monitor (id INTEGER PRIMARY KEY, scope TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS agent_history (id TEXT PRIMARY KEY, body TEXT NOT NULL);",
        )?;
        let mut snapshot = Snapshot::default();
        {
            let mut query = db.prepare("SELECT body FROM agents")?;
            for row in query.query_map([], |row| row.get::<_, String>(0))? {
                let mut agent: Agent = serde_json::from_str(&row?)?;
                agent.stale = true;
                snapshot.agents.insert(agent.id.clone(), agent);
            }
            let mut query = db.prepare("SELECT body FROM events ORDER BY rowid DESC LIMIT 300")?;
            for row in query.query_map([], |row| row.get::<_, String>(0))? {
                snapshot.events.push(serde_json::from_str(&row?)?);
            }
            snapshot.events.reverse();
            let mut query = db.prepare("SELECT id, body FROM agent_history")?;
            for row in query.query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })? {
                let (id, body) = row?;
                snapshot.history.insert(id, serde_json::from_str(&body)?);
            }
            let mut query = db.prepare(
                "SELECT body FROM chat WHERE json_extract(body, '$.at') >= ?1 ORDER BY id DESC",
            )?;
            for row in query.query_map([now().saturating_sub(30 * 24 * 60 * 60 * 1000)], |row| {
                row.get::<_, String>(0)
            })? {
                snapshot.chat.push(serde_json::from_str(&row?)?);
            }
            snapshot.chat.reverse();
        }
        snapshot.pi_status = "starting".into();
        snapshot.scope = db
            .query_row("SELECT scope FROM monitor WHERE id = 1", [], |row| {
                row.get(0)
            })
            .unwrap_or_default();
        snapshot.history_chat = std::mem::take(&mut snapshot.chat);
        snapshot.chat = snapshot
            .history_chat
            .iter()
            .filter(|item| item["scope"].as_str() == Some(snapshot.scope.as_str()))
            .cloned()
            .collect();
        Ok(Self {
            db,
            fresh_since,
            snapshot,
            live: BTreeSet::new(),
        })
    }

    pub fn view(&self) -> Snapshot {
        let mut view = self.snapshot.clone();
        view.history.extend(
            view.agents
                .iter()
                .filter(|(id, _)| !self.live.contains(*id))
                .map(|(id, agent)| (id.clone(), agent.clone()))
                .collect::<BTreeMap<_, _>>(),
        );
        view.agents.retain(|id, _| self.live.contains(id));
        view.events.retain(|event| {
            let id = format!(
                "{}:{}",
                event["client"].as_str().unwrap_or(""),
                event["session_id"].as_str().unwrap_or("")
            );
            view.agents.get(&id).is_some_and(|agent| {
                event["location"]["scope"].as_str() == Some(agent.location.scope.as_str())
            })
        });
        view.history_chat
            .retain(|item| item["scope"].as_str() != Some(view.scope.as_str()));
        view
    }

    pub fn observe(&mut self, sampled: &BTreeMap<String, Agent>, states: &Value) {
        for (id, previous) in sampled {
            let Some(current) = self.snapshot.agents.get_mut(id) else {
                continue;
            };
            if current.location != previous.location {
                continue;
            }
            if let Some(alive) = states[id].as_bool() {
                let alive = alive && current.status != "ended";
                let changed = if alive {
                    self.live.insert(id.clone())
                } else {
                    self.live.remove(id)
                };
                current.stale = !alive;
                if changed {
                    self.snapshot.revision += 1;
                }
            }
        }
    }

    pub fn set_scope(&mut self, scope: &str) -> Result<()> {
        if self.snapshot.scope == scope {
            return Ok(());
        }
        self.db.execute(
            "INSERT OR REPLACE INTO monitor (id, scope) VALUES (1, ?1)",
            [scope],
        )?;
        self.snapshot.scope = scope.into();
        self.snapshot.chat = self
            .snapshot
            .history_chat
            .iter()
            .filter(|item| item["scope"].as_str() == Some(scope))
            .cloned()
            .collect();
        self.snapshot.revision += 1;
        Ok(())
    }

    pub fn prune(&mut self) -> Result<()> {
        let cutoff = now().saturating_sub(30 * 24 * 60 * 60 * 1000);
        let expired: Vec<_> = self
            .snapshot
            .agents
            .iter()
            .filter(|(id, agent)| agent.last_seen < cutoff && !self.live.contains(*id))
            .map(|(id, _)| id.clone())
            .collect();
        let tx = self.db.transaction()?;
        for id in &expired {
            tx.execute("DELETE FROM agents WHERE id = ?1", [id])?;
        }
        tx.execute("DELETE FROM events WHERE at < ?1", [cutoff])?;
        tx.execute(
            "DELETE FROM agent_history WHERE json_extract(body, '$.last_seen') < ?1",
            [cutoff],
        )?;
        tx.execute(
            "DELETE FROM chat WHERE json_extract(body, '$.at') < ?1",
            [cutoff],
        )?;
        tx.commit()?;
        for id in expired {
            self.snapshot.agents.remove(&id);
        }
        self.snapshot
            .history
            .retain(|_, agent| agent.last_seen >= cutoff);
        self.snapshot
            .events
            .retain(|item| item["at"].as_u64().unwrap_or(0) >= cutoff);
        self.snapshot
            .chat
            .retain(|item| item["at"].as_u64().unwrap_or(0) >= cutoff);
        self.snapshot
            .history_chat
            .retain(|item| item["at"].as_u64().unwrap_or(0) >= cutoff);
        Ok(())
    }

    pub fn report(&mut self, mut report: Report) -> Result<String> {
        let subagent_event = report.kind == "hook"
            && report.client == "codex"
            && matches!(
                report.data["event"].as_str(),
                Some("SubagentStart" | "SubagentStop")
            );
        let mut provisional = subagent_event && report.data["subject_verified"] != true;
        if provisional {
            let native = required(&report.data, "agent_id")?;
            let parent = report
                .parent
                .as_deref()
                .context("Subagent hook has no parent")?;
            if let Some(child) = self.snapshot.agents.values().find(|agent| {
                agent.client == report.client
                    && !agent.provisional
                    && agent.parent.as_deref() == Some(parent)
                    && report.location.process_id != 0
                    && !report.location.process_started.is_empty()
                    && agent.location.process_id == report.location.process_id
                    && agent.location.process_started == report.location.process_started
                    && (agent.native_agent_id == native || agent.session_id == native)
            }) {
                report.session_id = child.session_id.clone();
                provisional = false;
            } else {
                report.session_id = format!(
                    "{}/{native}",
                    parent.strip_prefix("codex:").unwrap_or(parent)
                );
            }
        }
        if report.session_id.is_empty() || report.client.is_empty() {
            bail!("client and session_id are required");
        }
        let id = format!("{}:{}", report.client, report.session_id);
        if let Some(current) = self.snapshot.agents.get(&id) {
            if report.kind == "hook"
                && report.parent.is_some()
                && current.parent.is_some()
                && report.parent != current.parent
            {
                bail!("Hook parent does not match the registered agent");
            }
        }
        let resolved = if report.client == "codex"
            && report.kind == "hook"
            && report.data["subject_verified"] == true
        {
            self.snapshot
                .agents
                .values()
                .find(|agent| {
                    agent.provisional
                        && agent.parent.is_some()
                        && agent.parent == report.parent
                        && (report.data["agent_id"].as_str()
                            == Some(agent.native_agent_id.as_str())
                            || report.session_id == agent.native_agent_id)
                        && report.location.process_id != 0
                        && !report.location.process_started.is_empty()
                        && agent.location.process_id == report.location.process_id
                        && agent.location.process_started == report.location.process_started
                })
                .cloned()
        } else {
            None
        };
        if report.kind != "hook" {
            if let Some(agent) = self.snapshot.agents.get(&id) {
                report.location = agent.location.clone();
            }
        }
        let tx = self.db.transaction()?;
        if tx.execute(
            "INSERT OR IGNORE INTO events (id, at, body) VALUES (?1, ?2, ?3)",
            params![report.id, report.at, serde_json::to_string(&report)?],
        )? == 0
        {
            return Ok(id);
        }

        let previous = self
            .snapshot
            .agents
            .get(&id)
            .filter(|agent| {
                report.kind == "hook"
                    && report.at >= agent.last_hook
                    && report.location.process_id != 0
                    && !agent.location.scope.is_empty()
                    && (report.location.scope != agent.location.scope
                        || report.location.process_id != agent.location.process_id
                        || report.location.process_started != agent.location.process_started)
            })
            .cloned();
        if let Some(agent) = &previous {
            let key = format!("{}:{}", agent.location.scope, agent.id);
            tx.execute(
                "INSERT OR REPLACE INTO agent_history (id, body) VALUES (?1, ?2)",
                params![key, serde_json::to_string(agent)?],
            )?;
        }
        let mut agent = self
            .snapshot
            .agents
            .get(&id)
            .filter(|_| previous.is_none())
            .cloned()
            .or_else(|| resolved.clone())
            .unwrap_or_else(|| Agent {
                id: id.clone(),
                session_id: report.session_id.clone(),
                client: report.client.clone(),
                status: "unknown".into(),
                provisional,
                ..Agent::default()
            });
        if let Some(unresolved) = &resolved {
            agent.id = id.clone();
            agent.session_id = report.session_id.clone();
            agent.provisional = false;
            agent.native_agent_id = unresolved.native_agent_id.clone();
            if unresolved.last_hook > agent.last_hook {
                if unresolved.last_hook >= agent.observed_at {
                    agent.status = unresolved.status.clone();
                    agent.reconcile = unresolved.reconcile.clone();
                    if let Some(request) = &mut agent.reconcile {
                        request.child_run = agent.run_id.clone();
                    }
                }
                agent.last_hook = unresolved.last_hook;
            }
            if agent.transcript_path.is_empty() {
                agent.transcript_path =
                    report.data["transcript_path"].as_str().unwrap_or("").into();
            }
            for (target, source) in [
                (&mut agent.tasks, &unresolved.tasks),
                (&mut agent.steps, &unresolved.steps),
            ] {
                for (key, value) in source {
                    if target.get(key).is_none_or(|current| {
                        current["reported_at"].as_u64().unwrap_or(0)
                            < value["reported_at"].as_u64().unwrap_or(0)
                    }) {
                        target.insert(key.clone(), value.clone());
                    }
                }
            }
            for relation in &unresolved.relations {
                if !agent.relations.contains(relation) {
                    agent.relations.push(relation.clone());
                }
            }
            if agent.title.is_empty() {
                agent.title = unresolved.title.clone();
            }
            if unresolved.summary_at > agent.summary_at {
                agent.summary = unresolved.summary.clone();
                agent.summary_at = unresolved.summary_at;
                agent.task_status = unresolved.task_status.clone();
            }
            agent.last_seen = agent.last_seen.max(unresolved.last_seen);
            agent.last_report = agent.last_report.max(unresolved.last_report);
        }
        let last_update = if report.kind == "hook" {
            agent.last_hook
        } else {
            agent.last_report.unwrap_or(0)
        };
        if report.at >= last_update {
            agent.last_seen = agent.last_seen.max(report.at);
            agent.stale = agent.last_seen < self.fresh_since;
            if !report.cwd.is_empty() {
                agent.cwd = report.cwd.clone();
            }
            if report.kind == "hook" && report.location.process_id != 0 {
                agent.location = report.location.clone();
            }
            if report.parent.is_some() {
                agent.parent = report.parent.clone();
            }
            match report.kind.as_str() {
                "hook" => lifecycle::apply(&mut agent, &report),
                "report_task" => {
                    let key = required(&report.data, "task_id")?;
                    let mut task = report.data.clone();
                    task["reported_at"] = json!(report.at);
                    agent.tasks.insert(key.into(), task);
                }
                "report_step" => {
                    let key = format!(
                        "{}:{}",
                        required(&report.data, "task_id")?,
                        required(&report.data, "step_id")?
                    );
                    let mut step = report.data.clone();
                    step["reported_at"] = json!(report.at);
                    agent.steps.insert(key, step);
                }
                "report_relation" => {
                    let target = required(&report.data, "target_agent_id")?;
                    let relation = required(&report.data, "relation")?;
                    if relation == "parent" {
                        if target == id {
                            bail!("an agent cannot be its own parent");
                        }
                        agent.parent = Some(target.into());
                    }
                    agent.relations.retain(|item| {
                        item["target_agent_id"] != target || item["relation"] != relation
                    });
                    agent.relations.push(report.data.clone());
                }
                "report_status" => {
                    agent.summary = required(&report.data, "summary")?.into();
                    agent.summary_at = report.at;
                    let status = required(&report.data, "status")?;
                    if !matches!(
                        status,
                        "running" | "waiting" | "idle" | "error" | "cancelled"
                    ) {
                        bail!("unsupported status");
                    }
                    agent.task_status = Some(status.into());
                }
                _ => bail!("unsupported report kind"),
            }
            if report.kind != "hook" {
                agent.last_report = Some(report.at);
            }
        }
        let mut linked = BTreeMap::new();
        if let Some(unresolved) = &resolved {
            tx.execute("DELETE FROM agents WHERE id = ?1", [&unresolved.id])?;
            tx.execute(
                "UPDATE events SET body = json_set(body, '$.session_id', ?1)
                 WHERE json_extract(body, '$.client') = ?2
                   AND json_extract(body, '$.session_id') = ?3
                   AND json_extract(body, '$.location.scope') = ?4
                   AND json_extract(body, '$.location.process_id') = ?5
                   AND json_extract(body, '$.location.process_started') = ?6",
                params![
                    report.session_id,
                    report.client,
                    unresolved.session_id,
                    unresolved.location.scope,
                    unresolved.location.process_id,
                    unresolved.location.process_started,
                ],
            )?;
            for (other_id, current) in &self.snapshot.agents {
                if other_id == &unresolved.id || other_id == &id {
                    continue;
                }
                let mut other = current.clone();
                lifecycle::relink(&mut other, &unresolved.id, &id);
                if other != *current {
                    tx.execute(
                        "INSERT OR REPLACE INTO agents (id, body) VALUES (?1, ?2)",
                        params![other_id, serde_json::to_string(&other)?],
                    )?;
                    linked.insert(other_id.clone(), other);
                }
            }
            lifecycle::relink(&mut agent, &unresolved.id, &id);
        }
        tx.execute(
            "INSERT OR REPLACE INTO agents (id, body) VALUES (?1, ?2)",
            params![id, serde_json::to_string(&agent)?],
        )?;
        let mut children = BTreeMap::new();
        if report.at >= last_update
            && (lifecycle::requests_children(&report) || lifecycle::starts_turn(&report))
        {
            for (child_id, child) in &self.snapshot.agents {
                let child = linked.get(child_id).unwrap_or(child);
                if child.parent.as_deref() != Some(id.as_str()) {
                    continue;
                }
                let mut child = child.clone();
                if matches!(child.status.as_str(), "running" | "unknown") {
                    if child.reconcile.is_none() {
                        child.reconcile = Some(ReconcileRequest {
                            parent_run: agent.run_id.clone(),
                            child_run: child.run_id.clone(),
                            requested_at: report.at,
                            checked_at: 0,
                        });
                    }
                }
                if lifecycle::starts_turn(&report) {
                    if let Some(request) = &mut child.reconcile {
                        request.checked_at = 0;
                    }
                }
                if child.reconcile != self.snapshot.agents[child_id].reconcile {
                    tx.execute(
                        "INSERT OR REPLACE INTO agents (id, body) VALUES (?1, ?2)",
                        params![child_id, serde_json::to_string(&child)?],
                    )?;
                    children.insert(child_id.clone(), child);
                }
            }
        }
        tx.commit()?;
        self.snapshot.agents.extend(linked);
        if let Some(unresolved) = resolved {
            self.snapshot.agents.remove(&unresolved.id);
            if self.live.remove(&unresolved.id) {
                self.live.insert(id.clone());
            }
            for event in &mut self.snapshot.events {
                if event["client"] == report.client
                    && event["session_id"] == unresolved.session_id
                    && event["location"]["scope"] == unresolved.location.scope
                    && event["location"]["process_id"] == unresolved.location.process_id
                    && event["location"]["process_started"] == unresolved.location.process_started
                {
                    event["session_id"] = json!(report.session_id);
                }
            }
        }
        self.snapshot.agents.extend(children);
        if let Some(agent) = previous {
            self.snapshot
                .history
                .insert(format!("{}:{}", agent.location.scope, agent.id), agent);
            self.live.remove(&id);
        }
        self.snapshot.agents.insert(id.clone(), agent);
        self.snapshot.events.push(serde_json::to_value(report)?);
        if self.snapshot.events.len() > 300 {
            self.snapshot.events.remove(0);
        }
        self.snapshot.revision += 1;
        Ok(id)
    }

    pub fn reconciliation_candidates(&self) -> Vec<Agent> {
        let at = now();
        self.snapshot
            .agents
            .values()
            .filter(|agent| {
                self.live.contains(&agent.id)
                    && agent.reconcile.as_ref().is_some_and(|request| {
                        request.child_run == agent.run_id
                            && at.saturating_sub(request.checked_at) >= 30_000
                    })
            })
            .cloned()
            .collect()
    }

    pub fn reconciled(
        &mut self,
        sampled: &Agent,
        evidence: Option<crate::reconcile::Evidence>,
    ) -> Result<()> {
        let Some(current) = self.snapshot.agents.get(&sampled.id) else {
            return Ok(());
        };
        if current.last_hook != sampled.last_hook
            || current.location != sampled.location
            || current.run_id != sampled.run_id
            || current.reconcile != sampled.reconcile
            || current.reconcile.is_none()
        {
            return Ok(());
        }
        let mut agent = current.clone();
        let at = now();
        let status = evidence
            .as_ref()
            .filter(|evidence| evidence.run_id == agent.run_id)
            .map(|evidence| evidence.status)
            .unwrap_or("unknown");
        if matches!(status, "idle" | "error" | "cancelled")
            || !matches!(agent.status.as_str(), "approval" | "waiting")
        {
            agent.status = status.into();
        }
        if matches!(status, "idle" | "error" | "cancelled") {
            agent.reconcile = None;
            agent.observed_at = at;
        } else if let Some(request) = &mut agent.reconcile {
            request.checked_at = at;
        }
        let report = Report {
            id: uuid::Uuid::new_v4().to_string(),
            at,
            client: agent.client.clone(),
            session_id: agent.session_id.clone(),
            parent: agent.parent.clone(),
            cwd: agent.cwd.clone(),
            location: agent.location.clone(),
            kind: "observation".into(),
            data: json!({"event":"Reconciled", "run_id":agent.run_id, "status":agent.status}),
        };
        let tx = self.db.transaction()?;
        tx.execute(
            "INSERT OR REPLACE INTO agents (id, body) VALUES (?1, ?2)",
            params![agent.id, serde_json::to_string(&agent)?],
        )?;
        tx.execute(
            "INSERT INTO events (id, at, body) VALUES (?1, ?2, ?3)",
            params![report.id, at, serde_json::to_string(&report)?],
        )?;
        tx.commit()?;
        self.snapshot.agents.insert(agent.id.clone(), agent);
        self.snapshot.events.push(serde_json::to_value(report)?);
        if self.snapshot.events.len() > 300 {
            self.snapshot.events.remove(0);
        }
        self.snapshot.revision += 1;
        Ok(())
    }

    pub fn chat(&mut self, role: &str, text: &str, scope: Option<&str>) -> Result<()> {
        let scope = scope.unwrap_or(&self.snapshot.scope);
        let message = json!({ "role": role, "text": text, "at": now(), "scope": scope });
        self.db
            .execute("INSERT INTO chat (body) VALUES (?1)", [message.to_string()])?;
        self.snapshot.history_chat.push(message.clone());
        if scope == self.snapshot.scope {
            self.snapshot.chat.push(message);
        }
        if self.snapshot.chat.len() > 200 {
            self.snapshot.chat.remove(0);
        }
        self.snapshot.revision += 1;
        Ok(())
    }
}

pub fn required<'a>(value: &'a Value, name: &str) -> Result<&'a str> {
    value[name]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow::anyhow!("{name} is required"))
}

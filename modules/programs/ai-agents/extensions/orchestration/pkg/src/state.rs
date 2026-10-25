use anyhow::{bail, Result};
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
        if report.session_id.is_empty() || report.client.is_empty() {
            bail!("client and session_id are required");
        }
        let id = format!("{}:{}", report.client, report.session_id);
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
                    && report.location.scope != agent.location.scope
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
            .unwrap_or_else(|| Agent {
                id: id.clone(),
                session_id: report.session_id.clone(),
                client: report.client.clone(),
                status: "unknown".into(),
                ..Agent::default()
            });
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
                "hook" => {
                    agent.last_hook = report.at;
                    let event = report.data["event"].as_str().unwrap_or("");
                    if let Some(title) = report.data["title"].as_str() {
                        agent.title = title.into();
                    }
                    let status = match event {
                        "SessionStart" => Some("idle"),
                        "UserPromptSubmit" | "PreToolUse" => Some("running"),
                        "PostToolUse" if report.data["is_error"] == true => Some("error"),
                        "PostToolUse" => Some("running"),
                        "StopFailure" => Some("error"),
                        "Stop" if report.data["outcome"] == "aborted" => Some("cancelled"),
                        "Stop" if report.data["outcome"] == "error" => Some("error"),
                        "Stop" if report.data["proposed_plan"] == true => Some("waiting"),
                        "Stop" => Some("idle"),
                        "SessionEnd" => Some("ended"),
                        "Notification" if report.data["phase"] == "end" => {
                            Some(report.data["resume_state"].as_str().unwrap_or("unknown"))
                        }
                        "Notification"
                            if report.data["notification_type"] == "permission_prompt" =>
                        {
                            Some("approval")
                        }
                        "Notification" => Some("waiting"),
                        _ => None,
                    };
                    if let Some(status) = status {
                        agent.status = status.into();
                    }
                }
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
        tx.execute(
            "INSERT OR REPLACE INTO agents (id, body) VALUES (?1, ?2)",
            params![id, serde_json::to_string(&agent)?],
        )?;
        tx.commit()?;
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

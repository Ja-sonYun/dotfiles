use crate::lifecycle;
use anyhow::{bail, Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
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
    #[serde(default)]
    pub reported_title: String,
    pub cwd: String,
    pub parent: Option<String>,
    pub location: Location,
    pub status: String,
    #[serde(default)]
    pub last_confirmed_status: String,
    #[serde(default)]
    pub unread_completion: Option<String>,
    #[serde(default)]
    pub completed: bool,
    #[serde(default)]
    pub turn_id: String,
    #[serde(default)]
    pub state_source: String,
    #[serde(default)]
    pub state_at: u64,
    #[serde(default)]
    pub observation_pending: bool,
    #[serde(default)]
    pub observation_revision: u64,
    #[serde(default)]
    pub observation_evidence_revision: u64,
    #[serde(default)]
    pub observation_error: String,
    #[serde(default)]
    pub observation_priority: bool,
    #[serde(default)]
    pub observation_resumed: bool,
    #[serde(default)]
    pub prompt_pending: bool,
    #[serde(default)]
    pub approval_pending: bool,
    #[serde(default)]
    pub prompt_tool_id: String,
    #[serde(default)]
    pub prompt_tool_name: String,
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
    pub terminal_status: String,
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
    pub stopped_children: BTreeSet<String>,
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
             CREATE TABLE IF NOT EXISTS agent_history (id TEXT PRIMARY KEY, body TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS inbox (
                 id TEXT PRIMARY KEY, recipient TEXT NOT NULL, turn_id TEXT,
                 kind TEXT NOT NULL, body TEXT NOT NULL, acknowledged INTEGER NOT NULL DEFAULT 0
             );
             CREATE INDEX IF NOT EXISTS inbox_recipient ON inbox (recipient, acknowledged);
             CREATE TABLE IF NOT EXISTS inbox_deliveries (id TEXT PRIMARY KEY);",
        )?;
        let mut snapshot = Snapshot::default();
        {
            let mut query = db.prepare("SELECT body FROM agents")?;
            for row in query.query_map([], |row| row.get::<_, String>(0))? {
                let mut agent: Agent = serde_json::from_str(&row?)?;
                if agent.state_source.is_empty() {
                    agent.status = "unknown".into();
                    agent.completed = false;
                }
                agent.observation_pending = !agent.provisional && !agent.completed;
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

    pub fn send_message(&mut self, sender: &str, args: &Value) -> Result<Value> {
        let recipient = required(args, "agent_id")?;
        let agent = self
            .snapshot
            .agents
            .get(recipient)
            .context("Unknown recipient")?;
        if agent.provisional {
            bail!("Recipient identity is not confirmed");
        }
        let kind = required(args, "kind")?;
        if !matches!(kind, "message" | "status_request" | "completion_request") {
            bail!("Unsupported message kind");
        }
        let body = required(args, "body")?;
        if body.len() > 4096 {
            bail!("Message body exceeds 4096 UTF-8 bytes");
        }
        let turn = args
            .get("turn_id")
            .map(|_| required(args, "turn_id"))
            .transpose()?;
        if turn.is_some_and(|turn| turn != agent.turn_id)
            || (kind == "status_request" && turn.is_none())
        {
            bail!("Provide the recipient's current turn_id for a status request");
        }
        let tx = self.db.transaction()?;
        if kind != "message" {
            let existing: Option<(String, bool)> = tx
                .query_row(
                    "SELECT body, acknowledged FROM inbox WHERE recipient = ?1 AND turn_id IS ?2 AND kind = ?3
                     AND (?3 = 'completion_request' OR acknowledged = 0)
                     AND (?3 = 'status_request' OR json_extract(body, '$.body') = ?4) LIMIT 1",
                    params![recipient, turn, kind, body],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            if let Some((existing, acknowledged)) = existing {
                let mut message: Value = serde_json::from_str(&existing)?;
                message["acknowledged"] = json!(acknowledged);
                return Ok(message);
            }
        }
        let message = json!({
            "message_id": uuid::Uuid::new_v4().to_string(),
            "sender": sender, "agent_id": recipient, "turn_id": turn,
            "kind": kind, "body": body, "created_at": now(), "acknowledged": false,
        });
        let encoded = message.to_string();
        if encoded.len() > 8 * 1024 {
            bail!("Serialized message exceeds 8192 UTF-8 bytes");
        }
        tx.execute(
            "INSERT INTO inbox (id, recipient, turn_id, kind, body) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                message["message_id"].as_str(),
                recipient,
                turn,
                kind,
                encoded
            ],
        )?;
        tx.commit()?;
        Ok(message)
    }

    pub fn child_stopped(&self, agent: &Agent) -> Result<bool> {
        if agent.parent.is_none() || agent.provisional || agent.turn_id.is_empty() {
            return Ok(false);
        }
        self.db
            .query_row(
                "SELECT EXISTS (
                    SELECT 1 FROM events AS stopped JOIN events AS started ON started.id = ?1
                    WHERE stopped.rowid >= started.rowid AND stopped.at >= started.at
                    AND stopped.at <= ?2
                    AND json_extract(stopped.body, '$.kind') = 'hook'
                    AND json_extract(stopped.body, '$.client') = ?3
                    AND json_extract(stopped.body, '$.session_id') = ?4
                    AND json_extract(stopped.body, '$.parent') = ?5
                    AND json_extract(stopped.body, '$.location.scope') = ?6
                    AND json_extract(stopped.body, '$.location.process_id') = ?7
                    AND json_extract(stopped.body, '$.location.process_started') = ?8
                    AND json_extract(stopped.body, '$.data.event') IN
                        ('Stop', 'StopFailure', 'SubagentStop', 'SessionEnd')
                    AND (coalesce(json_extract(stopped.body, '$.data.run_id'), '') = ''
                         OR json_extract(stopped.body, '$.data.run_id') = ?9)
                )",
                params![
                    agent.turn_id,
                    agent.last_hook,
                    agent.client,
                    agent.session_id,
                    agent.parent,
                    agent.location.scope,
                    agent.location.process_id,
                    agent.location.process_started,
                    agent.run_id,
                ],
                |row| row.get(0),
            )
            .context("Cannot read child termination events")
    }

    pub fn request_status(&mut self, id: &str) -> Result<()> {
        let Some(agent) = self.snapshot.agents.get(id).cloned() else {
            return Ok(());
        };
        if agent.provisional || agent.turn_id.is_empty() || agent.completed {
            return Ok(());
        }
        let stopped = self.child_stopped(&agent)?;
        if !stopped {
            return Ok(());
        }
        if let Some(parent) = agent
            .parent
            .as_ref()
            .and_then(|id| self.snapshot.agents.get(id))
        {
            if !parent.provisional && !parent.turn_id.is_empty() {
                let request = json!({
                    "agent_id": parent.id, "kind": "completion_request",
                    "body": format!(
                        "If you received an actual completion result from child {} for child_turn_id {}, report it with report_subagent_completion and your current parent_turn_id. Otherwise do not infer an outcome. Acknowledge this message after handling it, including when no result is available.",
                        agent.id, agent.turn_id,
                    ),
                });
                self.send_message("agent-hub", &request)?;
            }
        }
        Ok(())
    }

    pub fn read_messages(&self, id: &str, turn: &str, deliver: bool) -> Result<Value> {
        let agent = self.snapshot.agents.get(id).context("Unknown recipient")?;
        if agent.provisional || turn.is_empty() || agent.turn_id != turn {
            bail!("Agent turn changed; read list_agents again");
        }
        let mut query = self.db.prepare(
            "SELECT body FROM inbox WHERE recipient = ?1 AND acknowledged = 0
             AND (turn_id IS NULL OR turn_id = ?2)
             AND (?3 = 0 OR id NOT IN (SELECT id FROM inbox_deliveries)) ORDER BY rowid",
        )?;
        let mut messages = Vec::<Value>::new();
        let mut bytes = 0;
        let mut truncated = false;
        for row in query.query_map(params![id, turn, deliver], |row| row.get::<_, String>(0))? {
            let body = row?;
            if bytes + body.len() > 12 * 1024 {
                truncated = true;
                break;
            }
            bytes += body.len();
            messages.push(serde_json::from_str(&body)?);
        }
        Ok(
            json!({"agent_id": id, "turn_id": turn, "run_id": agent.run_id, "messages": messages, "truncated": truncated}),
        )
    }

    pub fn delivered(&mut self, value: &Value) -> Result<()> {
        let id = required(value, "agent_id")?;
        let turn = required(value, "turn_id")?;
        let agent = self.snapshot.agents.get(id).context("Unknown recipient")?;
        if agent.provisional || agent.turn_id != turn || value["run_id"] != agent.run_id {
            bail!("Inbox recipient changed");
        }
        let ids = value["message_ids"]
            .as_array()
            .context("Missing message IDs")?;
        let tx = self.db.transaction()?;
        for id in ids {
            let message_id = id.as_str().context("Invalid message ID")?;
            let (recipient, target_turn): (String, Option<String>) = tx.query_row(
                "SELECT recipient, turn_id FROM inbox WHERE id = ?1",
                [message_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )?;
            if recipient != agent.id || target_turn.as_deref().is_some_and(|value| value != turn) {
                bail!("Message belongs to another agent or turn");
            }
            tx.execute(
                "INSERT OR IGNORE INTO inbox_deliveries (id) VALUES (?1)",
                [message_id],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn ack_messages(&mut self, id: &str, turn: &str, ids: &[Value]) -> Result<()> {
        let agent = self.snapshot.agents.get(id).context("Unknown recipient")?;
        if agent.provisional || turn.is_empty() || agent.turn_id != turn {
            bail!("Agent turn changed; read list_agents again");
        }
        let tx = self.db.transaction()?;
        for id in ids {
            let message_id = id.as_str().context("message_ids must contain strings")?;
            let (recipient, target_turn, body, acknowledged): (
                String,
                Option<String>,
                String,
                bool,
            ) = tx
                .query_row(
                    "SELECT recipient, turn_id, body, acknowledged FROM inbox WHERE id = ?1",
                    [message_id],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
                )
                .context("Unknown message_id")?;
            if recipient != agent.id || target_turn.as_deref().is_some_and(|value| value != turn) {
                bail!("Message belongs to another agent or turn");
            }
            let message: Value = serde_json::from_str(&body)?;
            if !acknowledged
                && message["kind"] == "status_request"
                && (agent.state_source != "mcp"
                    || agent.state_at < message["created_at"].as_u64().unwrap_or(u64::MAX))
            {
                bail!("Report your current status before acknowledging this request");
            }
            tx.execute(
                "UPDATE inbox SET acknowledged = 1 WHERE id = ?1",
                [message_id],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn mark_read(&mut self, value: &Value) -> Result<()> {
        let id = required(value, "agent_id")?;
        let completion = required(value, "completion_id")?;
        let (agents, sql) = if self.snapshot.agents.contains_key(id) {
            (
                &mut self.snapshot.agents,
                "UPDATE agents SET body = ?2 WHERE id = ?1",
            )
        } else {
            (
                &mut self.snapshot.history,
                "UPDATE agent_history SET body = ?2 WHERE id = ?1",
            )
        };
        let current = agents.get(id).context("Agent is not registered")?;
        if current.unread_completion.as_deref() != Some(completion) {
            bail!("Completion changed; refresh before marking it read");
        }
        let mut agent = current.clone();
        agent.unread_completion = None;
        self.db
            .execute(sql, params![id, serde_json::to_string(&agent)?])?;
        agents.insert(id.into(), agent);
        self.snapshot.revision += 1;
        Ok(())
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
                let alive = alive
                    && current.status != "ended"
                    && !(current.parent.is_some() && current.completed);
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
        let tx = self.db.transaction()?;
        tx.execute(
            "INSERT OR REPLACE INTO monitor (id, scope) VALUES (1, ?1)",
            [scope],
        )?;
        let mut observations = BTreeMap::new();
        for agent in self.snapshot.agents.values().filter(|agent| {
            self.live.contains(&agent.id)
                && !agent.provisional
                && !agent.stale
                && !agent.turn_id.is_empty()
                && (agent.observation_pending
                    || matches!(agent.status.as_str(), "approval" | "running"))
        }) {
            let mut agent = agent.clone();
            agent.observation_revision += 1;
            agent.observation_pending = true;
            agent.observation_priority = true;
            agent.observation_error.clear();
            tx.execute(
                "INSERT OR REPLACE INTO agents (id, body) VALUES (?1, ?2)",
                params![agent.id, serde_json::to_string(&agent)?],
            )?;
            observations.insert(agent.id.clone(), agent);
        }
        tx.commit()?;
        self.snapshot.agents.extend(observations);
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
        if report.kind == "report_subagent_completion" {
            let parent_id = required(&report.data, "parent_agent_id")?;
            let parent = self
                .snapshot
                .agents
                .get(parent_id)
                .context("Parent is not registered")?;
            let child = self
                .snapshot
                .agents
                .get(&id)
                .context("Child is not registered")?;
            if required(&report.data, "parent_turn_id")? != parent.turn_id
                || required(&report.data, "child_turn_id")? != child.turn_id
            {
                bail!("Agent turn changed; read list_agents again");
            }
            if required(&report.data, "child_agent_id")? != id
                || child.parent.as_deref() != Some(parent_id)
                || child.id == parent_id
            {
                bail!("Only the registered direct parent may report child completion");
            }
            let status = match required(&report.data, "outcome")? {
                "completed" => "idle",
                "failed" => "error",
                "cancelled" => "cancelled",
                _ => bail!("unsupported child outcome"),
            };
            required(&report.data, "summary")?;
            if child.completed {
                if child.status == status {
                    return Ok(id);
                }
                bail!("Child already completed with a different outcome");
            }
            report.data["status"] = json!(status);
            report.data["turn_id"] = json!(child.turn_id);
        }
        if matches!(
            report.kind.as_str(),
            "report_status" | "checked_status" | "report_title"
        ) {
            let current = self
                .snapshot
                .agents
                .get(&id)
                .context("Agent is not registered")?;
            if required(&report.data, "turn_id")? != current.turn_id {
                bail!("Agent turn changed; read list_agents again");
            }
        }
        if let Some(current) = self.snapshot.agents.get(&id) {
            if report.kind == "hook"
                && current.parent.is_some()
                && matches!(
                    report.data["event"].as_str(),
                    Some("Stop" | "StopFailure" | "SubagentStop" | "SessionEnd")
                )
                && !current.run_id.is_empty()
                && report.data["run_id"]
                    .as_str()
                    .is_some_and(|run| !run.is_empty() && run != current.run_id)
            {
                return Ok(id);
            }
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
                observation_revision: previous
                    .as_ref()
                    .map_or(0, |agent| agent.observation_revision + 1),
                ..Agent::default()
            });
        if let Some(unresolved) = &resolved {
            agent.id = id.clone();
            agent.session_id = report.session_id.clone();
            agent.provisional = false;
            agent.native_agent_id = unresolved.native_agent_id.clone();
            if unresolved.last_hook > agent.last_hook {
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
                "report_title" => {
                    let title = required(&report.data, "title")?.trim();
                    if title.is_empty()
                        || title.chars().count() > 120
                        || title.chars().any(char::is_control)
                    {
                        bail!("title must contain 1 to 120 characters without control characters");
                    }
                    agent.reported_title = title.into();
                    agent.observation_revision += 1;
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
                "report_status" | "checked_status" | "report_subagent_completion" => {
                    let summary = required(&report.data, "summary")?;
                    let status = required(&report.data, "status")?;
                    if !matches!(
                        status,
                        "running"
                            | "waiting"
                            | "approval"
                            | "idle"
                            | "error"
                            | "cancelled"
                            | "unknown"
                    ) {
                        bail!("unsupported status");
                    }
                    agent.observation_error.clear();
                    if report.kind == "checked_status" {
                        if let Some(title) = report.data["title"].as_str().filter(|title| {
                            !title.trim().is_empty()
                                && title.chars().count() <= 120
                                && !title.chars().any(char::is_control)
                        }) {
                            agent.reported_title = title.trim().into();
                        }
                    }
                    if report.kind == "checked_status" && status == "unknown" {
                        agent.observation_pending = false;
                        agent.observation_error = summary.into();
                        agent.status = "unknown".into();
                        agent.state_source =
                            report.data["source"].as_str().unwrap_or("pane").into();
                        agent.state_at = report.at;
                    } else {
                        agent.summary = summary.into();
                        agent.summary_at = report.at;
                        agent.status = status.into();
                        agent.state_source = if report.kind != "checked_status" {
                            "mcp"
                        } else {
                            report.data["source"].as_str().unwrap_or("pane")
                        }
                        .into();
                        agent.state_at = report.at;
                        agent.observation_pending = false;
                        if report.kind != "checked_status" {
                            agent.observation_revision += 1;
                        }
                        agent.completed = report.kind == "report_subagent_completion"
                            || (agent.parent.is_none()
                                && matches!(agent.status.as_str(), "idle" | "cancelled"));
                    }
                    if report.kind == "checked_status"
                        && report.data["observation_evidence_revision"]
                            .as_u64()
                            .is_some_and(|revision| revision < agent.observation_evidence_revision)
                    {
                        agent.observation_pending = true;
                        agent.observation_revision += 1;
                        agent.completed = false;
                    }
                    agent.observation_resumed = false;
                    agent.observation_priority = false;
                    if agent.parent.is_none()
                        && agent.status == "idle"
                        && agent.last_confirmed_status == "running"
                    {
                        agent.unread_completion = Some(report.id.clone());
                    }
                    if agent.status != "unknown" {
                        agent.last_confirmed_status = agent.status.clone();
                    }
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
        if !agent.provisional
            && report.at >= last_update
            && (report.kind == "report_subagent_completion"
                || (report.kind == "hook"
                    && matches!(
                        report.data["event"].as_str(),
                        Some(
                            "SubagentStart"
                                | "SubagentStop"
                                | "SessionStart"
                                | "Stop"
                                | "StopFailure"
                                | "SessionEnd"
                        )
                    )))
        {
            if let Some(parent) = agent
                .parent
                .as_ref()
                .and_then(|id| self.snapshot.agents.get(id))
            {
                if parent.parent.is_none()
                    && !parent.provisional
                    && !parent.stale
                    && !parent.turn_id.is_empty()
                    && !parent.location.pane.is_empty()
                    && report.at >= parent.state_at
                {
                    let mut parent = linked.get(&parent.id).unwrap_or(parent).clone();
                    parent.observation_revision += 1;
                    parent.observation_pending = true;
                    parent.observation_priority = true;
                    parent.observation_error.clear();
                    tx.execute(
                        "INSERT OR REPLACE INTO agents (id, body) VALUES (?1, ?2)",
                        params![parent.id, serde_json::to_string(&parent)?],
                    )?;
                    linked.insert(parent.id.clone(), parent);
                }
            }
        }
        tx.execute(
            "INSERT OR REPLACE INTO agents (id, body) VALUES (?1, ?2)",
            params![id, serde_json::to_string(&agent)?],
        )?;
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
        if let Some(agent) = previous {
            self.snapshot
                .history
                .insert(format!("{}:{}", agent.location.scope, agent.id), agent);
            self.live.remove(&id);
        }
        if agent.parent.is_some() && agent.completed {
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

    pub fn observation_failed(&mut self, value: &Value) -> Result<()> {
        let id = required(value, "agent_id")?;
        let Some(agent) = self.snapshot.agents.get_mut(id) else {
            return Ok(());
        };
        if value["turn_id"] != agent.turn_id
            || value["observation_revision"] != agent.observation_revision
            || !agent.observation_pending
        {
            return Ok(());
        }
        agent.observation_pending = value["observation_evidence_revision"]
            .as_u64()
            .is_some_and(|revision| revision < agent.observation_evidence_revision);
        if agent.observation_pending {
            agent.observation_revision += 1;
        }
        agent.observation_priority = false;
        agent.observation_resumed = false;
        agent.observation_error = required(value, "message")?.into();
        agent.status = if agent.terminal_status.is_empty() {
            "unknown".into()
        } else {
            agent.terminal_status.clone()
        };
        agent.state_source = "observation".into();
        agent.state_at = now();
        self.db.execute(
            "INSERT OR REPLACE INTO agents (id, body) VALUES (?1, ?2)",
            params![id, serde_json::to_string(agent)?],
        )?;
        self.snapshot.revision += 1;
        Ok(())
    }

    pub fn checked(&mut self, value: &Value) -> Result<Option<Report>> {
        let sampled: Agent = serde_json::from_value(value["sampled"].clone())?;
        let captured_at = value["captured_at"]
            .as_u64()
            .context("Missing capture time")?;
        let Some(current) = self.snapshot.agents.get(&sampled.id) else {
            return Ok(None);
        };
        if !self.live.contains(&sampled.id)
            || current.provisional
            || (current.parent.is_some() && value["source"] != "events")
            || current.turn_id != sampled.turn_id
            || current.observation_revision != sampled.observation_revision
            || current.location != sampled.location
            || current.run_id != sampled.run_id
            || current.state_at != sampled.state_at
            || captured_at < current.state_at
            || captured_at > now()
            || now().saturating_sub(captured_at) > 60_000
        {
            return Ok(None);
        }
        if value["source"] == "events" {
            let ids = value["evidence_ids"]
                .as_array()
                .context("Missing evidence IDs")?;
            if ids.is_empty() || ids.len() > 64 {
                bail!("Provide 1 to 64 evidence IDs");
            }
            for id in ids {
                let body: String = self.db.query_row(
                    "SELECT body FROM events WHERE id = ?1",
                    [id.as_str().context("Invalid evidence ID")?],
                    |row| row.get(0),
                )?;
                let event: Report = serde_json::from_str(&body)?;
                if event.client != current.client
                    || event.session_id != current.session_id
                    || event.parent != current.parent
                    || event.location != current.location
                    || event.kind != "hook"
                    || event.data["subject_verified"] != true
                {
                    bail!("Evidence belongs to another session");
                }
            }
            if value["status"] == "approval" && !current.approval_pending {
                bail!("No current approval prompt evidence");
            }
        }
        if !current.terminal_status.is_empty() && value["status"] != current.terminal_status {
            bail!("A confirmed failure or cancellation cannot be overwritten");
        }
        if value["type"] == "observation_requested" {
            if current.observation_pending {
                return Ok(None);
            }
            let mut agent = current.clone();
            agent.observation_pending = true;
            agent.observation_priority = true;
            agent.observation_revision += 1;
            agent.observation_error.clear();
            self.db.execute(
                "INSERT OR REPLACE INTO agents (id, body) VALUES (?1, ?2)",
                params![agent.id, serde_json::to_string(&agent)?],
            )?;
            self.snapshot.agents.insert(agent.id.clone(), agent);
            self.snapshot.revision += 1;
            return Ok(None);
        }
        let report = Report {
            id: uuid::Uuid::new_v4().to_string(),
            at: now(),
            client: current.client.clone(),
            session_id: current.session_id.clone(),
            parent: current.parent.clone(),
            cwd: current.cwd.clone(),
            location: current.location.clone(),
            kind: "checked_status".into(),
            data: json!({
                "turn_id": current.turn_id,
                "status": required(value, "status")?,
                "summary": required(value, "summary")?,
                "captured_at": captured_at,
                "observation_evidence_revision": sampled.observation_evidence_revision,
                "source": value["source"],
                "title": value["title"],
            }),
        };
        self.report(report.clone())?;
        Ok(Some(report))
    }

    pub fn observation_context(&self, value: &Value) -> Result<Value> {
        let sampled: Agent = serde_json::from_value(value["sampled"].clone())?;
        let current = self
            .snapshot
            .agents
            .get(&sampled.id)
            .context("Unknown agent")?;
        if current.provisional
            || current.stale
            || !self.live.contains(&current.id)
            || current.turn_id != sampled.turn_id
            || current.run_id != sampled.run_id
            || current.location != sampled.location
            || current.observation_revision != sampled.observation_revision
        {
            bail!("Observation changed");
        }
        let before = value["before"].as_i64().unwrap_or(i64::MAX);
        let mut query = self.db.prepare(
            "SELECT rowid, body FROM events WHERE rowid < ?1
             AND json_extract(body, '$.client') = ?2
             AND json_extract(body, '$.session_id') = ?3
             AND json_extract(body, '$.kind') = 'hook'
             AND json_extract(body, '$.data.subject_verified') = 1
             AND json_extract(body, '$.location') = ?4 ORDER BY rowid DESC LIMIT 33",
        )?;
        let mut page = json!({"events": [], "truncated": false, "next_before": null,
            "summary": current.summary.chars().take(500).collect::<String>(), "status": current.status, "latest_request": null});
        let latest: Option<String> = self
            .db
            .query_row(
                "SELECT json_extract(body, '$.data.evidence.prompt') FROM events
             WHERE json_extract(body, '$.client') = ?1 AND json_extract(body, '$.session_id') = ?2
             AND json_extract(body, '$.location') = ?3
             AND json_type(body, '$.data.evidence.prompt') = 'text' ORDER BY rowid DESC LIMIT 1",
                params![
                    current.client,
                    current.session_id,
                    serde_json::to_string(&current.location)?
                ],
                |row| row.get(0),
            )
            .optional()?;
        page["latest_request"] = json!(latest);
        let mut cursor = None;
        for row in query.query_map(
            params![
                before,
                current.client,
                current.session_id,
                serde_json::to_string(&current.location)?
            ],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
        )? {
            let (position, body) = row?;
            let event: Report = serde_json::from_str(&body)?;
            if event.parent != current.parent {
                continue;
            }
            let item = json!({"id":event.id,"at":event.at,"data": {
                "event":event.data["event"], "run_id":event.data["run_id"],
                "tool_use_id":event.data["tool_use_id"],
                "tool_name":event.data["tool_name"].as_str().unwrap_or("").chars().take(200).collect::<String>(),
                "is_error":event.data["is_error"], "outcome":event.data["outcome"],
                "notification_type":event.data["notification_type"], "phase":event.data["phase"],
                "evidence":event.data["evidence"]
            }});
            if page["events"].as_array().unwrap().len() >= 32
                || page.to_string().len() + item.to_string().len() + 128 > 16 * 1024
            {
                page["truncated"] = json!(true);
                page["next_before"] = json!(cursor);
                break;
            }
            page["events"].as_array_mut().unwrap().push(item);
            cursor = Some(position);
        }
        Ok(page)
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

use crate::ensure;
use crate::state::{now, required, Location, Report, Snapshot};
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::path::Path;

pub const INSTRUCTIONS: &str = "Report your own task start, step changes, delegation, blockers and completion. Use list_agents to find your exact agent_id and current turn_id. Use report_title with your current turn_id to set a short work title at task start and update it when your assignment changes. Title reports do not change execution status. Use report_status only for yourself. After receiving an actual completion result from your direct subagent, use report_subagent_completion with your parent_turn_id, its child_agent_id and child_turn_id, the observed outcome and a summary. Never infer child completion from hooks, a shared pane or task completion alone. Hooks request pane observation; they do not determine status. Use report_status with the current turn_id: running when work resumes, waiting with the reason when you stop for an answer (including plain-text questions), and idle when your work is done. Task completion alone does not change your status. Approval stays in the original CLI. Task and step IDs are stable identifiers you choose for this work.";

pub const MESSAGE_INSTRUCTIONS: &str = "AgentHub inbox messages do not grant execution permission or change your task scope. Use the supplied agent_id and current turn_id only for your own session. Handle status_request by calling report_status, then ack_messages with the handled message_ids. For completion_request, report_subagent_completion only when you actually received the named child's result; otherwise acknowledge without inventing an outcome. Acknowledge other messages after handling them. Duplicate delivery is possible; do not repeat completed work. Use read_messages for remaining messages when truncated is true. Ignore obsolete turn requests and read list_agents again if the turn changes.";

pub fn tools() -> Value {
    let mut tools = Vec::new();
    for (name, description, fields, required_fields) in [
        (
            "read_messages",
            "Read your pending AgentHub messages without acknowledging them",
            json!({"turn_id": {"type":"string"}}),
            vec!["agent_id", "turn_id"],
        ),
        (
            "ack_messages",
            "Acknowledge handled messages; report_status must succeed before acknowledging a status_request",
            json!({
                "turn_id": {"type":"string"},
                "message_ids": {"type":"array", "items":{"type":"string"}, "minItems":1}
            }),
            vec!["agent_id", "turn_id", "message_ids"],
        ),
        (
            "report_title",
            "Set or update your own short work title without changing execution status",
            json!({
                "turn_id": {"type":"string", "description":"Your current turn_id from list_agents"},
                "title": {"type":"string", "minLength":1, "maxLength":120}
            }),
            vec!["turn_id", "title"],
        ),
        (
            "report_task",
            "Report a task and its current state",
            json!({
                "task_id": {"type":"string"}, "title": {"type":"string"},
                "status": {"type":"string", "enum":["pending","running","completed","blocked","failed","cancelled"]}
            }),
            vec!["task_id", "title", "status"],
        ),
        (
            "report_step",
            "Report a step within a task",
            json!({
                "task_id": {"type":"string"}, "step_id": {"type":"string"},
                "title": {"type":"string"}, "status": {"type":"string", "enum":["pending","running","completed","blocked","failed","cancelled"]}
            }),
            vec!["task_id", "step_id", "title", "status"],
        ),
        (
            "report_relation",
            "Record an explicit agent relationship",
            json!({
                "target_agent_id": {"type":"string"},
                "relation": {"type":"string", "enum":["parent","delegated_to","depends_on"]}
            }),
            vec!["target_agent_id", "relation"],
        ),
        (
            "report_subagent_completion",
            "Report an actual completion result received from your direct subagent",
            json!({
                "parent_turn_id": {"type":"string"},
                "child_agent_id": {"type":"string"},
                "child_turn_id": {"type":"string"},
                "outcome": {"type":"string", "enum":["completed","failed","cancelled"]},
                "summary": {"type":"string"}
            }),
            vec![
                "parent_turn_id",
                "child_agent_id",
                "child_turn_id",
                "outcome",
                "summary",
            ],
        ),
        (
            "report_status",
            "Report your current turn's state and reason; does not approve execution",
            json!({
                "turn_id": {"type":"string", "description":"Your current turn_id from list_agents"},
                "summary": {"type":"string"},
                "status": {"type":"string", "enum":["running","waiting","approval","idle","error","cancelled","unknown"]}
            }),
            vec!["turn_id", "summary", "status"],
        ),
    ] {
        let mut properties = fields;
        properties["agent_id"] =
            json!({"type":"string", "description":"Your exact ID from list_agents"});
        properties["client"] =
            json!({"type":"string", "description":"Client name, for example codex, claude or pi"});
        properties["session_id"] =
            json!({"type":"string", "description":"Your actual CLI session ID"});
        tools.push(json!({
            "name": name, "description": description,
            "annotations": {"readOnlyHint": name == "read_messages"},
            "inputSchema": {"type":"object", "properties":properties, "required":required_fields, "additionalProperties":false}
        }));
    }
    tools.push(json!({
        "name":"list_agents", "description":"Find registered agent IDs, sessions and pane ownership before reporting",
        "inputSchema":{"type":"object","properties":{},"additionalProperties":false},
        "annotations":{"readOnlyHint":true}
    }));
    json!({"tools":tools})
}

pub fn local(request: &Value) -> Option<Value> {
    match request["method"].as_str()? {
        "initialize" => Some(json!({
            "protocolVersion": "2025-03-26", "capabilities":{"tools":{}},
            "serverInfo":{"name":"agent-hub","version":env!("CARGO_PKG_VERSION")},
            "instructions":format!("{INSTRUCTIONS} {MESSAGE_INSTRUCTIONS}")
        })),
        "ping" => Some(json!({})),
        "tools/list" => Some(tools()),
        _ => None,
    }
}

pub fn envelope(request: &Value, result: Value) -> Value {
    json!({"jsonrpc":"2.0", "id":request["id"], "result":result})
}

pub fn content(value: Value) -> Value {
    json!({"content":[{"type":"text", "text":value.to_string()}], "isError":false})
}

pub async fn bridge(root: &Path, request: Value, context: &Value) -> Value {
    if let Some(result) = local(&request) {
        return envelope(&request, result);
    }
    let result = async {
        let mut forwarded = request.clone();
        forwarded["params"]["_context"] = context.clone();
        ensure(root).await?.post("/mcp", &forwarded).await
    }
    .await;
    match result {
        Ok(response) => response,
        Err(error) => envelope(
            &request,
            json!({
                "content":[{"type":"text", "text":format!("Monitor unavailable: {error}. Continue your work; reporting does not grant approval.")}],
                "isError":true
            }),
        ),
    }
}

pub fn report(request: &Value, snapshot: &Snapshot) -> Result<Report> {
    let name = required(&request["params"], "name")?;
    if !matches!(
        name,
        "report_task"
            | "read_messages"
            | "ack_messages"
            | "report_step"
            | "report_relation"
            | "report_status"
            | "report_title"
            | "report_subagent_completion"
    ) {
        bail!("unknown tool");
    }
    let args = &request["params"]["arguments"];
    let context = &request["params"]["_context"];
    let location: Location =
        serde_json::from_value(context["location"].clone()).unwrap_or_default();
    let own_session = context["session_id"].as_str().unwrap_or("");
    let own_client = context["client"].as_str().unwrap_or("");
    let selected = args["agent_id"]
        .as_str()
        .and_then(|id| snapshot.agents.get(id));
    if args["agent_id"].is_string() && selected.is_none() {
        bail!("unknown agent_id; use list_agents");
    }
    let session = args["session_id"]
        .as_str()
        .filter(|value| !value.is_empty())
        .or_else(|| selected.map(|agent| agent.session_id.as_str()))
        .or_else(|| (!own_session.is_empty()).then_some(own_session))
        .context("provide your agent_id from list_agents or your session_id")?;
    let client = args["client"]
        .as_str()
        .filter(|value| !value.is_empty())
        .or_else(|| selected.map(|agent| agent.client.as_str()))
        .or_else(|| (!own_client.is_empty()).then_some(own_client))
        .context("provide client with session_id")?;
    if !own_session.is_empty() && session != own_session {
        bail!("session does not belong to this MCP connection");
    }
    if !own_client.is_empty() && client != own_client {
        bail!("client does not belong to this MCP connection");
    }
    if let Some(agent) = selected {
        if !location.pane.is_empty()
            && !agent.location.pane.is_empty()
            && (agent.location.socket != location.socket || agent.location.pane != location.pane)
        {
            bail!("agent belongs to another pane");
        }
        if agent.session_id != session || agent.client != client {
            bail!("agent_id and session/client disagree");
        }
    }
    for field in match name {
        "read_messages" | "ack_messages" => vec!["agent_id", "turn_id"],
        "report_title" => vec!["turn_id", "title"],
        "report_task" => vec!["task_id", "title", "status"],
        "report_step" => vec!["task_id", "step_id", "title", "status"],
        "report_relation" => vec!["target_agent_id", "relation"],
        "report_subagent_completion" => vec![
            "parent_turn_id",
            "child_agent_id",
            "child_turn_id",
            "outcome",
            "summary",
        ],
        _ => vec!["turn_id", "status", "summary"],
    } {
        required(args, field)?;
    }
    if matches!(name, "report_task" | "report_step")
        && !matches!(
            args["status"].as_str(),
            Some("pending" | "running" | "completed" | "blocked" | "failed" | "cancelled")
        )
    {
        bail!("unsupported task/step status");
    }
    if name == "report_relation"
        && !matches!(
            args["relation"].as_str(),
            Some("parent" | "delegated_to" | "depends_on")
        )
    {
        bail!("unsupported relationship");
    }
    let mut report = Report {
        id: uuid::Uuid::new_v4().to_string(),
        at: now(),
        client: client.into(),
        session_id: session.into(),
        parent: None,
        cwd: context["cwd"].as_str().unwrap_or("").into(),
        location,
        kind: name.into(),
        data: args.clone(),
    };
    if name == "report_subagent_completion" {
        let parent_id = format!("{client}:{session}");
        let child = snapshot
            .agents
            .get(required(args, "child_agent_id")?)
            .context("Unknown child_agent_id; use list_agents")?;
        report.client = child.client.clone();
        report.session_id = child.session_id.clone();
        report.parent = Some(parent_id.clone());
        report.location = child.location.clone();
        report.cwd = child.cwd.clone();
        report.data["parent_agent_id"] = json!(parent_id);
    }
    Ok(report)
}

use crate::ensure;
use crate::state::{now, required, Location, Report, Snapshot};
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::path::Path;

pub const INSTRUCTIONS: &str = "Report your own task start, step changes, delegation, blockers and completion. Use list_agents to find your exact agent_id, or provide client and session_id. Never report another agent's state. Lifecycle hooks report execution separately. Approval stays in the original CLI. Task and step IDs are stable identifiers you choose for this work.";

pub fn tools() -> Value {
    let mut tools = Vec::new();
    for (name, description, fields, required_fields) in [
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
            "report_status",
            "Describe progress or a blocker; does not approve execution",
            json!({
                "summary": {"type":"string"},
                "status": {"type":"string", "enum":["running","waiting","idle","error","cancelled"]}
            }),
            vec!["summary", "status"],
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
            "instructions":INSTRUCTIONS
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
        "report_task" | "report_step" | "report_relation" | "report_status"
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
        "report_task" => vec!["task_id", "title", "status"],
        "report_step" => vec!["task_id", "step_id", "title", "status"],
        "report_relation" => vec!["target_agent_id", "relation"],
        _ => vec!["status", "summary"],
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
    Ok(Report {
        id: uuid::Uuid::new_v4().to_string(),
        at: now(),
        client: client.into(),
        session_id: session.into(),
        parent: None,
        cwd: context["cwd"].as_str().unwrap_or("").into(),
        location,
        kind: name.into(),
        data: args.clone(),
    })
}

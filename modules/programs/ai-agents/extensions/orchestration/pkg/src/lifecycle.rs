use crate::state::{Agent, Report};
use serde::{Deserialize, Serialize};

#[derive(Clone, Deserialize, Serialize, PartialEq)]
pub struct ReconcileRequest {
    pub parent_run: String,
    pub child_run: String,
    pub requested_at: u64,
    pub checked_at: u64,
}

pub fn relink(agent: &mut Agent, previous: &str, current: &str) {
    if agent.parent.as_deref() == Some(previous) {
        agent.parent = Some(current.into());
    }
    for item in agent
        .tasks
        .values_mut()
        .chain(agent.steps.values_mut())
        .chain(agent.relations.iter_mut())
    {
        for key in ["agent_id", "target_agent_id"] {
            if item[key] == previous {
                item[key] = current.into();
            }
        }
    }
    for index in (0..agent.relations.len()).rev() {
        if agent.relations[..index].contains(&agent.relations[index]) {
            agent.relations.remove(index);
        }
    }
}

pub fn apply(agent: &mut Agent, report: &Report) {
    let event = report.data["event"].as_str().unwrap_or("");
    let run = report.data["run_id"].as_str().unwrap_or("");
    if !run.is_empty() && run != agent.run_id {
        if agent.run_id.is_empty() {
            if let Some(request) = &mut agent.reconcile {
                request.child_run = run.into();
                request.checked_at = 0;
            }
        } else {
            agent.reconcile = None;
            agent.observed_at = 0;
        }
        agent.run_id = run.into();
    }
    if let Some(path) = report.data["transcript_path"]
        .as_str()
        .filter(|p| !p.is_empty())
    {
        agent.transcript_path = path.into();
    }
    if let Some(native) = report.data["agent_id"].as_str().filter(|id| !id.is_empty()) {
        if agent.native_agent_id.is_empty() || matches!(event, "SubagentStart" | "SubagentStop") {
            agent.native_agent_id = native.into();
        }
    }
    if let Some(title) = report.data["title"].as_str() {
        agent.title = title.into();
    }
    let status = match event {
        "SessionStart" => Some("idle"),
        "UserPromptSubmit" | "PreToolUse" | "SubagentStart" => Some("running"),
        "PostToolUse" if report.data["is_error"] == true => Some("error"),
        "PostToolUse" => Some("running"),
        "StopFailure" => Some("error"),
        "Stop" if report.data["outcome"] == "aborted" => Some("cancelled"),
        "Stop" if report.data["outcome"] == "error" => Some("error"),
        "Stop" if report.data["proposed_plan"] == true => Some("waiting"),
        "SubagentStop" if report.data["transcript_status"] == "running" => Some("unknown"),
        "SubagentStop" if report.data["transcript_status"] == "cancelled" => Some("cancelled"),
        "Stop" | "SubagentStop" => Some("idle"),
        "SessionEnd" => Some("ended"),
        "Notification" if report.data["phase"] == "end" => {
            Some(report.data["resume_state"].as_str().unwrap_or("unknown"))
        }
        "Notification" if report.data["notification_type"] == "permission_prompt" => {
            Some("approval")
        }
        "Notification" => Some("waiting"),
        _ => None,
    };
    if let Some(status) = status {
        if report.at >= agent.observed_at {
            agent.status = status.into();
        }
    }
    if matches!(
        event,
        "Stop" | "StopFailure" | "SubagentStop" | "SessionEnd"
    ) {
        agent.reconcile = None;
    }
    if event == "SubagentStop" && report.data["transcript_status"] == "running" {
        agent.reconcile = Some(ReconcileRequest {
            parent_run: report.data["source_turn_id"].as_str().unwrap_or("").into(),
            child_run: agent.run_id.clone(),
            requested_at: report.at,
            checked_at: 0,
        });
    }
    agent.last_hook = report.at;
}

pub fn requests_children(report: &Report) -> bool {
    report.kind == "hook"
        && matches!(
            report.data["event"].as_str(),
            Some("Stop" | "StopFailure" | "SessionEnd")
        )
}

pub fn starts_turn(report: &Report) -> bool {
    report.kind == "hook" && report.data["event"] == "UserPromptSubmit"
}

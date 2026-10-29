use crate::state::{Agent, Report};

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
    let compact = event == "SessionStart" && report.data["source"] == "compact";
    if agent.turn_id.is_empty()
        || (!compact
            && (matches!(event, "SessionStart" | "UserPromptSubmit" | "SubagentStart")
                || (!run.is_empty() && run != agent.run_id)))
    {
        if agent.status != "unknown" {
            agent.last_confirmed_status = agent.status.clone();
        }
        agent.turn_id = report.id.clone();
        agent.status = "unknown".into();
        agent.state_source.clear();
        agent.state_at = 0;
        agent.completed = false;
        agent.summary.clear();
        agent.summary_at = 0;
        agent.observation_revision += 1;
        agent.observation_error.clear();
        agent.observation_priority = false;
        agent.observation_resumed = false;
        agent.prompt_pending = false;
        agent.prompt_tool_id.clear();
        agent.prompt_tool_name.clear();
    }
    if !compact && !run.is_empty() {
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
    let tool = report.data["tool_name"]
        .as_str()
        .unwrap_or("")
        .rsplit(['.', '/'])
        .next()
        .unwrap_or("")
        .rsplit("__")
        .next()
        .unwrap_or("");
    let tool_id = report.data["tool_use_id"].as_str().unwrap_or("");
    let question = matches!(
        tool,
        "AskUserQuestion" | "request_user_input" | "request_user_input_async"
    );
    let prompt = event == "Notification"
        && matches!(
            report.data["notification_type"].as_str(),
            Some("permission_prompt" | "elicitation_dialog")
        );
    if event == "PreToolUse" && !agent.prompt_pending {
        agent.prompt_tool_id = tool_id.into();
        agent.prompt_tool_name = tool.into();
    }
    let resumed = (prompt && report.data["phase"] == "end")
        || (event == "PostToolUse"
            && agent.prompt_pending
            && if !agent.prompt_tool_id.is_empty() {
                agent.prompt_tool_id == tool_id
            } else {
                !tool.is_empty() && agent.prompt_tool_name == tool
            });
    if (prompt && report.data["phase"] != "end") || (event == "PreToolUse" && question) {
        agent.prompt_pending = true;
        agent.observation_resumed = false;
        if !tool_id.is_empty() {
            agent.prompt_tool_id = tool_id.into();
        }
        if !tool.is_empty() {
            agent.prompt_tool_name = tool.into();
        }
    }
    if resumed {
        agent.prompt_pending = false;
        agent.observation_resumed = true;
    }
    let needs_observation = resumed
        || match event {
            "SessionStart" => !compact,
            "UserPromptSubmit" | "Stop" | "StopFailure" | "SessionEnd" => true,
            "Notification" => matches!(
                report.data["notification_type"].as_str(),
                Some("permission_prompt" | "elicitation_dialog" | "idle_prompt")
            ),
            "PreToolUse" => matches!(
                tool,
                "AskUserQuestion" | "request_user_input" | "request_user_input_async"
            ),
            _ => false,
        };
    if needs_observation && agent.parent.is_none() && !agent.location.pane.is_empty() {
        agent.observation_pending = true;
        agent.observation_revision += 1;
        agent.observation_error.clear();
        agent.observation_priority |= prompt || resumed || question;
    }
    agent.last_hook = report.at;
}

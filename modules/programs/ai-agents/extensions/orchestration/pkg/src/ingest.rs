use crate::state::{now, Report};
use crate::{adapter, alerts, start, Client, Config};
use anyhow::{bail, Context, Result};
use fs2::FileExt;
use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

fn public_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Array(items) => items
            .iter()
            .map(public_text)
            .filter(|text| !text.is_empty())
            .collect::<Vec<_>>()
            .join("\n"),
        Value::Object(fields) => {
            if matches!(
                fields.get("type").and_then(Value::as_str),
                Some("thinking" | "reasoning" | "image")
            ) {
                return String::new();
            }
            ["text", "content", "output", "stdout", "stderr", "result"]
                .iter()
                .filter_map(|key| fields.get(*key))
                .map(public_text)
                .filter(|text| !text.is_empty())
                .collect::<Vec<_>>()
                .join("\n")
        }
        _ => String::new(),
    }
}

async fn evidence(config: &Config, data: &Value) -> Value {
    let mut result = json!({});
    for key in [
        "prompt",
        "last_assistant_message",
        "tool_response",
        "message",
    ] {
        let text = public_text(&data[key]);
        if text.is_empty() {
            continue;
        }
        let redacted = tokio::time::timeout(Duration::from_millis(300), async {
            let mut child = tokio::process::Command::new(&config.redact)
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .kill_on_drop(true)
                .spawn()?;
            let mut input = child.stdin.take().context("Missing redact stdin")?;
            let write = async {
                input.write_all(text.as_bytes()).await?;
                drop(input);
                Ok::<_, anyhow::Error>(())
            };
            let ((), output) = tokio::try_join!(write, async {
                Ok::<_, anyhow::Error>(child.wait_with_output().await?)
            })?;
            if !output.status.success() {
                bail!("Redaction failed");
            }
            Ok::<_, anyhow::Error>(String::from_utf8(output.stdout)?)
        })
        .await;
        match redacted {
            Ok(Ok(mut text)) => {
                let mut end = text.len().min(2048);
                while !text.is_char_boundary(end) {
                    end -= 1;
                }
                if end < text.len() {
                    result["truncated"] = json!(true);
                    text.truncate(end);
                }
                while json!(text).to_string().len() > 2048 {
                    let mut end = text.len() / 2;
                    while !text.is_char_boundary(end) {
                        end -= 1;
                    }
                    text.truncate(end);
                    result["truncated"] = json!(true);
                }
                result[key] = json!(text);
            }
            _ => result["incomplete"] = json!(true),
        }
    }
    result
}

async fn publish(root: &Path, report: &Report, start_on_report: bool) -> Result<Option<Value>> {
    let pending = root.join("pending");
    std::fs::create_dir_all(&pending)?;
    let file = pending.join(format!("{}.json", report.id));
    let temp = pending.join(format!("{}.tmp", report.id));
    std::fs::write(&temp, serde_json::to_vec(report)?)?;
    std::fs::rename(temp, &file)?;
    if let Ok(client) = Client::load(root) {
        let result = tokio::time::timeout(
            Duration::from_millis(500),
            client.post("/report", &serde_json::to_value(report)?),
        )
        .await;
        if let Ok(Err(error)) = &result {
            if error
                .downcast_ref::<reqwest::Error>()
                .and_then(|error| error.status())
                .is_some_and(|status| matches!(status.as_u16(), 400 | 409 | 422))
            {
                std::fs::rename(&file, file.with_extension("rejected"))?;
                eprintln!("report rejected: {error:#}");
                return Ok(None);
            }
        }
        if let Ok(Ok(response)) = result {
            match std::fs::remove_file(file) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
            return Ok(Some(response));
        }
    }
    if start_on_report {
        let startup = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(root.join("startup.lock"))?;
        if startup.try_lock_exclusive().is_ok() {
            start(root, report.at)?;
        }
    }
    Ok(None)
}

pub fn receives_messages(report: &Report) -> bool {
    let tool = report.data["tool_name"]
        .as_str()
        .unwrap_or("")
        .rsplit(['.', '/'])
        .next()
        .unwrap_or("")
        .rsplit("__")
        .next()
        .unwrap_or("");
    report.kind == "hook"
        && matches!(report.client.as_str(), "claude" | "codex")
        && report.data["subject_verified"] == true
        && (matches!(
            report.data["event"].as_str(),
            Some("UserPromptSubmit" | "PreToolUse" | "PostToolUse")
        ) || (report.client == "claude"
            && report.data["event"] == "SubagentStart"
            && report.data["identity"] == "child"
            && report.parent.is_some()
            && report.data["agent_id"].as_str().is_some_and(|id| {
                !id.is_empty() && Some(id) != report.data["root_session_id"].as_str()
            })
            && report.data["root_session_id"].as_str() != Some(report.session_id.as_str())))
        && !matches!(
            tool,
            "read_messages" | "ack_messages" | "report_status" | "report_subagent_completion"
        )
}

pub fn inbox_output(mut inbox: Value, event: Option<&str>) -> Result<Option<(String, Value)>> {
    loop {
        let messages = inbox["messages"]
            .as_array()
            .context("Invalid inbox response")?;
        if messages.is_empty() && inbox["truncated"] != true {
            return Ok(None);
        }
        let context = format!(
            "{}\nAgentHub inbox:\n{inbox}",
            crate::mcp::MESSAGE_INSTRUCTIONS
        );
        let receipt = json!({"agent_id": inbox["agent_id"], "turn_id": inbox["turn_id"],
            "run_id": inbox["run_id"], "message_ids": messages.iter().map(|message| message["message_id"].clone()).collect::<Vec<_>>()});
        let output = if let Some(event) = event {
            json!({"hookSpecificOutput": {"hookEventName": event, "additionalContext": context}})
        } else {
            json!({"context": context, "receipt": receipt})
        };
        let encoded = serde_json::to_string(&output)?;
        if encoded.len() + 1 <= 16 * 1024 {
            return Ok(Some((encoded, receipt)));
        }
        if inbox["messages"]
            .as_array_mut()
            .context("Invalid inbox response")?
            .pop()
            .is_none()
        {
            bail!("Inbox identity exceeds the hook output limit");
        }
        inbox["truncated"] = json!(true);
    }
}

pub async fn confirm_delivery(root: &Path, receipt: &Value) -> Result<()> {
    tokio::time::timeout(
        Duration::from_millis(500),
        Client::load(root)?.post("/messages/delivered", receipt),
    )
    .await
    .context("Inbox delivery confirmation timed out")??;
    Ok(())
}

pub async fn codex_session_meta(path: &str, thread: &str) -> Result<Value> {
    let metadata = read_codex_meta(path).await?;
    if metadata["id"].as_str() != Some(thread) {
        bail!("Codex transcript metadata does not match the hook thread");
    }
    Ok(metadata)
}

async fn read_codex_meta(path: &str) -> Result<Value> {
    let file = tokio::fs::File::open(path).await?;
    let mut reader = BufReader::new(file.take(1024 * 1024));
    let mut line = String::new();
    reader.read_line(&mut line).await?;
    let record: Value = serde_json::from_str(&line)?;
    if record["type"] != "session_meta"
        || record["payload"]["id"].as_str().is_none_or(str::is_empty)
    {
        bail!("Missing Codex session metadata");
    }
    Ok(record["payload"].clone())
}

pub async fn hook(root: &Path, config: &Config) -> Result<()> {
    let received_at = now();
    let mut input = String::new();
    tokio::io::stdin()
        .take(1024 * 1024)
        .read_to_string(&mut input)
        .await?;
    let data: Value = serde_json::from_str(&input)?;
    let client = std::env::var("AI_AGENT_CLIENT")
        .unwrap_or_else(|_| "unknown".into())
        .to_lowercase();
    let session = data["session_id"]
        .as_str()
        .context("hook has no session_id")?;
    let event = data["hook_event_name"].as_str().unwrap_or("");
    let subagent_event = matches!(event, "SubagentStart" | "SubagentStop");
    let child = data["agent_id"].as_str().filter(|id| {
        matches!(client.as_str(), "claude" | "codex") && !id.is_empty() && *id != session
    });
    let mut session_id = child
        .map(|id| {
            if client == "codex" && !subagent_event {
                id.into()
            } else {
                format!("{session}/{id}")
            }
        })
        .unwrap_or_else(|| session.into());
    let mut parent = data["parent_agent_id"]
        .as_str()
        .or_else(|| data["parent_thread_id"].as_str())
        .filter(|id| !id.is_empty())
        .map(|id| {
            if id.starts_with(&format!("{client}:")) {
                id.into()
            } else {
                format!("{client}:{id}")
            }
        })
        .or_else(|| {
            child
                .filter(|_| client == "claude" || subagent_event)
                .map(|_| format!("{client}:{session}"))
        })
        .or_else(|| std::env::var("AGENT_HUB_PARENT_ID").ok());
    parent = parent.filter(|id| id != &format!("{client}:{session_id}"));
    let mut identity = if parent.is_some() || child.is_some() {
        "child"
    } else if client == "codex" {
        "unknown"
    } else {
        "root"
    };
    let mut identity_error = None;
    let transcript_path = if subagent_event {
        data["agent_transcript_path"].as_str()
    } else {
        data["transcript_path"].as_str()
    };
    let mut subject_verified = client != "codex";
    if client == "codex" && event != "SubagentStart" {
        let metadata = async {
            let path = transcript_path.context("Missing Codex subject transcript path")?;
            tokio::time::timeout(Duration::from_millis(250), async {
                if event == "SubagentStop" {
                    let metadata = read_codex_meta(path).await?;
                    let direct_parent = metadata["parent_thread_id"].as_str().or_else(|| {
                        metadata
                            .pointer("/source/subagent/thread_spawn/parent_thread_id")
                            .and_then(Value::as_str)
                    });
                    if direct_parent != Some(session) {
                        bail!("Codex child transcript does not match the reporting parent");
                    }
                    Ok(metadata)
                } else {
                    codex_session_meta(path, &session_id).await
                }
            })
            .await
            .context("Codex transcript metadata timed out")?
        }
        .await;
        match metadata {
            Ok(metadata) => {
                subject_verified = true;
                if event == "SubagentStop" {
                    session_id = metadata["id"].as_str().unwrap().to_owned();
                }
                let direct_parent = metadata["parent_thread_id"]
                    .as_str()
                    .or_else(|| {
                        metadata
                            .pointer("/source/subagent/thread_spawn/parent_thread_id")
                            .and_then(Value::as_str)
                    })
                    .filter(|id| !id.is_empty() && *id != session_id);
                if let Some(id) = direct_parent {
                    parent = Some(format!("codex:{id}"));
                    identity = "child";
                } else if metadata["source"].get("subagent").is_some() {
                    identity = "child";
                } else if identity != "child"
                    && matches!(
                        metadata["source"].as_str(),
                        Some("cli" | "vscode" | "exec" | "mcp")
                    )
                {
                    identity = "root";
                }
                if identity == "unknown" {
                    identity_error = Some("Unrecognized Codex session source".to_string());
                }
            }
            Err(error) => identity_error = Some(error.to_string()),
        }
    }
    let mut run_id = if subagent_event {
        String::new()
    } else {
        data["run_id"]
            .as_str()
            .or_else(|| data["turn_id"].as_str())
            .or_else(|| data["prompt_id"].as_str())
            .unwrap_or("")
            .to_string()
    };
    let mut transcript_status = None;
    if client == "codex" && subject_verified && run_id.is_empty() {
        if let Some(path) = transcript_path {
            if let Ok(Ok(evidence)) = tokio::time::timeout(
                Duration::from_millis(250),
                crate::reconcile::codex_run(path, &session_id),
            )
            .await
            {
                run_id = evidence.run_id;
                transcript_status = Some(evidence.status);
            }
        }
    }
    let mut fields = json!({
        "event": data["hook_event_name"],
        "agent_id": data["agent_id"],
        "agent_type": data["agent_type"],
        "source": data["source"],
        "transcript_path": if subject_verified { transcript_path } else { None },
        "subject_verified": subject_verified,
        "source_turn_id": data["turn_id"],
        "run_id": run_id,
        "transcript_status": transcript_status,
        "tool_use_id": data["tool_use_id"],
        "tool_name": data["tool_name"],
        "root_session_id": session,
        "identity": identity,
        "identity_error": identity_error,
        "notification_type": data["notification_type"],
        "phase": data["phase"],
        "resume_state": data["resume_state"],
        "outcome": data["outcome"],
        "proposed_plan": data["last_assistant_message"].as_str()
            .is_some_and(|message| message.to_lowercase().contains("<proposed_plan>")),
        "is_error": data["tool_failed"] == true || data["is_error"] == true,
    });
    fields["evidence"] = if subject_verified {
        evidence(config, &data).await
    } else {
        json!({"incomplete": true})
    };
    if data["hook_event_name"] == "Stop" {
        if let Some(message) = fields["evidence"]["last_assistant_message"].as_str() {
            fields["response_excerpt"] = json!(alerts::excerpt(message));
        }
    }
    if let Some(title) = data["session_title"].as_str() {
        fields["title"] = json!(title);
    }
    if let Some(summary) = fields["evidence"]["message"]
        .as_str()
        .or_else(|| data["tool_name"].as_str())
    {
        fields["summary"] = json!(summary.chars().take(2000).collect::<String>());
    }
    let at = data["reported_at"].as_u64().unwrap_or(received_at);
    let registered = adapter(config, "register", &json!({"client":client,"session_id":session_id,"parent":parent,"identity":identity,"event":data["hook_event_name"],"at":at})).await
        .ok().and_then(|value| serde_json::from_value(value).ok()).unwrap_or_default();
    let report = Report {
        id: data["event_id"]
            .as_str()
            .filter(|id| !id.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
        at,
        client,
        session_id,
        parent,
        cwd: data["cwd"].as_str().unwrap_or("").into(),
        location: registered,
        kind: "hook".into(),
        data: fields,
    };
    if let Some(response) = publish(root, &report, config.notifications.is_some()).await? {
        if let Some(inbox) = response.get("inbox") {
            match inbox_output(inbox.clone(), Some(event)) {
                Ok(Some((output, receipt))) => {
                    {
                        use std::io::Write;
                        let mut stdout = std::io::stdout().lock();
                        writeln!(stdout, "{output}")?;
                        stdout.flush()?;
                    }
                    if let Err(error) = confirm_delivery(root, &receipt).await {
                        eprintln!("cannot confirm inbox delivery: {error}");
                    }
                }
                Ok(None) => {}
                Err(error) => eprintln!("cannot render inbox: {error}"),
            }
        }
    }
    Ok(())
}

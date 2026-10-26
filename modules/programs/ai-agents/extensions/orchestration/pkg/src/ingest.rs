use crate::state::{now, Report};
use crate::{adapter, alerts, start, Client, Config};
use anyhow::{bail, Context, Result};
use fs2::FileExt;
use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};

async fn publish(root: &Path, report: &Report, start_on_report: bool) -> Result<()> {
    let pending = root.join("pending");
    std::fs::create_dir_all(&pending)?;
    let file = pending.join(format!("{}.json", report.id));
    let temp = pending.join(format!("{}.tmp", report.id));
    std::fs::write(&temp, serde_json::to_vec(report)?)?;
    std::fs::rename(temp, &file)?;
    if let Ok(client) = Client::load(root) {
        if matches!(
            tokio::time::timeout(
                Duration::from_millis(500),
                client.post("/report", &serde_json::to_value(report)?),
            )
            .await,
            Ok(Ok(_))
        ) {
            match std::fs::remove_file(file) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
            return Ok(());
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
    if data["hook_event_name"] == "Stop" {
        if let Some(message) = data["last_assistant_message"].as_str() {
            fields["response_excerpt"] = json!(alerts::excerpt(message));
        }
    }
    if let Some(title) = data["session_title"].as_str() {
        fields["title"] = json!(title);
    }
    if let Some(summary) = data["message"]
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
    publish(root, &report, config.notifications.is_some()).await
}

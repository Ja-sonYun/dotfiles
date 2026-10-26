use crate::ingest::codex_session_meta;
use crate::state::Agent;
use anyhow::{Context, Result};
use serde_json::Value;
use std::io::SeekFrom;
use tokio::io::{AsyncReadExt, AsyncSeekExt};

pub struct Evidence {
    pub run_id: String,
    pub status: &'static str,
}

pub async fn codex_run(path: &str, session: &str) -> Result<Evidence> {
    codex_session_meta(path, session).await?;
    let mut file = tokio::fs::File::open(path).await?;
    let offset = file.metadata().await?.len().saturating_sub(1024 * 1024);
    file.seek(SeekFrom::Start(offset)).await?;
    let mut bytes = Vec::new();
    file.take(1024 * 1024).read_to_end(&mut bytes).await?;
    let mut lines = bytes.split(|byte| *byte == b'\n');
    if offset != 0 {
        lines.next();
    }
    let mut evidence: Option<Evidence> = None;
    for line in lines {
        let Ok(record) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        if record["type"] != "event_msg" {
            continue;
        }
        let payload = &record["payload"];
        let Some(run) = payload["turn_id"].as_str().filter(|id| !id.is_empty()) else {
            continue;
        };
        let status = match payload["type"].as_str() {
            Some("task_started") => "running",
            Some("task_complete") => "idle",
            Some("turn_aborted") => "cancelled",
            _ => continue,
        };
        evidence = Some(Evidence {
            run_id: run.into(),
            status,
        });
    }
    evidence.context("No identified Codex turn in the transcript tail")
}

pub async fn inspect(agent: &Agent) -> Option<Evidence> {
    if agent.client != "codex" || agent.transcript_path.is_empty() || agent.run_id.is_empty() {
        return None;
    }
    let evidence = tokio::time::timeout(
        std::time::Duration::from_secs(1),
        codex_run(&agent.transcript_path, &agent.session_id),
    )
    .await
    .ok()?
    .ok()?;
    (evidence.run_id == agent.run_id).then_some(evidence)
}

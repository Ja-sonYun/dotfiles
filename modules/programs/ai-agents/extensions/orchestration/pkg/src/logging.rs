use serde_json::Value;
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;
use tokio::sync::{mpsc, oneshot};

#[derive(Clone, Default)]
pub struct Logger(Option<mpsc::Sender<Vec<String>>>);

impl Logger {
    pub fn start(
        command: Option<String>,
    ) -> (
        Self,
        Option<(oneshot::Sender<()>, tokio::task::JoinHandle<()>)>,
    ) {
        let Some(command) = command else {
            return (Self::default(), None);
        };
        let (stop, mut stopped) = oneshot::channel();
        let (send, mut receive) = mpsc::channel::<Vec<String>>(64);
        let worker = tokio::spawn(async move {
            loop {
                let args = tokio::select! {
                    _ = &mut stopped => break,
                    args = receive.recv() => match args { Some(args) => args, None => break },
                };
                let Ok(mut child) = Command::new(&command)
                    .args(args)
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .kill_on_drop(true)
                    .spawn()
                else {
                    continue;
                };
                let stop = tokio::select! {
                    _ = &mut stopped => true,
                    result = tokio::time::timeout(Duration::from_secs(1), child.wait()) => {
                        if matches!(result, Ok(Ok(_))) { continue; }
                        false
                    },
                };
                let _ = child.kill().await;
                let _ = child.wait().await;
                if stop {
                    break;
                }
            }
        });
        (Self(Some(send)), Some((stop, worker)))
    }

    pub fn record(&self, level: &str, event: &str, fields: &Value) {
        let Some(send) = &self.0 else { return };
        let level = if level == "warn" { "warning" } else { level };
        let mut args = vec!["agent-hub".into(), level.into(), event.into()];
        for key in [
            "agent_id",
            "turn_id",
            "observation_revision",
            "model",
            "reasoning",
            "attempt",
            "queue_ms",
            "capture_ms",
            "prompt_ms",
            "total_ms",
            "outcome",
            "reason",
            "cause",
            "stage",
        ] {
            let value = &fields[key];
            if let Some(value) = value.as_str() {
                args.push(format!("{key}={value}"));
            } else if value.is_number() {
                args.push(format!("{key}={value}"));
            }
        }
        let _ = send.try_send(args);
    }
}

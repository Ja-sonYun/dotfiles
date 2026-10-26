mod alerts;
mod graph;
mod hub;
mod ingest;
mod lifecycle;
mod mcp;
mod reconcile;
mod state;
mod terminal;
mod tui;

use anyhow::{bail, Context, Result};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use state::{now, Location};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;

#[derive(Clone, Deserialize)]
pub struct Config {
    pub node: String,
    pub runner: String,
    pub sdk: String,
    pub model: String,
    pub tmux_adapter: Option<String>,
    pub notifications: Option<alerts::Settings>,
}

#[derive(Clone, Deserialize, Serialize)]
pub struct Endpoint {
    pub url: String,
    pub token: String,
}

#[derive(Clone)]
pub struct Client {
    pub endpoint: Endpoint,
    http: reqwest::Client,
}

impl Client {
    pub fn load(root: &Path) -> Result<Self> {
        Ok(Self {
            endpoint: serde_json::from_slice(&std::fs::read(root.join("endpoint.json"))?)?,
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(20))
                .build()?,
        })
    }

    pub async fn post(&self, route: &str, body: &Value) -> Result<Value> {
        let response = self
            .http
            .post(format!("{}{route}", self.endpoint.url))
            .bearer_auth(&self.endpoint.token)
            .json(body)
            .send()
            .await?;
        let status = response.status();
        let text = response.text().await?;
        if !status.is_success() {
            bail!("hub {status}: {text}");
        }
        if text.is_empty() {
            return Ok(Value::Null);
        }
        Ok(serde_json::from_str(&text)?)
    }
}

pub fn root() -> Result<PathBuf> {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")))
        .context("HOME is not set")?;
    let root = base.join("agent-hub");
    std::fs::create_dir_all(&root)?;
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))?;
    Ok(root)
}

pub fn config() -> Result<Config> {
    let path = std::env::var("AGENT_HUB_CONFIG").context("run the configured agent-hub wrapper")?;
    Ok(serde_json::from_slice(&std::fs::read(path)?)?)
}

pub fn runtime() -> Result<String> {
    Ok(format!(
        "{}:{}",
        std::env::current_exe()?.display(),
        std::env::var("AGENT_HUB_CONFIG")?
    ))
}

pub async fn adapter(config: &Config, operation: &str, value: &Value) -> Result<Value> {
    let mut child = Command::new(&config.node)
        .arg(
            config
                .tmux_adapter
                .as_ref()
                .context("tmux integration is disabled")?,
        )
        .arg(operation)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()?;
    child
        .stdin
        .take()
        .context("adapter stdin")?
        .write_all(value.to_string().as_bytes())
        .await?;
    let output = tokio::time::timeout(Duration::from_secs(3), child.wait_with_output()).await??;
    if !output.status.success() {
        bail!("{}", String::from_utf8_lossy(&output.stderr));
    }
    Ok(serde_json::from_slice(&output.stdout)?)
}

pub async fn location(config: &Config) -> Location {
    tokio::time::timeout(
        Duration::from_millis(800),
        adapter(config, "location", &Value::Null),
    )
    .await
    .ok()
    .and_then(Result::ok)
    .and_then(|value| serde_json::from_value(value).ok())
    .unwrap_or_default()
}

fn start(root: &Path, fresh_since: u64) -> Result<()> {
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(root.join("hub.log"))?;
    let mut command = Command::new(std::env::current_exe()?);
    command
        .arg("serve")
        .env("AGENT_HUB_FRESH_SINCE", fresh_since.to_string())
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log);
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command.spawn()?;
    tokio::spawn(async move {
        let _ = child.wait().await;
    });
    Ok(())
}

async fn ensure(root: &Path) -> Result<Client> {
    ensure_runtime(root, false).await
}

async fn ensure_runtime(root: &Path, replace: bool) -> Result<Client> {
    let expected = runtime()?;
    let startup = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(root.join("startup.lock"))?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    while startup.try_lock_exclusive().is_err() {
        if tokio::time::Instant::now() >= deadline {
            bail!("hub restart is still in progress");
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let mut started = false;
    while tokio::time::Instant::now() < deadline {
        if let Ok(client) = Client::load(root) {
            if let Ok(Ok(snapshot)) = tokio::time::timeout(
                Duration::from_millis(500),
                client.post("/snapshot", &Value::Null),
            )
            .await
            {
                if !replace || snapshot["runtime"].as_str() == Some(expected.as_str()) {
                    return Ok(client);
                }
                client.post("/stop", &Value::Null).await?;
                let lock = std::fs::OpenOptions::new()
                    .create(true)
                    .truncate(false)
                    .write(true)
                    .open(root.join("hub.lock"))?;
                loop {
                    if lock.try_lock_exclusive().is_ok() {
                        break;
                    }
                    if tokio::time::Instant::now() >= deadline {
                        bail!("previous hub has not finished shutting down");
                    }
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
                started = false;
            }
        }
        if !started {
            start(root, now())?;
            started = true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    bail!("hub did not start; see {}", root.join("hub.log").display())
}

#[tokio::main]
async fn main() -> Result<()> {
    let root = root()?;
    let config = config()?;
    match std::env::args().nth(1).as_deref().unwrap_or("tui") {
        "serve" => hub::serve(root, config).await,
        "hook" => ingest::hook(&root, &config).await,
        "mcp" => {
            let context = json!({
                "client": std::env::var("AI_AGENT_CLIENT").unwrap_or_default().to_lowercase(),
                "session_id": std::env::var("AGENT_HUB_SESSION_ID").unwrap_or_default(),
                "location": location(&config).await,
                "cwd": std::env::current_dir()?.to_string_lossy(),
            });
            let mut lines = BufReader::new(tokio::io::stdin()).lines();
            let mut stdout = tokio::io::stdout();
            while let Some(line) = lines.next_line().await? {
                let request: Value = serde_json::from_str(&line)?;
                if request.get("id").is_none() {
                    continue;
                }
                let result = mcp::bridge(&root, request, &context).await;
                stdout.write_all(format!("{result}\n").as_bytes()).await?;
                stdout.flush().await?;
            }
            Ok(())
        }
        "stop" => {
            Client::load(&root)?.post("/stop", &Value::Null).await?;
            Ok(())
        }
        "tui" => {
            let client = ensure_runtime(&root, true).await?;
            tui::run(client, config).await
        }
        _ => bail!("usage: agent-hub [tui|stop|hook|mcp]"),
    }
}

use crate::state::{Report, Store};
use crate::{alerts, mcp, Config, Endpoint};
use anyhow::{Context, Result};
use axum::extract::{DefaultBodyLimit, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use axum::{Json, Router};
use fs2::FileExt;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::{mpsc, oneshot, Notify};
use tokio::task::JoinSet;

#[derive(Clone)]
struct App {
    store: Arc<Mutex<Store>>,
    token: String,
    commands: mpsc::Sender<Value>,
    stop: Arc<Notify>,
    alerts: Arc<Mutex<alerts::Alerts>>,
    notifications: Option<alerts::Settings>,
    deliveries: Arc<Mutex<JoinSet<()>>>,
}

impl App {
    async fn notify(&self, text: &str) -> Result<()> {
        let settings = self
            .notifications
            .clone()
            .context("Desktop notifications are disabled")?;
        let text = text.to_string();
        let (reply, result) = oneshot::channel();
        {
            let mut deliveries = self.deliveries.lock().unwrap();
            while let Some(result) = deliveries.try_join_next() {
                if let Err(error) = result {
                    eprintln!("notification task failed: {error}");
                }
            }
            deliveries.spawn(async move {
                let result = alerts::send(&settings, &text).await;
                if let Err(Err(error)) = reply.send(result) {
                    eprintln!("notification request failed after caller disconnected: {error}");
                }
            });
        }
        result
            .await
            .context("Notification task stopped before replying")?
    }

    fn ingest(&self, report: Report) -> Result<String> {
        let mut store = self.store.lock().unwrap();
        let id = format!("{}:{}", report.client, report.session_id);
        let before = store.snapshot.agents.get(&id).cloned();
        let revision = store.snapshot.revision;
        let id = store.report(report.clone())?;
        if revision != store.snapshot.revision {
            self.alerts.lock().unwrap().receive(
                &report,
                before.as_ref(),
                &store.snapshot.agents[&id],
                store.live.contains(&id),
            );
        }
        Ok(id)
    }
}

fn authorize(app: &App, headers: &HeaderMap) -> Result<()> {
    let expected = format!("Bearer {}", app.token);
    if headers
        .get("authorization")
        .and_then(|header| header.to_str().ok())
        != Some(expected.as_str())
    {
        anyhow::bail!("unauthorized");
    }
    Ok(())
}

fn response(result: Result<Value>) -> Response {
    match result {
        Ok(value) => Json(value).into_response(),
        Err(error) => (StatusCode::BAD_REQUEST, error.to_string()).into_response(),
    }
}

async fn snapshot(State(app): State<App>, headers: HeaderMap) -> Response {
    response((|| {
        authorize(&app, &headers)?;
        let store = app.store.lock().unwrap();
        let mut snapshot = serde_json::to_value(store.view())?;
        snapshot["progress_version"] = json!(app.alerts.lock().unwrap().version);
        Ok(snapshot)
    })())
}

async fn report(State(app): State<App>, headers: HeaderMap, Json(value): Json<Report>) -> Response {
    response((|| {
        authorize(&app, &headers)?;
        Ok(json!({"agent_id":app.ingest(value)?}))
    })())
}

async fn mcp_request(
    State(app): State<App>,
    headers: HeaderMap,
    Json(request): Json<Value>,
) -> Response {
    if authorize(&app, &headers).is_err() {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if request.get("id").is_none() {
        return StatusCode::ACCEPTED.into_response();
    }
    if let Some(result) = mcp::local(&request) {
        return Json(mcp::envelope(&request, result)).into_response();
    }
    let result = (|| -> Result<Value> {
        if request["method"] != "tools/call" {
            anyhow::bail!("unknown method");
        }
        if request["params"]["name"] == "list_agents" {
            return Ok(mcp::content(json!(app.store.lock().unwrap().view().agents)));
        }
        let report = mcp::report(&request, &app.store.lock().unwrap().snapshot)?;
        Ok(mcp::content(json!({"agent_id":app.ingest(report)?})))
    })();
    Json(match result {
        Ok(value) => mcp::envelope(&request, value),
        Err(error) => mcp::envelope(
            &request,
            json!({
                "isError":true, "content":[{"type":"text","text":error.to_string()}]
            }),
        ),
    })
    .into_response()
}

async fn pi_command(
    State(app): State<App>,
    headers: HeaderMap,
    Json(value): Json<Value>,
) -> Response {
    response((|| {
        authorize(&app, &headers)?;
        match value["type"].as_str() {
            Some("prompt") => {
                let text = crate::state::required(&value, "text")?;
                let mut store = app.store.lock().unwrap();
                let mut command = value.clone();
                command["history"] = json!(store.snapshot.chat);
                command["scope"] = json!(store.snapshot.scope);
                app.commands.try_send(command)?;
                store.chat("user", text, None)?;
            }
            Some("abort") => app.commands.try_send(value)?,
            _ => anyhow::bail!("unsupported Pi command"),
        }
        Ok(json!({"accepted":true}))
    })())
}

async fn notify_user(
    State(app): State<App>,
    headers: HeaderMap,
    Json(value): Json<Value>,
) -> Response {
    let result = async {
        authorize(&app, &headers)?;
        let text = crate::state::required(&value, "text")?;
        match app.notify(text).await {
            Ok(()) => {
                if value["origin"] != "scheduled_summary" {
                    app.store
                        .lock()
                        .unwrap()
                        .chat("notice", text, value["scope"].as_str())?;
                }
                Ok(json!({"status":"requested"}))
            }
            Err(error) => {
                let _ = app.store.lock().unwrap().chat(
                    "error",
                    &format!("Notification request failed: {error}"),
                    value["scope"].as_str(),
                );
                Err(error)
            }
        }
    }
    .await;
    response(result)
}

async fn stop(State(app): State<App>, headers: HeaderMap) -> Response {
    response((|| {
        authorize(&app, &headers)?;
        app.stop.notify_one();
        Ok(json!({"stopping":true}))
    })())
}

async fn scope(State(app): State<App>, headers: HeaderMap, Json(value): Json<Value>) -> Response {
    response((|| {
        authorize(&app, &headers)?;
        let scope = crate::state::required(&value, "scope")?;
        let mut store = app.store.lock().unwrap();
        if store.snapshot.scope != scope {
            app.commands.try_send(json!({"type":"abort"}))?;
            store.set_scope(scope)?;
            store.snapshot.pi_text.clear();
            store.snapshot.pi_status = "idle".into();
            *app.alerts.lock().unwrap() =
                alerts::Alerts::new(app.notifications.clone(), crate::state::now());
        }
        Ok(json!({"accepted":true}))
    })())
}

pub async fn serve(root: PathBuf, config: Config) -> Result<()> {
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(root.join("hub.lock"))?;
    if lock.try_lock_exclusive().is_err() {
        return Ok(());
    }
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let endpoint = Endpoint {
        url: format!("http://{}", listener.local_addr()?),
        token: uuid::Uuid::new_v4().to_string(),
    };
    let (commands, mut receive) = mpsc::channel::<Value>(128);
    let fresh_since = std::env::var("AGENT_HUB_FRESH_SINCE")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or_else(crate::state::now);
    let app = App {
        store: Arc::new(Mutex::new(Store::open(
            &root.join("state.sqlite3"),
            fresh_since,
        )?)),
        token: endpoint.token.clone(),
        commands,
        stop: Arc::new(Notify::new()),
        alerts: Arc::new(Mutex::new(alerts::Alerts::new(
            config.notifications.clone(),
            fresh_since,
        ))),
        notifications: config.notifications.clone(),
        deliveries: Arc::new(Mutex::new(JoinSet::new())),
    };
    app.store.lock().unwrap().snapshot.runtime = crate::runtime()?;
    let observer_app = app.clone();
    let observer_config = config.clone();
    let observer = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(2));
        let mut prune_at = Instant::now();
        loop {
            interval.tick().await;
            let sampled = observer_app.store.lock().unwrap().snapshot.agents.clone();
            let agents: Vec<_> = sampled.values().collect();
            match crate::adapter(&observer_config, "observe", &json!(agents)).await {
                Ok(states) => {
                    let mut store = observer_app.store.lock().unwrap();
                    store.observe(&sampled, &states);
                    observer_app
                        .alerts
                        .lock()
                        .unwrap()
                        .observed(&sampled, &states, &store.live);
                    if Instant::now() >= prune_at {
                        if let Err(error) = store.prune() {
                            eprintln!("history retention failed: {error}");
                        }
                        prune_at = Instant::now() + Duration::from_secs(3600);
                    }
                }
                Err(error) => eprintln!("agent observation unavailable: {error}"),
            }
        }
    });
    let mut child = Command::new(&config.node)
        .arg(&config.runner)
        .env("AGENT_HUB_STATE", &root)
        .env("AGENT_HUB_SCOPE", &app.store.lock().unwrap().snapshot.scope)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .process_group(0)
        .kill_on_drop(true)
        .spawn()?;
    let process_group = child.id().context("Pi process has no pid")? as i32;
    let mut input = child.stdin.take().context("Pi stdin")?;
    let output = child.stdout.take().context("Pi stdout")?;
    let writer = tokio::spawn(async move {
        while let Some(value) = receive.recv().await {
            if input
                .write_all(format!("{value}\n").as_bytes())
                .await
                .is_err()
            {
                break;
            }
        }
    });
    let reader_app = app.clone();
    let reader = tokio::spawn(async move {
        let mut lines = BufReader::new(output).lines();
        let mut partial = String::new();
        let mut partial_scope = String::new();
        while let Ok(Some(line)) = lines.next_line().await {
            let Ok(value) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            let mut store = reader_app.store.lock().unwrap();
            let scope = value["scope"].as_str().unwrap_or("");
            let current = scope == store.snapshot.scope;
            let result = match value["type"].as_str() {
                Some("text_delta") => {
                    partial.push_str(value["delta"].as_str().unwrap_or(""));
                    partial_scope = scope.into();
                    if current {
                        store.snapshot.pi_text = partial.clone();
                        store.snapshot.pi_status = "streaming".into();
                    }
                    Ok(())
                }
                Some("settled") => {
                    let result = if partial.is_empty() {
                        Ok(())
                    } else {
                        store.chat(
                            if value["outcome"] == "idle" {
                                "pi"
                            } else {
                                "interrupted"
                            },
                            &partial,
                            Some(&partial_scope),
                        )
                    };
                    partial.clear();
                    if current {
                        store.snapshot.pi_text.clear();
                        store.snapshot.pi_status =
                            value["outcome"].as_str().unwrap_or("idle").into();
                    }
                    result
                }
                Some("notice") => {
                    store.chat("notice", value["text"].as_str().unwrap_or(""), Some(scope))
                }
                Some("error") => {
                    if current {
                        store.snapshot.pi_status = "error".into();
                    }
                    store.chat(
                        "error",
                        value["message"].as_str().unwrap_or("Pi error"),
                        Some(scope),
                    )
                }
                Some("status") => {
                    if current {
                        store.snapshot.pi_status =
                            value["status"].as_str().unwrap_or("unknown").into();
                    }
                    Ok(())
                }
                Some("tool") => store.chat(
                    "tool",
                    value["name"].as_str().unwrap_or("query"),
                    Some(scope),
                ),
                _ => Ok(()),
            };
            if let Err(error) = result {
                eprintln!("cannot persist Pi message: {error}");
            }
            store.snapshot.revision += 1;
        }
        let mut store = reader_app.store.lock().unwrap();
        store.snapshot.pi_status = "disconnected".into();
        if !partial.is_empty() {
            let _ = store.chat("interrupted", &partial, Some(&partial_scope));
        }
        store.snapshot.pi_text.clear();
    });
    std::fs::write(root.join("endpoint.tmp"), serde_json::to_vec(&endpoint)?)?;
    std::fs::rename(root.join("endpoint.tmp"), root.join("endpoint.json"))?;
    let pending_app = app.clone();
    let pending_root = root.clone();
    let publisher = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(1));
        loop {
            interval.tick().await;
            let Ok(entries) = std::fs::read_dir(pending_root.join("pending")) else {
                continue;
            };
            let mut reports = Vec::new();
            for entry in entries.flatten() {
                if entry.path().extension().and_then(|ext| ext.to_str()) != Some("json") {
                    continue;
                }
                if let Ok(bytes) = std::fs::read(entry.path()) {
                    if let Ok(report) = serde_json::from_slice::<Report>(&bytes) {
                        reports.push((entry.path(), report));
                    }
                }
            }
            reports.sort_by_key(|(_, report)| report.at);
            for (path, report) in reports {
                match pending_app.ingest(report) {
                    Ok(_) => {
                        let _ = std::fs::remove_file(path);
                    }
                    Err(error) => eprintln!("cannot ingest {}: {error}", path.display()),
                }
            }
        }
    });
    let notifier = config.notifications.clone().map(|settings| {
        let notify_app = app.clone();
        tokio::spawn(async move {
            let period = Duration::from_secs(settings.summary_interval_seconds.max(1));
            let mut next_summary = Instant::now() + period;
            let mut interval = tokio::time::interval(Duration::from_millis(100));
            loop {
                interval.tick().await;
                let notices = notify_app.alerts.lock().unwrap().due();
                let scope = notify_app.store.lock().unwrap().snapshot.scope.clone();
                for text in notices {
                    let result = notify_app.notify(&text).await;
                    let mut store = notify_app.store.lock().unwrap();
                    let result = match result {
                        Ok(()) => store.chat("notice", &text, Some(&scope)),
                        Err(error) => store.chat(
                            "error",
                            &format!("Notification request failed: {error}"),
                            Some(&scope),
                        ),
                    };
                    if let Err(error) = result {
                        eprintln!("cannot persist notification result: {error}");
                    }
                }
                if Instant::now() >= next_summary {
                    next_summary = Instant::now() + period;
                    let active = alerts::active(&notify_app.store.lock().unwrap().view());
                    if active && notify_app.alerts.lock().unwrap().version > 0 {
                        if let Err(error) = notify_app.commands.try_send(json!({"type":"summary"}))
                        {
                            eprintln!("cannot request progress summary: {error}");
                        }
                    }
                }
            }
        })
    });
    let shutdown = app.stop.clone();
    let router = Router::new()
        .route("/snapshot", post(snapshot))
        .route("/report", post(report))
        .route("/mcp", post(mcp_request))
        .route("/pi", post(pi_command))
        .route("/notify", post(notify_user))
        .route("/stop", post(stop))
        .route("/scope", post(scope))
        .layer(DefaultBodyLimit::max(1024 * 1024))
        .with_state(app.clone());
    let result = axum::serve(listener, router)
        .with_graceful_shutdown(async move {
            let mut terminate =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).unwrap();
            tokio::select! {
                _ = shutdown.notified() => {}
                _ = tokio::signal::ctrl_c() => {}
                _ = terminate.recv() => {}
            }
        })
        .await;
    publisher.abort();
    observer.abort();
    if let Some(notifier) = notifier {
        notifier.abort();
        let _ = notifier.await;
    }
    let _ = app.commands.try_send(json!({"type":"shutdown"}));
    let mut deliveries = std::mem::take(&mut *app.deliveries.lock().unwrap());
    while let Some(result) = deliveries.join_next().await {
        if let Err(error) = result {
            eprintln!("notification task failed during shutdown: {error}");
        }
    }
    // Keep the owned leader unreaped until group cleanup prevents PID reuse.
    tokio::time::sleep(Duration::from_secs(3)).await;
    unsafe {
        libc::kill(-process_group, libc::SIGTERM);
    }
    tokio::time::sleep(Duration::from_secs(2)).await;
    if unsafe { libc::kill(-process_group, 0) } == 0 {
        unsafe {
            libc::kill(-process_group, libc::SIGKILL);
        }
    }
    let _ = child.wait().await;
    writer.abort();
    reader.abort();
    std::fs::remove_file(root.join("endpoint.json"))?;
    result?;
    Ok(())
}

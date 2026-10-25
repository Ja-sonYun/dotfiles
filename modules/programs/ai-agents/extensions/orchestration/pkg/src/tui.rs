use crate::graph::{clean, status_color, status_label, width, Graph, GraphWidget};
use crate::state::Snapshot;
use crate::terminal::{combine_results, EmbeddedTerminal};
use crate::{adapter, Client, Config};
use anyhow::{Context, Result};
use crossterm::event::{
    self, DisableBracketedPaste, EnableBracketedPaste, Event, KeyCode, KeyEventKind, KeyModifiers,
};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};
use ratatui::{Frame, Terminal};
use serde_json::{json, Value};
use std::io::stdout;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

struct Screen;

impl Drop for Screen {
    fn drop(&mut self) {
        let _ = execute!(stdout(), DisableBracketedPaste, LeaveAlternateScreen);
        let _ = disable_raw_mode();
    }
}

#[derive(Default)]
struct Input {
    text: String,
    cursor: usize,
    revision: u64,
}

impl Input {
    fn insert(&mut self, text: &str) {
        let text: String = text
            .chars()
            .map(|c| {
                if matches!(c, '\n' | '\r' | '\t') {
                    ' '
                } else {
                    c
                }
            })
            .filter(|c| !c.is_control())
            .collect();
        self.text.insert_str(self.cursor, &text);
        self.cursor += text.len();
        self.revision += 1;
    }

    fn left(&self) -> usize {
        self.text[..self.cursor]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0)
    }

    fn right(&self) -> usize {
        self.cursor
            + self.text[self.cursor..]
                .chars()
                .next()
                .map(char::len_utf8)
                .unwrap_or(0)
    }

    fn erase(&mut self, backwards: bool) {
        let (start, end) = if backwards {
            (self.left(), self.cursor)
        } else {
            (self.cursor, self.right())
        };
        self.text.replace_range(start..end, "");
        self.cursor = start;
        self.revision += 1;
    }

    fn view(&self, columns: usize) -> (String, usize) {
        if columns == 0 {
            return (String::new(), 0);
        }
        let mut start = self.cursor;
        for (index, _) in self.text[..self.cursor].char_indices().rev() {
            if width(&self.text[index..self.cursor]) >= columns {
                break;
            }
            start = index;
        }
        let mut end = self.cursor;
        for (index, c) in self.text[self.cursor..].char_indices() {
            let next = self.cursor + index + c.len_utf8();
            if width(&self.text[start..next]) > columns {
                break;
            }
            end = next;
        }
        (
            self.text[start..end].to_string(),
            width(&self.text[start..self.cursor]),
        )
    }

    fn accept(&mut self, revision: u64) {
        if self.revision == revision {
            self.text.clear();
            self.cursor = 0;
            self.revision += 1;
        }
    }
}

fn inline_spans(mut text: &str) -> Vec<Span<'static>> {
    let mut spans = Vec::new();
    while !text.is_empty() {
        let marker = ["**", "`"]
            .into_iter()
            .filter_map(|marker| text.find(marker).map(|at| (at, marker)))
            .min_by_key(|(at, _)| *at);
        let Some((at, marker)) = marker else {
            spans.push(Span::raw(text.to_string()));
            break;
        };
        let rest = &text[at + marker.len()..];
        let Some(end) = rest.find(marker) else {
            spans.push(Span::raw(text.to_string()));
            break;
        };
        if at > 0 {
            spans.push(Span::raw(text[..at].to_string()));
        }
        if marker == "**" {
            spans.extend(inline_spans(&rest[..end]).into_iter().map(|mut span| {
                span.style = span.style.add_modifier(Modifier::BOLD);
                span
            }));
        } else {
            spans.push(Span::styled(
                rest[..end].to_string(),
                Style::default().fg(Color::LightCyan),
            ));
        }
        text = &rest[end + marker.len()..];
    }
    spans
}

fn chat_message(role: &str, color: Color, text: &str, columns: usize) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(Span::styled(
        role.to_string(),
        Style::default().fg(color).add_modifier(Modifier::BOLD),
    ))];
    let columns = columns.max(1);
    for source in clean(text).trim().lines() {
        if source.trim().is_empty() {
            if lines.last().is_some_and(|line| !line.spans.is_empty()) {
                lines.push(Line::default());
            }
            continue;
        }
        let body = source.trim_start();
        let marker = ["- ", "* ", "• "]
            .into_iter()
            .find(|marker| body.starts_with(marker))
            .or_else(|| {
                let (number, _) = body.split_once(". ")?;
                (!number.is_empty() && number.chars().all(|c| c.is_ascii_digit()))
                    .then_some(&body[..number.len() + 2])
            })
            .unwrap_or("");
        let indent = (2 + width(source) - width(body)).min(columns.saturating_sub(2));
        let prefix = format!("{}{marker}", " ".repeat(indent));
        let padding = width(&prefix).min(columns.saturating_sub(1));
        let prefix = if width(&prefix) < columns {
            prefix
        } else {
            " ".repeat(padding)
        };
        let mut row = vec![Span::raw(prefix)];
        let mut cells = padding;
        for span in inline_spans(&body[marker.len()..]) {
            for word in span.content.split_inclusive(char::is_whitespace) {
                if cells > padding
                    && width(word) <= columns - padding
                    && cells + width(word) > columns
                {
                    lines.push(Line::from(std::mem::take(&mut row)));
                    row.push(Span::raw(" ".repeat(padding)));
                    cells = padding;
                }
                for c in word.chars() {
                    let size = width(&c.to_string());
                    if cells + size > columns && cells > padding {
                        lines.push(Line::from(std::mem::take(&mut row)));
                        row.push(Span::raw(" ".repeat(padding)));
                        cells = padding;
                    }
                    if let Some(last) = row.last_mut().filter(|last| last.style == span.style) {
                        last.content.to_mut().push(c);
                    } else {
                        row.push(Span::styled(c.to_string(), span.style));
                    }
                    cells += size;
                }
            }
        }
        lines.push(Line::from(row));
    }
    lines.push(Line::default());
    lines
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum CloseIntent {
    Graph,
    Popup,
}

#[derive(Default)]
enum Connection {
    #[default]
    Idle,
    Starting {
        task: JoinHandle<Result<EmbeddedTerminal>>,
        close: Option<CloseIntent>,
    },
    Attached(EmbeddedTerminal),
    Stopping {
        task: JoinHandle<Result<()>>,
        intent: CloseIntent,
    },
}

impl Connection {
    fn terminal(&self) -> Option<&EmbeddedTerminal> {
        match self {
            Self::Attached(terminal) => Some(terminal),
            _ => None,
        }
    }

    fn terminal_mut(&mut self) -> Option<&mut EmbeddedTerminal> {
        match self {
            Self::Attached(terminal) => Some(terminal),
            _ => None,
        }
    }

    fn is_starting(&self) -> bool {
        matches!(self, Self::Starting { .. })
    }

    fn is_stopping(&self) -> bool {
        matches!(
            self,
            Self::Starting { close: Some(_), .. } | Self::Stopping { .. }
        )
    }

    fn is_finished(&self) -> bool {
        match self {
            Self::Starting { task, .. } => task.is_finished(),
            Self::Stopping { task, .. } => task.is_finished(),
            _ => false,
        }
    }

    fn stop(&mut self, intent: CloseIntent) {
        *self = match std::mem::take(self) {
            Self::Starting { task, close } => Self::Starting {
                task,
                close: Some(if close == Some(CloseIntent::Popup) {
                    CloseIntent::Popup
                } else {
                    intent
                }),
            },
            Self::Attached(terminal) => Self::Stopping {
                task: tokio::spawn(terminal.stop()),
                intent,
            },
            Self::Stopping {
                task,
                intent: previous,
            } => Self::Stopping {
                task,
                intent: if previous == CloseIntent::Popup {
                    previous
                } else {
                    intent
                },
            },
            Self::Idle => Self::Idle,
        };
    }

    async fn shutdown(self) -> Result<()> {
        match self {
            Self::Idle => Ok(()),
            Self::Starting { task, .. } => {
                task.await
                    .context("Agent attachment task failed")??
                    .stop()
                    .await
            }
            Self::Attached(terminal) => terminal.stop().await,
            Self::Stopping { task, .. } => task.await.context("Agent disconnect task failed")?,
        }
    }
}

#[derive(Default)]
struct Ui {
    snapshot: Snapshot,
    graph: Graph,
    input: Input,
    editing: bool,
    sending: bool,
    connection: Connection,
    connected: bool,
    message: String,
    graph_area: Rect,
    chat_scroll: Option<usize>,
    chat_bottom: usize,
    chat_height: usize,
    chat_lines: Vec<Line<'static>>,
    chat_width: u16,
    chat_dirty: bool,
    history: bool,
    details: bool,
    spinner: usize,
    graph_dirty: bool,
    restore_graph: Option<Value>,
    restore_chat: Option<Option<usize>>,
}

impl Ui {
    fn stop_agent(&mut self, intent: CloseIntent) {
        self.editing = false;
        self.connection.stop(intent);
    }

    fn displayed(&self) -> Snapshot {
        let mut snapshot = Snapshot {
            agents: if self.history {
                self.snapshot.history.clone()
            } else {
                self.snapshot.agents.clone()
            },
            ..Snapshot::default()
        };
        if self.history {
            let ids: std::collections::BTreeMap<_, _> = snapshot
                .agents
                .iter()
                .map(|(key, agent)| {
                    (
                        (agent.location.scope.clone(), agent.id.clone()),
                        key.clone(),
                    )
                })
                .collect();
            for (key, agent) in &mut snapshot.agents {
                agent.id = key.clone();
                agent.parent = agent.parent.as_ref().and_then(|id| {
                    ids.get(&(agent.location.scope.clone(), id.clone()))
                        .cloned()
                });
                for relation in &mut agent.relations {
                    if let Some(id) = relation["target_agent_id"].as_str() {
                        if let Some(key) = ids.get(&(agent.location.scope.clone(), id.into())) {
                            relation["target_agent_id"] = json!(key);
                        }
                    }
                }
            }
        }
        snapshot
    }

    fn view(&self) -> Value {
        json!({"graph":self.restore_graph.clone().unwrap_or_else(|| self.graph.view()),"chat_scroll":self.restore_chat.unwrap_or(self.chat_scroll),"history":self.history})
    }

    fn chat(&self, columns: usize) -> Vec<Line<'static>> {
        let mut lines = Vec::new();
        for message in if self.history {
            &self.snapshot.history_chat
        } else {
            &self.snapshot.chat
        } {
            let (role, color) = match message["role"].as_str() {
                Some("user") => ("You", Color::LightCyan),
                Some("notice") => ("Notice", status_color("idle")),
                Some("error") => ("Error", status_color("error")),
                Some("interrupted") => ("Interrupted", status_color("cancelled")),
                Some("tool") => ("Tool", status_color("idle")),
                _ => ("Pi", Color::LightMagenta),
            };
            let text = message["text"].as_str().unwrap_or("");
            let text = if message["role"] == "tool" {
                match text {
                    "get_agents" => "Agent status",
                    "get_events" => "Recent activity",
                    "get_pane_output" => "Pane output",
                    "notify_user" => "Notice",
                    _ => text,
                }
            } else {
                text
            };
            lines.extend(chat_message(role, color, text, columns));
        }
        if !self.history && !self.snapshot.pi_text.is_empty() {
            lines.extend(chat_message(
                "Pi",
                Color::LightMagenta,
                &self.snapshot.pi_text,
                columns,
            ));
        }
        lines
    }

    fn draw(&mut self, frame: &mut Frame) {
        let sections = Layout::vertical([
            Constraint::Length(1),
            Constraint::Min(3),
            Constraint::Length((frame.area().height / 4).max(4)),
            Constraint::Length(3),
        ])
        .split(frame.area());
        let running = self
            .snapshot
            .agents
            .values()
            .filter(|a| a.status == "running")
            .count();
        let approval = self
            .snapshot
            .agents
            .values()
            .filter(|a| a.status == "approval")
            .count();
        let waiting = self
            .snapshot
            .agents
            .values()
            .filter(|a| a.status == "waiting")
            .count();
        let ended = self.snapshot.history.len();
        let visible = if self.history {
            ended
        } else {
            self.snapshot.agents.len()
        };
        let mut header = vec![
            Span::styled(
                " AGENT HUB ",
                Style::default()
                    .fg(Color::LightCyan)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!(
                    "· {} · {visible} agents ",
                    if self.editing {
                        "Input"
                    } else if self.connection.terminal().is_some() {
                        "Agent"
                    } else {
                        "Graph"
                    }
                ),
                Style::default().fg(Color::White),
            ),
            Span::styled(
                format!("· Running {running} "),
                Style::default().fg(Color::Cyan),
            ),
            Span::styled(
                format!("· Approval {approval} · Waiting {waiting}"),
                Style::default().fg(Color::Yellow),
            ),
        ];
        if !self.connected {
            header.push(Span::styled(
                " · Disconnected",
                Style::default().fg(Color::LightRed),
            ));
        }
        frame.render_widget(Paragraph::new(Line::from(header)), sections[0]);
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(if self.editing {
                Color::Gray
            } else {
                Color::LightBlue
            }))
            .title(if let Some(embedded) = self.connection.terminal() {
                format!(" Agent · {} ", clean(&embedded.title))
            } else {
                format!(
                    " {} · Zoom {}/5 · e: {} ({ended}) · d: Details · q: Detach ",
                    if self.history {
                        "History · 30 days"
                    } else {
                        "Current"
                    },
                    self.graph.zoom + 1,
                    if self.history { "Current" } else { "History" },
                )
            });
        let area = block.inner(sections[1]);
        if self.connected
            && self.connection.terminal().is_none()
            && area.width > 0
            && area.height > 0
            && (self.graph_dirty || area != self.graph_area)
        {
            self.graph_area = area;
            let displayed = self.displayed();
            if !displayed.agents.is_empty() {
                let restore = self.restore_graph.take();
                if let Some(view) = &restore {
                    self.graph.restore(view);
                }
                self.graph.sync(&displayed, area);
                if let Some(view) = restore {
                    if view["selected"]
                        .as_str()
                        .is_some_and(|id| displayed.agents.contains_key(id))
                    {
                        self.graph.pan =
                            serde_json::from_value(view["pan"].clone()).unwrap_or_default();
                    } else {
                        self.graph.pan = (0, 0);
                        self.graph.reveal(area);
                    }
                }
            } else {
                self.graph.sync(&displayed, area);
            }
            self.graph_dirty = false;
        }
        frame.render_widget(block, sections[1]);
        if let Some(embedded) = self.connection.terminal_mut() {
            self.graph_area = area;
            if let Err(error) = embedded.resize(area.height, area.width) {
                self.message = error.to_string();
            }
            frame.render_widget(
                tui_term::widget::PseudoTerminal::new(embedded.parser.screen())
                    .cursor(tui_term::widget::Cursor::default().visibility(false)),
                area,
            );
            if !self.editing && !embedded.parser.screen().hide_cursor() {
                let (row, col) = embedded.parser.screen().cursor_position();
                if row < area.height && col < area.width {
                    frame.set_cursor_position((area.x + col, area.y + row));
                }
            }
        } else if visible == 0 {
            frame.render_widget(
                Paragraph::new(if ended > 0 {
                    "No current CLI sessions · Press e for history"
                } else {
                    "Waiting for agent reports"
                })
                .style(Style::default().fg(Color::Gray)),
                self.graph_area,
            );
        } else if self.details {
            if let Some(agent) = self.graph.selected.as_ref().and_then(|id| {
                if self.history {
                    self.snapshot.history.get(id)
                } else {
                    self.snapshot.agents.get(id)
                }
            }) {
                frame.render_widget(
                    Paragraph::new(format!(
                        "{}\n{}\n{}\nSession: {}\nPane: {}\nScope: {}\n\nd: Back",
                        agent.id,
                        agent.title,
                        agent.cwd,
                        agent.location.session,
                        agent.location.pane,
                        agent.location.scope
                    ))
                    .wrap(ratatui::widgets::Wrap { trim: false }),
                    self.graph_area,
                );
            }
        } else {
            frame.render_widget(
                GraphWidget {
                    graph: &self.graph,
                    spinner: (!self.history && self.connected)
                        .then_some(['-', '/', '|', '\\'][self.spinner]),
                },
                self.graph_area,
            );
        }
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(status_color(&self.snapshot.pi_status)))
            .title(format!(" Pi · {} ", status_label(&self.snapshot.pi_status)));
        let area = block.inner(sections[2]);
        if self.chat_dirty || self.chat_width != area.width {
            self.chat_lines = self.chat(area.width.max(1) as usize);
            self.chat_width = area.width;
            self.chat_dirty = false;
        }
        self.chat_height = area.height as usize;
        self.chat_bottom = self.chat_lines.len().saturating_sub(self.chat_height);
        if self.connected && area.width > 0 && area.height > 0 {
            if let Some(scroll) = self.restore_chat.take() {
                self.chat_scroll = scroll;
            }
        }
        let top = self
            .chat_scroll
            .unwrap_or(self.chat_bottom)
            .min(self.chat_bottom);
        if self.chat_scroll.is_some() {
            self.chat_scroll = Some(top);
        }
        frame.render_widget(block, sections[2]);
        frame.render_widget(
            Paragraph::new(
                self.chat_lines
                    .iter()
                    .skip(top)
                    .take(self.chat_height)
                    .cloned()
                    .collect::<Vec<_>>(),
            ),
            area,
        );
        let title = if !self.message.is_empty() {
            format!(" {} ", clean(&self.message).replace('\n', " "))
        } else if self.sending {
            " Sending ".into()
        } else if self.connection.is_stopping() {
            " Disconnecting agent ".into()
        } else if self.connection.is_starting()
            || self
                .connection
                .terminal()
                .is_some_and(|embedded| !embedded.ready)
        {
            " Checking session ".into()
        } else {
            " Prompt ".into()
        };
        let block = Block::default()
            .borders(Borders::ALL)
            .title(title)
            .border_style(Style::default().fg(
                if !self.message.is_empty() || self.sending || self.connection.is_starting() {
                    Color::Yellow
                } else if self.editing {
                    Color::LightCyan
                } else {
                    Color::Gray
                },
            ));
        let area = block.inner(sections[3]);
        let (text, cursor) = self.input.view(area.width as usize);
        frame.render_widget(block, sections[3]);
        frame.render_widget(
            Paragraph::new(text).style(Style::default().fg(Color::LightCyan)),
            area,
        );
        if self.editing && area.width > 0 && area.height > 0 {
            frame.set_cursor_position((area.x + cursor as u16, area.y));
        }
    }

    fn scroll(&mut self, up: bool) {
        let top = self.chat_scroll.unwrap_or(self.chat_bottom);
        let next = if up {
            top.saturating_sub(self.chat_height.max(1))
        } else {
            top.saturating_add(self.chat_height.max(1))
                .min(self.chat_bottom)
        };
        self.chat_scroll = if next == self.chat_bottom {
            None
        } else {
            Some(next)
        };
    }
}

enum Update {
    Snapshot(Result<Snapshot>),
    Prompt(u64, Result<Value>),
    Abort(Result<Value>),
    Shutdown,
}

pub async fn run(client: Client, config: Config) -> Result<()> {
    let monitor = adapter(&config, "view-load", &Value::Null).await?;
    client
        .post("/scope", &json!({"scope":monitor["scope"]}))
        .await?;
    let (updates, mut receive) = mpsc::channel::<Update>(16);
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut hangup = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::hangup())?;
    let shutdown_updates = updates.clone();
    let shutdown_task = tokio::spawn(async move {
        tokio::select! {
            _ = terminate.recv() => {},
            _ = hangup.recv() => {},
        }
        let _ = shutdown_updates.send(Update::Shutdown).await;
    });
    let polling = updates.clone();
    let snapshot_client = client.clone();
    let snapshot_task = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_millis(500));
        loop {
            interval.tick().await;
            let result = snapshot_client
                .post("/snapshot", &Value::Null)
                .await
                .and_then(|value| Ok(serde_json::from_value(value)?));
            if polling.send(Update::Snapshot(result)).await.is_err() {
                break;
            }
        }
    });
    enable_raw_mode()?;
    let guard = Screen;
    execute!(stdout(), EnterAlternateScreen, EnableBracketedPaste)?;
    let mut terminal = Terminal::new(CrosstermBackend::new(stdout()))?;
    let mut ui = Ui::default();
    let restored = &monitor["view"];
    ui.history = restored["history"].as_bool().unwrap_or(false);
    if !restored.is_null() {
        ui.graph.restore(&restored["graph"]);
        ui.restore_graph = Some(restored["graph"].clone());
        ui.restore_chat = Some(restored["chat_scroll"].as_u64().map(|value| value as usize));
    }
    let mut saved_view = ui.view();
    let mut saved_at = Instant::now();
    let frame_interval = Duration::from_millis(16);
    let mut last_frame = Instant::now() - frame_interval;
    let mut last_animation = Instant::now();
    let mut dirty = true;
    let result: Result<()> = async {
        loop {
            while let Ok(update) = receive.try_recv() {
                match update {
                    Update::Shutdown => return Ok(()),
                    Update::Snapshot(Ok(snapshot)) => {
                        if ui.connection.terminal().is_some()
                            && ui
                                .graph
                                .selected
                                .as_ref()
                                .is_some_and(|id| !snapshot.agents.contains_key(id))
                        {
                            ui.message = "Agent session ended".into();
                            ui.stop_agent(CloseIntent::Graph);
                        }
                        if snapshot != ui.snapshot || !ui.connected {
                            ui.chat_dirty |= snapshot.chat != ui.snapshot.chat
                                || snapshot.history_chat != ui.snapshot.history_chat
                                || snapshot.pi_text != ui.snapshot.pi_text;
                            ui.snapshot = snapshot;
                            ui.graph_dirty = true;
                            ui.connected = true;
                            dirty = true;
                        }
                    }
                    Update::Snapshot(Err(_)) => {
                        dirty |= ui.connected;
                        ui.connected = false;
                    }
                    Update::Prompt(revision, result) => {
                        dirty = true;
                        ui.sending = false;
                        match result {
                            Ok(_) => {
                                ui.input.accept(revision);
                                ui.message.clear();
                                ui.chat_scroll = None;
                            }
                            Err(error) => ui.message = format!("Send failed: {error}"),
                        }
                    }
                    Update::Abort(result) => {
                        dirty = true;
                        ui.message = match result {
                            Ok(_) => "Response cancellation requested".into(),
                            Err(error) => format!("Abort failed: {error}"),
                        }
                    }
                }
            }
            if ui.connection.is_finished() {
                dirty = true;
                match std::mem::take(&mut ui.connection) {
                    Connection::Starting { task, close } => {
                        match task
                            .await
                            .context("Agent attachment task failed")
                            .and_then(|result| result)
                        {
                            Ok(embedded) => {
                                ui.connection = Connection::Attached(embedded);
                                ui.editing = false;
                                ui.message.clear();
                                if let Some(intent) = close {
                                    ui.stop_agent(intent);
                                }
                            }
                            Err(error) => ui.message = format!("Attach failed: {error:#}"),
                        }
                    }
                    Connection::Stopping { task, intent } => {
                        ui.graph_dirty = true;
                        match task
                            .await
                            .context("Agent disconnect task failed")
                            .and_then(|result| result)
                        {
                            Err(error) => {
                                if !ui.message.is_empty() {
                                    ui.message.push_str("; ");
                                }
                                ui.message
                                    .push_str(&format!("Disconnect failed: {error:#}"));
                            }
                            Ok(()) if intent == CloseIntent::Popup => {
                                ui.message = match save_view(&config, &monitor, &ui).await {
                                    Ok(()) => adapter(&config, "detach", &Value::Null)
                                        .await
                                        .err()
                                        .map(|error| error.to_string())
                                        .unwrap_or_default(),
                                    Err(error) => format!("Cannot save view: {error}"),
                                };
                            }
                            Ok(()) => {}
                        }
                    }
                    connection => ui.connection = connection,
                }
            }
            if let Some(embedded) = ui.connection.terminal_mut() {
                match embedded.poll() {
                    Ok(changed) => dirty |= changed,
                    Err(error) => {
                        ui.message = error.to_string();
                        ui.stop_agent(CloseIntent::Graph);
                        dirty = true;
                    }
                }
            }
            let batch_started = Instant::now();
            let mut events = 0;
            while events < 256
                && batch_started.elapsed() < Duration::from_millis(4)
                && event::poll(Duration::ZERO)?
            {
                events += 1;
                dirty = true;
                match event::read()? {
                    Event::Paste(text) if ui.editing => ui.input.insert(&text),
                    Event::Paste(text) if ui.connection.terminal().is_some() => {
                        if let Some(embedded) = ui.connection.terminal() {
                            if let Err(error) = embedded.paste(&text) {
                                ui.message = error.to_string();
                            }
                        }
                    }
                    Event::Key(key) if key.kind != KeyEventKind::Release => {
                        if !ui.editing
                            && ui
                                .connection
                                .terminal()
                                .is_some_and(EmbeddedTerminal::interrupt_pending)
                        {
                            if let Some(embedded) = ui.connection.terminal_mut() {
                                if let Err(error) = embedded.key(key) {
                                    ui.message = error.to_string();
                                }
                            }
                            continue;
                        }
                        if key.modifiers.contains(KeyModifiers::CONTROL)
                            && key.code == KeyCode::Char('g')
                            && ui.connection.terminal().is_some()
                        {
                            ui.editing = !ui.editing;
                            if let Some(embedded) = ui.connection.terminal_mut() {
                                embedded.clear_prefix();
                            }
                            continue;
                        }
                        if key.modifiers.contains(KeyModifiers::CONTROL)
                            && matches!(key.code, KeyCode::Char('c' | 'f'))
                            && !matches!(ui.connection, Connection::Idle)
                        {
                            ui.stop_agent(if key.code == KeyCode::Char('f') {
                                CloseIntent::Popup
                            } else {
                                CloseIntent::Graph
                            });
                            continue;
                        }
                        if ui.connection.is_stopping() {
                            continue;
                        }
                        if !ui.editing {
                            if let Some(embedded) = ui.connection.terminal_mut() {
                                if let Err(error) = embedded.key(key) {
                                    ui.message = error.to_string();
                                }
                                continue;
                            }
                        }
                        if key.modifiers.contains(KeyModifiers::CONTROL) {
                            match key.code {
                                KeyCode::Char('c' | 'f') => {
                                    ui.message = match save_view(&config, &monitor, &ui).await {
                                        Ok(()) => adapter(&config, "detach", &Value::Null)
                                            .await
                                            .err()
                                            .map(|error| error.to_string())
                                            .unwrap_or_default(),
                                        Err(error) => format!("Cannot save view: {error}"),
                                    };
                                }
                                KeyCode::Char('x') => {
                                    let client = client.clone();
                                    let updates = updates.clone();
                                    tokio::spawn(async move {
                                        let _ = updates
                                            .send(Update::Abort(
                                                client.post("/pi", &json!({"type":"abort"})).await,
                                            ))
                                            .await;
                                    });
                                }
                                _ => {}
                            }
                            continue;
                        }
                        if matches!(key.code, KeyCode::PageUp | KeyCode::PageDown) {
                            ui.scroll(key.code == KeyCode::PageUp);
                            continue;
                        }
                        if ui.editing {
                            match key.code {
                                KeyCode::Esc => ui.editing = false,
                                KeyCode::Enter
                                    if !ui.sending && !ui.input.text.trim().is_empty() =>
                                {
                                    ui.sending = true;
                                    ui.message.clear();
                                    let text = ui.input.text.clone();
                                    let revision = ui.input.revision;
                                    let client = client.clone();
                                    let updates = updates.clone();
                                    tokio::spawn(async move {
                                        let result = client
                                            .post("/pi", &json!({"type":"prompt","text":text}))
                                            .await;
                                        let _ =
                                            updates.send(Update::Prompt(revision, result)).await;
                                    });
                                }
                                KeyCode::Left => ui.input.cursor = ui.input.left(),
                                KeyCode::Right => ui.input.cursor = ui.input.right(),
                                KeyCode::Home => ui.input.cursor = 0,
                                KeyCode::End => ui.input.cursor = ui.input.text.len(),
                                KeyCode::Backspace => ui.input.erase(true),
                                KeyCode::Delete => ui.input.erase(false),
                                KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::ALT) => {
                                    ui.input.insert(&c.to_string())
                                }
                                _ => {}
                            }
                            continue;
                        }
                        if ui.connection.is_starting() {
                            continue;
                        }
                        match key.code {
                            KeyCode::Char('q') => {
                                ui.message = match save_view(&config, &monitor, &ui).await {
                                    Ok(()) => adapter(&config, "detach", &Value::Null)
                                        .await
                                        .err()
                                        .map(|error| error.to_string())
                                        .unwrap_or_default(),
                                    Err(error) => format!("Cannot save view: {error}"),
                                };
                            }
                            KeyCode::Char('i') => ui.editing = true,
                            KeyCode::Char('e') => {
                                ui.history = !ui.history;
                                ui.chat_dirty = true;
                                ui.chat_scroll = None;
                                ui.graph.sync(&ui.displayed(), ui.graph_area);
                                ui.graph.reveal(ui.graph_area);
                            }
                            KeyCode::Char('d') => ui.details = !ui.details,
                            KeyCode::Left => ui.graph.pan.0 = ui.graph.pan.0.saturating_sub(4),
                            KeyCode::Right => ui.graph.pan.0 = ui.graph.pan.0.saturating_add(4),
                            KeyCode::Down => ui.graph.pan.1 = ui.graph.pan.1.saturating_add(2),
                            KeyCode::Up => ui.graph.pan.1 = ui.graph.pan.1.saturating_sub(2),
                            KeyCode::Char('h') => ui.graph.select_direction(-1, 0, ui.graph_area),
                            KeyCode::Char('l') => ui.graph.select_direction(1, 0, ui.graph_area),
                            KeyCode::Char('j') => ui.graph.select_direction(0, 1, ui.graph_area),
                            KeyCode::Char('k') => ui.graph.select_direction(0, -1, ui.graph_area),
                            KeyCode::Char('J') => {
                                ui.graph.zoom(true, ui.graph_area, &ui.displayed())
                            }
                            KeyCode::Char('K') => {
                                ui.graph.zoom(false, ui.graph_area, &ui.displayed())
                            }
                            KeyCode::Tab => ui.graph.select(false, ui.graph_area),
                            KeyCode::BackTab => ui.graph.select(true, ui.graph_area),
                            KeyCode::Enter if matches!(ui.connection, Connection::Idle) => {
                                if ui.history {
                                    ui.message =
                                        "History has no live CLI to attach to · e: Current".into();
                                    continue;
                                }
                                if let Some(agent) = ui
                                    .graph
                                    .selected
                                    .as_ref()
                                    .and_then(|id| ui.snapshot.agents.get(id))
                                {
                                    let location = serde_json::to_value(&agent.location)?;
                                    let title = if agent.title.is_empty() {
                                        agent.id.clone()
                                    } else {
                                        agent.title.clone()
                                    };
                                    let area = ui.graph_area;
                                    let config = config.clone();
                                    ui.connection = Connection::Starting {
                                        task: tokio::spawn(EmbeddedTerminal::start(
                                            config,
                                            location,
                                            title,
                                            area.height,
                                            area.width,
                                        )),
                                        close: None,
                                    };
                                }
                            }
                            _ => {}
                        }
                    }
                    _ => {}
                }
            }
            if ui.restore_graph.is_none()
                && ui.restore_chat.is_none()
                && saved_at.elapsed() >= Duration::from_millis(500)
                && ui.view() != saved_view
            {
                match save_view(&config, &monitor, &ui).await {
                    Ok(_) => saved_view = ui.view(),
                    Err(error) => ui.message = format!("Cannot save view: {error}"),
                }
                saved_at = Instant::now();
            }
            if ui.connected
                && ui.connection.terminal().is_none()
                && !ui.history
                && !ui.details
                && ui.graph.has_running(ui.graph_area)
                && last_animation.elapsed() >= Duration::from_millis(100)
            {
                ui.spinner = (ui.spinner + 1) % 4;
                last_animation = Instant::now();
                dirty = true;
            }
            if dirty && last_frame.elapsed() >= frame_interval {
                terminal.draw(|frame| ui.draw(frame))?;
                dirty = false;
                last_frame = Instant::now();
            }
            if event::poll(Duration::ZERO)? {
                tokio::task::yield_now().await;
            } else {
                let wait = if dirty {
                    frame_interval.saturating_sub(last_frame.elapsed())
                } else {
                    frame_interval
                };
                event::poll(wait)?;
            }
        }
    }
    .await;
    snapshot_task.abort();
    shutdown_task.abort();
    receive.close();
    let cleanup = std::mem::take(&mut ui.connection).shutdown().await;
    drop(terminal);
    drop(guard);
    combine_results(result, cleanup)
}

async fn save_view(config: &Config, monitor: &Value, ui: &Ui) -> Result<()> {
    adapter(
        config,
        "view-save",
        &json!({"scope":monitor["scope"],"view":ui.view()}),
    )
    .await?;
    Ok(())
}

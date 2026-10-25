use crate::state::{agent_label, Agent, Snapshot};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::Span;
use ratatui::widgets::Widget;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

pub fn width(text: &str) -> usize {
    Span::raw(text).width()
}

pub fn clean(text: &str) -> String {
    text.chars()
        .filter(|c| !c.is_control() || *c == '\n')
        .collect()
}

pub fn status_label(status: &str) -> &str {
    match status {
        "running" => "Running",
        "waiting" => "Waiting for input",
        "approval" => "Awaiting approval",
        "idle" => "Idle",
        "error" | "failed" => "Error",
        "cancelled" => "Cancelled",
        "ended" => "Ended",
        "completed" => "Completed",
        "blocked" => "Blocked",
        "pending" => "Pending",
        "starting" => "Starting",
        "thinking" => "Thinking",
        "streaming" => "Responding",
        "disconnected" => "Disconnected",
        _ => "Unknown",
    }
}

pub fn status_color(status: &str) -> Color {
    match status {
        "running" | "starting" | "thinking" | "streaming" => Color::Rgb(108, 190, 197),
        "waiting" | "approval" | "blocked" | "pending" | "cancelled" => Color::Rgb(218, 184, 114),
        "error" | "failed" | "disconnected" => Color::Rgb(221, 132, 132),
        "completed" => Color::Rgb(145, 190, 148),
        "idle" => Color::Rgb(145, 170, 197),
        _ => Color::Rgb(155, 165, 172),
    }
}

struct Node {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    lines: Vec<(String, Style)>,
    status: String,
}

pub struct Graph {
    slots: BTreeMap<String, (usize, usize)>,
    nodes: BTreeMap<String, Node>,
    edges: BTreeMap<(i32, i32), (u8, bool)>,
    annotations: Vec<(i32, i32, String, bool)>,
    pub selected: Option<String>,
    pub zoom: u8,
    pub pan: (i32, i32),
}

impl Default for Graph {
    fn default() -> Self {
        Self {
            slots: BTreeMap::new(),
            nodes: BTreeMap::new(),
            edges: BTreeMap::new(),
            annotations: Vec::new(),
            selected: None,
            zoom: 1,
            pan: (0, 0),
        }
    }
}

impl Graph {
    pub fn view(&self) -> Value {
        json!({"slots":self.slots,"selected":self.selected,"zoom":self.zoom,"pan":self.pan})
    }

    pub fn restore(&mut self, value: &Value) {
        self.slots = serde_json::from_value(value["slots"].clone()).unwrap_or_default();
        self.selected = value["selected"].as_str().map(String::from);
        self.zoom = value["zoom"].as_u64().unwrap_or(1).min(4) as u8;
        self.pan = serde_json::from_value(value["pan"].clone()).unwrap_or_default();
    }

    pub fn sync(&mut self, snapshot: &Snapshot, area: Rect) {
        let mut snapshot = snapshot.clone();
        let parents = parents(&snapshot);
        for (id, parent) in parents {
            snapshot.agents.get_mut(&id).unwrap().parent = Some(parent);
        }
        let snapshot = &snapshot;
        let previous = self
            .selected
            .as_ref()
            .and_then(|id| self.nodes.get(id).map(|node| (id.clone(), node.x, node.y)));
        self.slots.retain(|id, _| snapshot.agents.contains_key(id));
        let mut topology = Vec::new();
        for agent in snapshot.agents.values() {
            let mut ancestors = BTreeSet::new();
            let mut current = agent;
            let mut depth = 0;
            while let Some(parent) = current
                .parent
                .as_ref()
                .and_then(|id| snapshot.agents.get(id))
            {
                if !ancestors.insert(parent.id.clone()) || parent.id == agent.id {
                    depth = 0;
                    break;
                }
                depth += 1;
                current = parent;
            }
            topology.push((depth, agent.id.clone()));
        }
        topology.sort();
        for (column, id) in topology {
            if self.slots.get(&id).is_some_and(|slot| slot.0 == column) {
                continue;
            }
            let mut row = snapshot.agents[&id]
                .parent
                .as_ref()
                .and_then(|parent| self.slots.get(parent))
                .map(|slot| slot.1)
                .unwrap_or(0);
            while self
                .slots
                .iter()
                .any(|(other, slot)| other != &id && *slot == (column, row))
            {
                row += 1;
            }
            self.slots.insert(id, (column, row));
        }
        if self
            .selected
            .as_ref()
            .is_none_or(|id| !self.slots.contains_key(id))
        {
            self.selected = self
                .slots
                .iter()
                .min_by_key(|(id, (column, row))| (*row, *column, *id))
                .map(|(id, _)| id.clone());
        }
        self.layout(snapshot, area);
        if let Some((id, x, y)) = previous {
            if let Some(node) = self.nodes.get(&id) {
                self.pan.0 = self.pan.0.saturating_add(node.x - x);
                self.pan.1 = self.pan.1.saturating_add(node.y - y);
            } else {
                self.pan = (0, 0);
                self.reveal(area);
            }
        }
    }

    fn layout(&mut self, snapshot: &Snapshot, area: Rect) {
        let limit = [28, 40, 52, 72, 92][self.zoom as usize];
        let mut columns = BTreeMap::<usize, i32>::new();
        let mut rows = BTreeMap::<usize, i32>::new();
        self.nodes.clear();
        for (id, agent) in &snapshot.agents {
            if !self.slots.contains_key(id) {
                continue;
            }
            let subagent = agent.parent.as_ref().is_some_and(|parent| parent != id)
                || agent.relations.iter().any(|relation| {
                    relation["relation"] == "parent"
                        && relation["target_agent_id"]
                            .as_str()
                            .is_some_and(|parent| parent != id)
                })
                || snapshot.agents.values().any(|parent| {
                    parent.id != *id
                        && parent.relations.iter().any(|relation| {
                            relation["relation"] == "delegated_to"
                                && relation["target_agent_id"].as_str() == Some(id.as_str())
                        })
                });
            let lines: Vec<_> = node_lines(agent, self.zoom, subagent)
                .into_iter()
                .flat_map(|(line, style)| {
                    let mut lines = if self.zoom <= 2 {
                        vec![shorten(&line, limit - 4)]
                    } else {
                        wrap(&line, limit - 4)
                    };
                    if self.zoom == 3 && lines.len() > 3 {
                        lines.truncate(3);
                        if let Some(last) = lines.last_mut() {
                            last.push('…');
                            *last = shorten(last, limit - 4);
                        }
                    }
                    lines.into_iter().enumerate().map(move |(index, line)| {
                        (line, if index == 0 { style } else { Style::default() })
                    })
                })
                .collect();
            let node_width = lines
                .iter()
                .map(|(line, _)| width(line) as i32 + 4)
                .max()
                .unwrap_or(4);
            let node_height = lines.len() as i32 + 2;
            let (column, row) = self.slots[id];
            columns
                .entry(column)
                .and_modify(|w| *w = (*w).max(node_width))
                .or_insert(node_width);
            rows.entry(row)
                .and_modify(|h| *h = (*h).max(node_height))
                .or_insert(node_height);
            self.nodes.insert(
                id.clone(),
                Node {
                    x: 0,
                    y: 0,
                    width: node_width,
                    height: node_height,
                    lines,
                    status: agent.status.clone(),
                },
            );
        }
        for (id, node) in &mut self.nodes {
            let (column, row) = self.slots[id];
            node.x = 1 + columns.range(..column).map(|(_, w)| w + 6).sum::<i32>();
            node.y = 1 + rows.range(..row).map(|(_, h)| h + 1).sum::<i32>();
            node.width = columns[&column];
        }
        let parents = parents(snapshot);
        let mut groups = BTreeMap::<String, Vec<String>>::new();
        for id in self.nodes.keys() {
            let mut root = id;
            let mut seen = BTreeSet::new();
            while let Some(parent) = parents.get(root) {
                if !seen.insert(root) {
                    break;
                }
                root = parent;
            }
            groups.entry(root.clone()).or_default().push(id.clone());
        }
        let (mut x, mut y, mut row_height) = (1, 1, 0);
        for ids in groups.values() {
            let left = ids.iter().map(|id| self.nodes[id].x).min().unwrap_or(0);
            let top = ids.iter().map(|id| self.nodes[id].y).min().unwrap_or(0);
            let width = ids
                .iter()
                .map(|id| self.nodes[id].x + self.nodes[id].width - left)
                .max()
                .unwrap_or(0);
            let height = ids
                .iter()
                .map(|id| self.nodes[id].y + self.nodes[id].height - top)
                .max()
                .unwrap_or(0);
            if x > 1 && x + width > i32::from(area.width) {
                x = 1;
                y += row_height + 2;
                row_height = 0;
            }
            for id in ids {
                let node = self.nodes.get_mut(id).unwrap();
                node.x += x - left;
                node.y += y - top;
            }
            x += width + 4;
            row_height = row_height.max(height);
        }
        self.edges.clear();
        self.annotations.clear();
        let mut relations = BTreeSet::new();
        for agent in snapshot.agents.values() {
            if let Some(parent) = &agent.parent {
                relations.insert((parent.clone(), agent.id.clone(), false));
            }
            for relation in &agent.relations {
                let Some(target) = relation["target_agent_id"].as_str() else {
                    continue;
                };
                match relation["relation"].as_str() {
                    Some("parent") => {
                        relations.insert((target.into(), agent.id.clone(), false));
                    }
                    Some("delegated_to") => {
                        relations.insert((agent.id.clone(), target.into(), false));
                    }
                    Some("depends_on") => {
                        relations.insert((agent.id.clone(), target.into(), true));
                    }
                    _ => {}
                }
            }
        }
        for (from, to, dashed) in relations {
            if from == to {
                continue;
            }
            let (Some(source), Some(target)) = (self.nodes.get(&from), self.nodes.get(&to)) else {
                continue;
            };
            let forward = target.x > source.x;
            let same_column = target.x == source.x;
            let start = (
                if forward || same_column {
                    source.x + source.width
                } else {
                    source.x - 1
                },
                source.y + source.height / 2,
            );
            let end = (
                if forward {
                    target.x - 1
                } else {
                    target.x + target.width
                },
                target.y + target.height / 2,
            );
            let middle = if same_column {
                start.0.max(end.0) + 2
            } else {
                (start.0 + end.0) / 2
            };
            self.segment(start, (middle, start.1), dashed);
            self.segment((middle, start.1), (middle, end.1), dashed);
            self.segment((middle, end.1), end, dashed);
            self.annotations
                .push((end.0, end.1, if forward { "▶" } else { "◀" }.into(), dashed));
            if !same_column {
                self.annotations.push((
                    start.0.min(end.0) + 1,
                    start.1 - 1,
                    if dashed { "dep." } else { "del." }.into(),
                    dashed,
                ));
            }
        }
    }

    fn segment(&mut self, from: (i32, i32), to: (i32, i32), dashed: bool) {
        let direction = ((to.0 - from.0).signum(), (to.1 - from.1).signum());
        let (out, incoming) = match direction {
            (1, 0) => (2, 8),
            (-1, 0) => (8, 2),
            (0, 1) => (4, 1),
            (0, -1) => (1, 4),
            _ => return,
        };
        let mut point = from;
        while point != to {
            let next = (point.0 + direction.0, point.1 + direction.1);
            for (position, mask) in [(point, out), (next, incoming)] {
                let cell = self.edges.entry(position).or_insert((0, dashed));
                cell.0 |= mask;
                cell.1 &= dashed;
            }
            point = next;
        }
    }

    pub fn reveal(&mut self, area: Rect) {
        let Some(node) = self.selected.as_ref().and_then(|id| self.nodes.get(id)) else {
            return;
        };
        if node.x < self.pan.0 || node.width >= area.width as i32 {
            self.pan.0 = node.x - 1;
        } else if node.x + node.width > self.pan.0 + area.width as i32 {
            self.pan.0 = node.x + node.width - area.width as i32 + 1;
        }
        if node.y < self.pan.1 || node.height >= area.height as i32 {
            self.pan.1 = node.y - 1;
        } else if node.y + node.height > self.pan.1 + area.height as i32 {
            self.pan.1 = node.y + node.height - area.height as i32 + 1;
        }
    }

    pub fn select_direction(&mut self, dx: i64, dy: i64, area: Rect) {
        let Some(current) = self.selected.as_ref().and_then(|id| self.nodes.get(id)) else {
            return;
        };
        let center = (
            i64::from(current.x * 2 + current.width),
            i64::from(current.y * 2 + current.height),
        );
        let next = self
            .nodes
            .iter()
            .filter_map(|(id, node)| {
                let x = i64::from(node.x * 2 + node.width) - center.0;
                let y = i64::from(node.y * 2 + node.height) - center.1;
                if x * dx + y * dy <= 0 {
                    return None;
                }
                Some(((x * x + y * y, (x * dy - y * dx).abs(), id), id.clone()))
            })
            .min_by(|a, b| a.0.cmp(&b.0))
            .map(|(_, id)| id);
        if let Some(id) = next {
            self.selected = Some(id);
            self.reveal(area);
        }
    }

    pub fn select(&mut self, backwards: bool, area: Rect) {
        let mut ids: Vec<_> = self.slots.keys().cloned().collect();
        ids.sort_by_key(|id| (self.slots[id].1, self.slots[id].0, id.clone()));
        if ids.is_empty() {
            return;
        }
        let current = ids
            .iter()
            .position(|id| Some(id) == self.selected.as_ref())
            .unwrap_or(0);
        let next = if backwards {
            (current + ids.len() - 1) % ids.len()
        } else {
            (current + 1) % ids.len()
        };
        self.selected = Some(ids[next].clone());
        self.reveal(area);
    }

    pub fn zoom(&mut self, expand: bool, area: Rect, snapshot: &Snapshot) {
        let next = if expand {
            (self.zoom + 1).min(4)
        } else {
            self.zoom.saturating_sub(1)
        };
        if next != self.zoom {
            self.zoom = next;
            self.layout(snapshot, area);
            self.reveal(area);
        }
    }

    pub fn has_running(&self, area: Rect) -> bool {
        self.nodes.values().any(|node| {
            node.status == "running"
                && node.x + node.width > self.pan.0
                && node.x < self.pan.0 + i32::from(area.width)
                && node.y + node.height > self.pan.1
                && node.y < self.pan.1 + i32::from(area.height)
        })
    }

    fn draw(&self, area: Rect, buf: &mut Buffer, spinner: Option<char>) {
        for (&(x, y), &(mask, dashed)) in &self.edges {
            let symbol = match mask {
                1 | 4 | 5 => {
                    if dashed {
                        "┆"
                    } else {
                        "│"
                    }
                }
                2 | 8 | 10 => {
                    if dashed {
                        "┄"
                    } else {
                        "─"
                    }
                }
                6 => "┌",
                12 => "┐",
                3 => "└",
                9 => "┘",
                7 => "├",
                13 => "┤",
                14 => "┬",
                11 => "┴",
                _ => "┼",
            };
            self.text(
                buf,
                area,
                x,
                y,
                symbol,
                Style::default().fg(if dashed {
                    status_color("waiting")
                } else {
                    status_color("idle")
                }),
            );
        }
        for (x, y, label, dashed) in &self.annotations {
            self.text(
                buf,
                area,
                *x,
                *y,
                label,
                Style::default().fg(if *dashed {
                    status_color("waiting")
                } else {
                    status_color("idle")
                }),
            );
        }
        for (id, node) in &self.nodes {
            let (x, y, w, h) = (node.x, node.y, node.width, node.height);
            if x + w <= self.pan.0
                || x >= self.pan.0 + area.width as i32
                || y + h <= self.pan.1
                || y >= self.pan.1 + area.height as i32
            {
                continue;
            }
            let border = Style::default().fg(status_color(&node.status));
            for row in 0..h {
                self.horizontal(buf, area, x, x + w - 1, y + row, " ", Style::default());
            }
            self.horizontal(buf, area, x + 1, x + w - 2, y, "─", border);
            self.horizontal(buf, area, x + 1, x + w - 2, y + h - 1, "─", border);
            self.vertical(buf, area, x, y + 1, y + h - 2, "│", border);
            self.vertical(buf, area, x + w - 1, y + 1, y + h - 2, "│", border);
            for (dx, dy, symbol) in [
                (0, 0, "┌"),
                (w - 1, 0, "┐"),
                (0, h - 1, "└"),
                (w - 1, h - 1, "┘"),
            ] {
                self.text(buf, area, x + dx, y + dy, symbol, border);
            }
            for (row, (line, style)) in node.lines.iter().enumerate() {
                let style = if row == 0 && self.selected.as_ref() == Some(id) {
                    style.add_modifier(Modifier::REVERSED)
                } else {
                    *style
                };
                if line.starts_with("[x]") || line.starts_with("[.]") || line.starts_with("[!]") {
                    self.text(buf, area, x + 2, y + 1 + row as i32, &line[..3], style);
                    self.text(
                        buf,
                        area,
                        x + 5,
                        y + 1 + row as i32,
                        &line[3..],
                        Style::default(),
                    );
                } else {
                    self.text(buf, area, x + 2, y + 1 + row as i32, line, style);
                    if row == 1 && node.status == "running" {
                        if let Some(frame) = spinner {
                            self.text(
                                buf,
                                area,
                                x + 2,
                                y + 1 + row as i32,
                                &frame.to_string(),
                                style,
                            );
                        }
                    }
                }
            }
        }
    }

    fn text(&self, buf: &mut Buffer, area: Rect, x: i32, y: i32, text: &str, style: Style) {
        let y = y - self.pan.1;
        if y < 0 || y >= area.height as i32 {
            return;
        }
        let mut x = x - self.pan.0;
        for character in text.chars() {
            let glyph = character.to_string();
            let size = width(&glyph) as i32;
            if x >= 0 && x + size <= area.width as i32 && size > 0 {
                buf.set_string(area.x + x as u16, area.y + y as u16, glyph, style);
            }
            x += size;
            if x >= area.width as i32 {
                break;
            }
        }
    }

    fn horizontal(
        &self,
        buf: &mut Buffer,
        area: Rect,
        x1: i32,
        x2: i32,
        y: i32,
        symbol: &str,
        style: Style,
    ) {
        let left = x1.min(x2).max(self.pan.0);
        let right = x1.max(x2).min(self.pan.0 + area.width as i32 - 1);
        for x in left..=right {
            self.text(buf, area, x, y, symbol, style);
        }
    }

    fn vertical(
        &self,
        buf: &mut Buffer,
        area: Rect,
        x: i32,
        y1: i32,
        y2: i32,
        symbol: &str,
        style: Style,
    ) {
        let top = y1.min(y2).max(self.pan.1);
        let bottom = y1.max(y2).min(self.pan.1 + area.height as i32 - 1);
        for y in top..=bottom {
            self.text(buf, area, x, y, symbol, style);
        }
    }
}

pub struct GraphWidget<'a> {
    pub graph: &'a Graph,
    pub spinner: Option<char>,
}

impl Widget for GraphWidget<'_> {
    fn render(self, area: Rect, buf: &mut Buffer) {
        self.graph.draw(area, buf, self.spinner);
    }
}

fn shorten(text: &str, limit: usize) -> String {
    let text = clean(text).replace('\n', " ");
    if width(&text) <= limit {
        return text;
    }
    let mut result = String::new();
    for c in text.chars() {
        if width(&result) + width(&c.to_string()) + 1 > limit {
            break;
        }
        result.push(c);
    }
    result.push('…');
    result
}

fn wrap(text: &str, limit: usize) -> Vec<String> {
    let mut lines = Vec::new();
    for paragraph in clean(text).split('\n') {
        let mut line = String::new();
        let mut line_width = 0;
        for grapheme in Span::raw(paragraph).styled_graphemes(Style::default()) {
            let size = width(grapheme.symbol);
            if line_width + size > limit && !line.is_empty() {
                lines.push(std::mem::take(&mut line));
                line_width = 0;
            }
            line.push_str(grapheme.symbol);
            line_width += size;
        }
        lines.push(line);
    }
    lines
}

fn parents(snapshot: &Snapshot) -> BTreeMap<String, String> {
    let mut parents = BTreeMap::new();
    for agent in snapshot.agents.values() {
        if let Some(parent) = &agent.parent {
            if parent != &agent.id && snapshot.agents.contains_key(parent) {
                parents.insert(agent.id.clone(), parent.clone());
            }
        }
    }
    for agent in snapshot.agents.values() {
        for relation in &agent.relations {
            let Some(target) = relation["target_agent_id"].as_str() else {
                continue;
            };
            if target == agent.id || !snapshot.agents.contains_key(target) {
                continue;
            }
            match relation["relation"].as_str() {
                Some("parent") => {
                    parents
                        .entry(agent.id.clone())
                        .or_insert_with(|| target.into());
                }
                Some("delegated_to") => {
                    parents
                        .entry(target.into())
                        .or_insert_with(|| agent.id.clone());
                }
                _ => {}
            }
        }
    }
    for id in snapshot.agents.keys() {
        let mut cursor = id;
        let mut seen = BTreeSet::new();
        while let Some(parent) = parents.get(cursor) {
            if !seen.insert(cursor.clone()) {
                parents.remove(id);
                break;
            }
            cursor = parent;
        }
    }
    parents
}

fn node_lines(agent: &Agent, zoom: u8, subagent: bool) -> Vec<(String, Style)> {
    let mut lines = vec![
        (
            agent_label(agent),
            Style::default().add_modifier(Modifier::BOLD),
        ),
        (
            format!(
                "{}{}{}",
                if agent.status == "running" { "  " } else { "" },
                if agent.status == "unknown" {
                    ""
                } else {
                    status_label(&agent.status)
                },
                agent
                    .task_status
                    .as_ref()
                    .map(|state| format!(" / Task: {}", status_label(state)))
                    .unwrap_or_default(),
            ),
            Style::default().fg(status_color(&agent.status)),
        ),
    ];
    if !agent.title.is_empty() && agent.title != agent.client {
        lines.push((agent.title.clone(), Style::default()));
    }
    if subagent {
        lines.push(("Subagent".into(), Style::default().fg(status_color("idle"))));
    }
    lines.retain(|(line, _)| !line.is_empty());
    if zoom == 0 {
        return lines;
    }
    let mut work: Vec<_> = agent.tasks.values().chain(agent.steps.values()).collect();
    work.sort_by_key(|item| std::cmp::Reverse(item["reported_at"].as_u64().unwrap_or(0)));
    let current = if !agent.summary.is_empty()
        && agent.status != "idle"
        && agent.task_status.as_deref() != Some("idle")
        && agent.summary_at
            >= work
                .first()
                .and_then(|item| item["reported_at"].as_u64())
                .unwrap_or(0)
    {
        agent.summary.as_str()
    } else {
        work.iter()
            .find(|item| matches!(item["status"].as_str(), Some("running" | "blocked")))
            .and_then(|item| item["title"].as_str())
            .unwrap_or("")
    };
    if !current.is_empty() {
        let issue = matches!(
            agent.task_status.as_deref(),
            Some("error" | "blocked" | "cancelled")
        );
        lines.push((
            format!("{} {current}", if issue { "[!]" } else { "[.]" }),
            Style::default().fg(status_color(if issue { "error" } else { "running" })),
        ));
    }
    let completed: Vec<_> = work
        .iter()
        .filter(|item| item["status"] == "completed")
        .take(if zoom == 1 { 2 } else { 5 })
        .collect();
    if !completed.is_empty() {
        lines.extend(completed.iter().map(|item| {
            (
                format!("[x] {}", item["title"].as_str().unwrap_or("")),
                Style::default().fg(status_color("completed")),
            )
        }));
    }
    if !agent.cwd.is_empty() {
        let home = std::env::var("HOME").unwrap_or_default();
        let cwd = if !home.is_empty()
            && (agent.cwd == home || agent.cwd.starts_with(&format!("{home}/")))
        {
            format!("~{}", &agent.cwd[home.len()..])
        } else {
            agent.cwd.clone()
        };
        lines.push((cwd, Style::default().fg(status_color("unknown"))));
    }
    lines
}

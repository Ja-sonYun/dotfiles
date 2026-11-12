package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type command struct {
	Command    string
	Args       []string
	Key, Label string
}

type config struct {
	Tmux, Direnv, Launcher, Menu string
	Colors                       map[string]string
	Commands                     []command
}

type controller struct {
	Config          config
	Socket, Session string
}

type dashboardPane struct {
	Pane, Window, Owner, Name, Path, Command string
	WindowIndex, PaneIndex                   int
}

type agent struct {
	dashboardPane
	State, Title, Kind string
	Shells             []dashboardPane
}

func (a agent) targets() []dashboardPane {
	return append([]dashboardPane{a.dashboardPane}, a.Shells...)
}

func (c controller) lock() (*os.File, error) {
	file, err := os.OpenFile(c.Socket+".agent-dashboard.lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX); err != nil {
		file.Close()
		return nil, err
	}
	return file, nil
}

func (c controller) tmux(args ...string) (string, error) {
	ctx, cancel := context.WithCancel(context.Background())
	if args[0] != "display-menu" {
		cancel()
		ctx, cancel = context.WithTimeout(context.Background(), 5*time.Second)
	}
	defer cancel()
	cmd := exec.CommandContext(ctx, c.Config.Tmux, append([]string{"-S", c.Socket}, args...)...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s: %w: %s", args[0], err, strings.TrimSpace(string(output)))
	}
	return strings.TrimSuffix(string(output), "\n"), nil
}

func (c controller) option(name string) (string, error) {
	return c.tmux("show-option", "-qv", "-t", c.Session, "@agent_dashboard_"+name)
}

func (c controller) set(name, value string) error {
	_, err := c.tmux("set-option", "-t", c.Session, "@agent_dashboard_"+name, value)
	return err
}

type dashboardState struct {
	View, Viewer, Selected, Connected, Pending string
}

func (c controller) state() (dashboardState, error) {
	format := "#{@agent_dashboard_view}\x1f#{@agent_dashboard_viewer}\x1f#{@agent_dashboard_selected}\x1f#{@agent_dashboard_connected}\x1f#{@agent_dashboard_pending}"
	output, err := c.tmux("display-message", "-p", "-t", c.Session+":", format)
	if err != nil {
		return dashboardState{}, err
	}
	f := strings.SplitN(output, "\x1f", 5)
	if len(f) != 5 {
		return dashboardState{}, errors.New("Invalid dashboard state")
	}
	return dashboardState{f[0], f[1], f[2], f[3], f[4]}, nil
}

func (c controller) agents() ([]agent, error) {
	format := "#{pane_id}\x1f#{window_id}\x1f#{@agent_session_id}\x1f#{@agent_display_name}\x1f#{@agent_state}\x1f#{@agent_project}\x1f#{@agent_conversation}\x1f#{pane_dead}\x1f#{@agent_name}\x1f#{@agent_enabled}\x1f#{session_id}\x1f#{@shell_project}\x1f#{pane_current_path}\x1f#{pane_current_command}\x1f#{window_index}\x1f#{pane_index}"
	filter := "#{||:#{==:#{@agent_enabled},1},#{!=:#{@shell_project},}}"
	output, err := c.tmux("list-panes", "-a", "-f", filter, "-F", format)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	shells := map[string][]dashboardPane{}
	var agents []agent
	for _, line := range strings.Split(output, "\n") {
		f := strings.SplitN(line, "\x1f", 16)
		if len(f) != 16 || seen[f[0]] || f[7] == "1" {
			continue
		}
		if f[9] != "1" {
			if f[11] == "" {
				continue
			}
			seen[f[0]] = true
			window, _ := strconv.Atoi(f[14])
			pane, _ := strconv.Atoi(f[15])
			shells[f[11]] = append(shells[f[11]], dashboardPane{
				Pane: f[0], Window: f[1], Owner: f[10], Path: f[12], Command: f[13],
				WindowIndex: window, PaneIndex: pane,
			})
			continue
		}
		if f[2] == "" || f[2] == c.Session {
			continue
		}
		seen[f[0]] = true
		var conversation struct {
			Title string `json:"title"`
			Known bool   `json:"title_known"`
			Task  string `json:"task"`
		}
		if err := json.Unmarshal([]byte(f[6]), &conversation); err != nil {
			conversation.Known = false
		}
		title := conversation.Title
		if !conversation.Known || strings.TrimSpace(title) == "" {
			title = "No title yet"
			if strings.TrimSpace(conversation.Task) != "" {
				title = "Task: " + conversation.Task
			}
		}
		agents = append(agents, agent{
			dashboardPane: dashboardPane{Pane: f[0], Window: f[1], Owner: f[2], Name: f[3], Path: f[5]},
			State:         f[4], Title: title, Kind: f[8],
		})
	}
	sort.Slice(agents, func(i, j int) bool {
		a, _ := strconv.Atoi(strings.TrimPrefix(agents[i].Pane, "%"))
		b, _ := strconv.Atoi(strings.TrimPrefix(agents[j].Pane, "%"))
		return a < b
	})

	for project, panes := range shells {
		sort.Slice(panes, func(i, j int) bool {
			if panes[i].WindowIndex != panes[j].WindowIndex {
				return panes[i].WindowIndex < panes[j].WindowIndex
			}
			return panes[i].PaneIndex < panes[j].PaneIndex
		})
		for i := range panes {
			panes[i].Name = fmt.Sprintf("subshell %d", i+1)
		}
		shells[project] = panes
	}
	for i := range agents {
		agents[i].Shells = shells[agents[i].Path]
	}
	return agents, nil
}

func shellQuote(value string) string { return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'" }

func shellCommand(args ...string) string {
	quoted := make([]string, len(args))
	for i, arg := range args {
		quoted[i] = shellQuote(arg)
	}
	return strings.Join(quoted, " ")
}

func (c controller) invoke(mode string, args ...string) string {
	return shellCommand(append([]string{c.Config.Launcher, os.Args[1], c.Socket, c.Session, mode}, args...)...)
}

func (c controller) viewerClient() (string, error) {
	pane, err := c.option("viewer")
	if err != nil {
		return "", err
	}
	return c.clientForViewer(pane)
}

func (c controller) clientForViewer(pane string) (string, error) {
	tty, err := c.tmux("display-message", "-p", "-t", pane, "#{pane_tty}")
	if err != nil {
		return "", err
	}
	clients, err := c.tmux("list-clients", "-F", "#{client_name}\x1f#{client_tty}")
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(clients, "\n") {
		fields := strings.SplitN(line, "\x1f", 2)
		if len(fields) == 2 && fields[1] == tty {
			return fields[0], nil
		}
	}
	return "", errors.New("Viewer is not connected")
}

func (c controller) connectLocked(state dashboardState, entry agent, target dashboardPane, focus bool) error {
	client, err := c.clientForViewer(state.Viewer)
	if err != nil {
		return err
	}
	windows, err := c.tmux("list-windows", "-t", state.View, "-F", "#{window_id}")
	if err != nil {
		return err
	}
	linked := false
	for _, window := range strings.Split(windows, "\n") {
		if window == target.Window {
			linked = true
		}
	}
	if !linked {
		if _, err := c.tmux("link-window", "-d", "-s", target.Owner+":"+target.Window, "-t", state.View+":"); err != nil {
			return err
		}
	}
	args := []string{"switch-client", "-E", "-c", client, "-t", state.View + ":" + target.Window + "." + target.Pane}
	if focus {
		args = append(args, ";", "select-pane", "-t", state.Viewer)
	}
	if state.Selected != entry.Pane {
		args = append(args, ";", "set-option", "-t", c.Session, "@agent_dashboard_previous", state.Selected)
	}
	args = append(args,
		";", "set-option", "-t", c.Session, "@agent_dashboard_selected", entry.Pane,
		";", "set-option", "-t", c.Session, "@agent_dashboard_connected", target.Pane,
		";", "set-option", "-s", "@agent_overview_last", entry.Window+"."+entry.Pane,
	)
	_, err = c.tmux(args...)
	return err
}

func (c controller) focus(which string) error {
	pane, err := c.option(which)
	if err != nil {
		return err
	}
	if pane == "" {
		return errors.New("Dashboard pane is unavailable")
	}
	_, err = c.tmux("select-pane", "-t", pane)
	return err
}

func (c controller) copyMode(pageUp bool) error {
	lock, err := c.lock()
	if err != nil {
		return err
	}
	defer lock.Close()

	pane, err := c.option("connected")
	if err != nil {
		return err
	}
	if pane == "" {
		return nil
	}
	args := []string{"copy-mode", "-t", pane}
	if pageUp {
		args = append(args, "-u")
	}
	if _, err := c.tmux(args...); err != nil {
		return err
	}
	return c.focus("viewer")
}

func (c controller) selectAgent(selection string, initial, focus bool) error {
	lock, err := c.lock()
	if err != nil {
		return err
	}
	defer lock.Close()

	agents, err := c.agents()
	if err != nil {
		return err
	}
	if len(agents) == 0 {
		return nil
	}
	state, err := c.state()
	if err != nil {
		return err
	}
	if initial && state.Selected != "" {
		return nil
	}
	index := 0
	for i, entry := range agents {
		if entry.Pane == state.Selected {
			index = i
		}
	}
	switch selection {
	case "next":
		index++
	case "previous":
		index--
	case "last":
		last, err := c.option("previous")
		if err != nil {
			return err
		}
		for i, entry := range agents {
			if entry.Pane == last {
				index = i
			}
		}
	default:
		if strings.HasPrefix(selection, "%") {
			for _, entry := range agents {
				if entry.Pane == selection {
					return c.connectLocked(state, entry, entry.dashboardPane, focus)
				}
			}
			return errors.New("Agent exited")
		}
		index, err = strconv.Atoi(selection)
		if err != nil {
			return err
		}
		if index < 0 || index >= len(agents) {
			return nil
		}
	}
	index = (index%len(agents) + len(agents)) % len(agents)
	return c.connectLocked(state, agents[index], agents[index].dashboardPane, focus)
}

func (c controller) cycle(direction string) error {
	lock, err := c.lock()
	if err != nil {
		return err
	}
	defer lock.Close()

	agents, err := c.agents()
	if err != nil {
		return err
	}
	state, err := c.state()
	if err != nil {
		return err
	}
	for _, entry := range agents {
		if entry.Pane != state.Selected {
			continue
		}
		targets := entry.targets()
		index := 0
		for i, target := range targets {
			if target.Pane == state.Connected {
				index = i
			}
		}
		if direction == "previous" {
			index--
		} else {
			index++
		}
		index = (index + len(targets)) % len(targets)
		return c.connectLocked(state, entry, targets[index], true)
	}
	return nil
}

func (c controller) menu(client string) error {
	agents, err := c.agents()
	if err != nil {
		return err
	}
	if len(agents) == 0 {
		return c.openMenu(client)
	}
	args := []string{"display-menu", "-c", client, "-T", " agent "}
	for i, entry := range c.Config.Commands {
		label := entry.Label
		if label == "" {
			label = entry.Command
		}
		args = append(args, label, entry.Key, "run-shell -b "+shellQuote(c.invoke("create", strconv.Itoa(i), client)))
	}
	_, err = c.tmux(args...)
	return err
}

func (c controller) openMenu(client string) error {
	lock, err := c.lock()
	if err != nil {
		return err
	}
	defer lock.Close()

	values := make([]string, 4)
	for i, name := range []string{"origin_pane", "origin_window", "outer", "origin"} {
		value, err := c.option(name)
		if err != nil {
			return err
		}
		if value == "" {
			return errors.New("Original project is unavailable")
		}
		values[i] = value
	}
	selected, err := c.option("selected")
	if err != nil {
		return err
	}
	agents, err := c.agents()
	if err != nil {
		return err
	}
	for _, entry := range agents {
		if entry.Pane == selected {
			values[0], values[1], values[3] = entry.Pane, entry.Window, entry.Path
			break
		}
	}
	if err := c.set("menu_request", shellCommand(append([]string{c.Config.Menu}, values...)...)); err != nil {
		return err
	}
	if err := lock.Close(); err != nil {
		return err
	}
	_, err = c.tmux("detach-client", "-t", client)
	if err != nil {
		return errors.Join(err, c.set("menu_request", ""))
	}
	return err
}

func (c controller) create(index int, client string) error {
	if index < 0 || index >= len(c.Config.Commands) {
		return errors.New("Unknown agent command")
	}
	lock, err := c.lock()
	if err != nil {
		return err
	}
	defer lock.Close()

	agents, err := c.agents()
	if err != nil {
		return err
	}
	selected, err := c.option("selected")
	if err != nil {
		return err
	}
	for _, entry := range agents {
		if entry.Pane != selected {
			continue
		}
		choice := c.Config.Commands[index]
		command := shellCommand(append([]string{c.Config.Direnv, "exec", entry.Path, choice.Command}, choice.Args...)...)
		pane, err := c.tmux("new-window", "-dP", "-F", "#{pane_id}", "-t", entry.Owner+":", "-c", entry.Path, command)
		if err != nil {
			return err
		}
		return c.set("pending", pane)
	}
	if err := lock.Close(); err != nil {
		return err
	}
	return c.openMenu(client)
}

func (c controller) setup(sidebar string) (func(), error) {
	view, err := c.tmux(
		"new-session", "-dP", "-F", "#{session_id}",
		"-s", "_agent_dashboard_view_"+strings.TrimPrefix(c.Session, "$"),
		"-e", "TMUX_AGENT_STATUS=",
		"-e", "TMUX_AGENT_DASHBOARD=",
		"-e", "TMUX_AGENT_VIEW=1",
		"-e", "TMUX_TITLE_OWNER=",
		"-e", "STATE_COMMAND_NOTIFY=",
		c.invoke("blank", "No agent selected"),
	)
	if err != nil {
		return nil, err
	}
	cleanup := func() { _, _ = c.tmux("kill-session", "-t", view) }
	if err := c.set("view", view); err != nil {
		cleanup()
		return nil, err
	}
	blank, err := c.tmux("display-message", "-p", "-t", view+":", "#{window_id}")
	if err != nil {
		cleanup()
		return nil, err
	}
	if err := c.set("blank", blank); err != nil {
		cleanup()
		return nil, err
	}
	_, err = c.tmux(
		"set-option", "-t", view, "status", "off",
		";", "set-option", "-t", view, "prefix", "None",
		";", "set-option", "-t", view, "key-table", "all-agents-view-root",
	)
	if err != nil {
		cleanup()
		return nil, err
	}
	viewerCommand := "env -u TMUX -u TMUX_PANE -u TMUX_AGENT_STATUS -u TMUX_TITLE_OWNER -u STATE_COMMAND_NOTIFY -u STATE_COMMAND_NAME " + shellCommand(c.Config.Tmux, "-S", c.Socket, "attach-session", "-E", "-t", view)
	viewer, err := c.tmux("split-window", "-h", "-l", "72%", "-dP", "-F", "#{pane_id}", "-t", sidebar, viewerCommand)
	if err != nil {
		cleanup()
		return nil, err
	}
	if err := c.set("sidebar", sidebar); err != nil {
		cleanup()
		return nil, err
	}
	if err := c.set("viewer", viewer); err != nil {
		cleanup()
		return nil, err
	}
	return cleanup, nil
}

func (c controller) endedLocked(expected string) error {
	selected, err := c.option("selected")
	if err != nil {
		return err
	}
	if selected != expected {
		return nil
	}
	blank, err := c.option("blank")
	if err != nil {
		return err
	}
	view, err := c.option("view")
	if err != nil {
		return err
	}
	client, err := c.viewerClient()
	if err != nil {
		return err
	}
	_, err = c.tmux("respawn-window", "-k", "-t", view+":"+blank, c.invoke("blank", "Agent exited"),
		";", "switch-client", "-E", "-c", client, "-t", view+":"+blank)
	if err != nil {
		return err
	}
	if err := c.set("selected", ""); err != nil {
		return err
	}
	if err := c.set("connected", ""); err != nil {
		return err
	}
	return c.focus("sidebar")
}

type snapshot struct {
	Agents                   []agent
	Parent, Connected, Error string
	Ready                    bool
}
type actionResult struct {
	Err   error
	Pane  string
	Focus bool
}
type focusResult struct{ Err error }
type tick struct{}

type model struct {
	Controller               controller
	Agents                   []agent
	Selected, Pending        string
	Parent, Connected, Error string
	Width, Height, Offset    int
	Busy                     bool
	PendingFocus             bool
	Initial                  string
	Ready                    bool
	Started                  bool
	Focused                  bool
}

func (m model) refresh() tea.Msg {
	lock, err := m.Controller.lock()
	if err != nil {
		return snapshot{Error: err.Error()}
	}
	defer lock.Close()

	agents, err := m.Controller.agents()
	if err != nil {
		return snapshot{Error: err.Error()}
	}
	state, err := m.Controller.state()
	if err != nil {
		return snapshot{Error: err.Error()}
	}
	if state.Pending != "" {
		for _, entry := range agents {
			if entry.Pane == state.Pending {
				if err := m.Controller.connectLocked(state, entry, entry.dashboardPane, true); err != nil {
					return snapshot{Error: err.Error()}
				}
				if err := m.Controller.set("pending", ""); err != nil {
					return snapshot{Error: err.Error()}
				}
				state.Selected, state.Connected = entry.Pane, entry.Pane
				break
			}
		}
	}

	parent, connected := state.Selected, state.Connected
	if parent != "" {
		found := false
		for _, entry := range agents {
			if entry.Pane == parent {
				found = true
				paneExists := false
				for _, target := range entry.targets() {
					if target.Pane == connected {
						paneExists = true
					}
				}
				if !paneExists {
					if err := m.Controller.connectLocked(state, entry, entry.dashboardPane, false); err != nil {
						return snapshot{Error: err.Error()}
					}
					connected = entry.Pane
				}
				break
			}
		}
		if !found {
			if err := m.Controller.endedLocked(parent); err != nil {
				return snapshot{Error: err.Error()}
			}
			parent, connected = "", ""
		}
	}

	ready := true
	if !m.Started {
		_, err := m.Controller.clientForViewer(state.Viewer)
		ready = err == nil
	}
	return snapshot{Agents: agents, Parent: parent, Connected: connected, Ready: ready}
}

func (m model) Init() tea.Cmd { return m.refresh }
func (m model) index() int {
	for i, entry := range m.Agents {
		if entry.Pane == m.Selected {
			return i
		}
	}
	return 0
}

func (m model) visibleAgents() int { return max(0, (m.Height-6)/4) }

func (m *model) startPending() tea.Cmd {
	if !m.Ready || m.Busy || m.Pending == "" {
		return nil
	}
	pane, focus := m.Pending, m.PendingFocus
	m.Pending, m.PendingFocus = "", false
	m.Started, m.Busy = true, true
	controller := m.Controller
	return func() tea.Msg { return actionResult{controller.selectAgent(pane, false, false), pane, focus} }
}

func (m *model) scrollToSelection() {
	index := m.index()
	visible := max(1, m.visibleAgents())
	if index < m.Offset {
		m.Offset = index
	}
	if index >= m.Offset+visible {
		m.Offset = index - visible + 1
	}
}

func (m model) Update(message tea.Msg) (tea.Model, tea.Cmd) {
	index := m.index()
	move := 0
	connect := false
	switch msg := message.(type) {
	case tea.FocusMsg:
		m.Focused = true
	case tea.BlurMsg:
		m.Focused = false
	case tea.WindowSizeMsg:
		m.Width, m.Height = msg.Width, msg.Height
	case tick:
		return m, m.refresh
	case snapshot:
		m.Error = msg.Error
		m.Ready = msg.Error == "" && msg.Ready
		if msg.Error == "" {
			m.Agents = msg.Agents
			if !m.Focused && !m.Busy && m.Pending == "" && msg.Parent != "" {
				m.Selected = msg.Parent
			}
			m.Parent, m.Connected = msg.Parent, msg.Connected
			if msg.Connected != "" {
				m.Started = true
			}
			index = m.index()
			if len(m.Agents) > 0 {
				m.Selected = m.Agents[index].Pane
			} else {
				m.Selected, m.Pending = "", ""
				m.Offset = 0
			}
		}
		m.scrollToSelection()
		next := tea.Tick(time.Second, func(time.Time) tea.Msg { return tick{} })
		if pending := m.startPending(); pending != nil {
			return m, tea.Batch(next, pending)
		}
		if !m.Started && m.Ready && len(m.Agents) > 0 {
			m.Started, m.Busy = true, true
			entry := m.Agents[0]
			for _, candidate := range m.Agents {
				if candidate.Window+"."+candidate.Pane == m.Initial {
					entry = candidate
					break
				}
			}
			m.Selected = entry.Pane
			return m, tea.Batch(next, func() tea.Msg {
				return actionResult{m.Controller.selectAgent(entry.Pane, true, false), entry.Pane, true}
			})
		}
		return m, next
	case actionResult:
		m.Busy = false
		if msg.Err != nil {
			m.Error = msg.Err.Error()
		}
		next := m.startPending()
		if next == nil && m.Pending == "" && msg.Err == nil && msg.Focus && m.Selected == msg.Pane {
			controller := m.Controller
			next = func() tea.Msg { return focusResult{controller.focus("viewer")} }
		}
		return m, next
	case focusResult:
		if msg.Err != nil {
			m.Error = msg.Err.Error()
		}
	case tea.KeyMsg:
		switch msg.String() {
		case "up", "k":
			move = -1
		case "down", "j":
			move = 1
		case "enter", "right":
			connect = true
		}
	case tea.MouseMsg:
		switch msg.Button {
		case tea.MouseButtonWheelUp:
			move = -1
		case tea.MouseButtonWheelDown:
			move = 1
		case tea.MouseButtonLeft:
			if msg.Action == tea.MouseActionPress && msg.Y >= 3 && msg.Y < 3+m.visibleAgents()*4 && (msg.Y-3)%4 < 2 {
				candidate := m.Offset + (msg.Y-3)/4
				if candidate < len(m.Agents) {
					index, connect = candidate, true
				}
			}
		}
	}
	if len(m.Agents) > 0 {
		index = (index + move + len(m.Agents)) % len(m.Agents)
		m.Selected = m.Agents[index].Pane
		m.scrollToSelection()
		if connect || move != 0 {
			m.Pending, m.PendingFocus = m.Selected, connect
			next := m.startPending()
			return m, next
		}
	}
	return m, nil
}

func fit(text string, width int) string {
	text = strings.Join(strings.Fields(text), " ")
	if width < 1 {
		return ""
	}
	if lipgloss.Width(text) <= width {
		return text
	}
	runes := []rune(text)
	for len(runes) > 0 && lipgloss.Width(string(runes))+1 > width {
		runes = runes[:len(runes)-1]
	}
	return string(runes) + "…"
}

func fitPath(path string, width int) string {
	path = strings.Join(strings.Fields(path), " ")
	if width < 1 {
		return ""
	}
	if lipgloss.Width(path) <= width {
		return path
	}
	runes := []rune(path)
	for len(runes) > 0 && lipgloss.Width(string(runes))+1 > width {
		runes = runes[1:]
	}
	return "…" + string(runes)
}

func agentStyle(kind string) lipgloss.Style {
	color := "6"
	switch kind {
	case "codex":
		color = "#8bd5ca"
	case "claude":
		color = "#f5a97f"
	case "pi":
		color = "#c6a0f6"
	case "antigravity":
		color = "4"
	}
	return lipgloss.NewStyle().Foreground(lipgloss.Color(color))
}

func (m model) stateStyle(state string) lipgloss.Style {
	style := lipgloss.NewStyle()
	if color := m.Controller.Config.Colors[state]; color != "" {
		style = style.Foreground(lipgloss.Color(color))
	}
	return style
}

func projectPath(path string) string {
	if home, err := os.UserHomeDir(); err == nil && strings.HasPrefix(path, home+"/") {
		return "~" + strings.TrimPrefix(path, home)
	}
	return path
}

func (m model) tabStrip(entry agent, width int) string {
	if width < 1 {
		return ""
	}
	targets := entry.targets()
	labels := make([]string, len(targets))
	anchor := 0
	for i, target := range targets {
		label := "agent"
		if i > 0 {
			label = fmt.Sprintf("%d %s", i, target.Command)
		}
		connected := m.Parent == entry.Pane && m.Connected == target.Pane
		if connected {
			label = "[" + label + "]"
			anchor = i
		}
		labels[i] = fit(label, max(1, width-2))
	}
	start := 0
	for start < anchor && lipgloss.Width(strings.Join(labels[start:anchor+1], " · ")) > width-2 {
		start++
	}
	muted := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	row, used := "", 0
	if start > 0 && width > 2 {
		row, used = muted.Render("‹ "), 2
	}
	for i := start; i < len(targets); i++ {
		separator := ""
		if i > start {
			separator = " · "
		}
		size := lipgloss.Width(labels[i])
		if used+lipgloss.Width(separator)+size > width {
			if used+2 <= width {
				row += muted.Render(" ›")
			}
			break
		}
		row += muted.Render(separator)
		used += lipgloss.Width(separator)
		style := muted
		if m.Parent == entry.Pane && m.Connected == targets[i].Pane {
			style = lipgloss.NewStyle().Foreground(lipgloss.Color("6")).Bold(true)
		}
		row += style.Render(labels[i])
		used += size
	}
	return row
}

func (m model) View() string {
	width := m.Width - 2
	if width < 1 || m.Height < 1 {
		return ""
	}
	if width < 6 {
		return fit("AGENTS", width)
	}
	accent := lipgloss.NewStyle().Foreground(lipgloss.Color("6")).Bold(true)
	muted := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	if !m.Focused {
		accent = muted
	}
	divider := muted.Render(strings.Repeat("─", width))
	running, waiting := 0, 0
	for _, entry := range m.Agents {
		switch entry.State {
		case "running":
			running++
		case "waiting":
			waiting++
		}
	}
	countWidth := (width - 3) / 2
	counts := m.stateStyle("running").Render(fit(fmt.Sprintf("%d running", running), countWidth)) +
		muted.Render(" / ") + m.stateStyle("waiting").Render(fit(fmt.Sprintf("%d waiting", waiting), width-countWidth-3))
	rows := []string{
		accent.Render(fit(fmt.Sprintf("AGENTS / %d", len(m.Agents)), width)),
		counts,
		divider,
	}

	for i := m.Offset; i < len(m.Agents) && i < m.Offset+m.visibleAgents(); i++ {
		if i > m.Offset {
			rows = append(rows, "")
		}
		entry := m.Agents[i]
		prefix := "  "
		style := agentStyle(entry.Kind)
		if entry.Pane == m.Selected {
			prefix = accent.Render("> ")
			style = style.Bold(m.Focused).Underline(m.Focused)
		}
		state := fit("● "+entry.State, (width-3)/2)
		name := fit(entry.Name, width-lipgloss.Width(state)-3)
		gap := strings.Repeat(" ", width-lipgloss.Width(name)-lipgloss.Width(state)-2)
		path := fitPath(projectPath(entry.Path), (width-2)/3)
		detail := fit(entry.Title, max(0, width-5-lipgloss.Width(path))) + muted.Render(" · "+path)
		tabs := m.tabStrip(entry, width-2)
		rows = append(rows,
			prefix+style.Render(name)+gap+m.stateStyle(entry.State).Render(state),
			"  "+detail,
			"  "+tabs,
		)
	}
	if len(m.Agents) == 0 && len(rows) < m.Height-4 {
		rows = append(rows, muted.Render(fit("No agents", width)))
	}

	for len(rows) < m.Height-4 {
		rows = append(rows, "")
	}

	footer := []string{
		divider,
		muted.Render(fit("No agent selected", width)),
		"",
		"",
	}
	for _, entry := range m.Agents {
		if entry.Pane != m.Parent {
			continue
		}
		targets := entry.targets()
		for i, target := range targets {
			if target.Pane != m.Connected {
				continue
			}
			label := fmt.Sprintf("VIEWING / %s · %d/%d", target.Name, i+1, len(targets))
			footer[1] = agentStyle(entry.Kind).Bold(true).Render(fit(label, width))
			footer[2] = m.stateStyle(entry.State).Render(fit("● "+entry.State, width))
			if i > 0 {
				footer[2] = muted.Render(fit(fmt.Sprintf("%s · %d.%d", target.Command, target.WindowIndex, target.PaneIndex), width))
			}
			footer[3] = muted.Render(fitPath(projectPath(target.Path), width))
			break
		}
		break
	}
	if m.Error != "" {
		footer[2] = m.stateStyle("error").Render(fit(m.Error, width))
	}
	rows = append(rows, footer...)
	return strings.Join(rows[:min(len(rows), m.Height)], "\n")
}

func run() error {
	if len(os.Args) < 5 {
		return errors.New("expected config, socket, session, mode")
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		return err
	}
	var cfg config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return err
	}
	cfg.Launcher, err = os.Executable()
	if err != nil {
		return err
	}
	c := controller{cfg, os.Args[2], os.Args[3]}
	args := os.Args[5:]
	switch os.Args[4] {
	case "blank":
		if len(args) != 1 {
			return errors.New("expected message")
		}
		fmt.Print("\033[2J\033[H", args[0])
		ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGHUP, syscall.SIGTERM, os.Interrupt)
		defer stop()
		<-ctx.Done()
		return nil
	case "select":
		if len(args) != 1 {
			return errors.New("expected selection")
		}
		return c.selectAgent(args[0], false, true)
	case "cycle":
		if len(args) != 1 || (args[0] != "next" && args[0] != "previous") {
			return errors.New("expected next or previous")
		}
		return c.cycle(args[0])
	case "focus":
		if len(args) != 1 {
			return errors.New("expected pane role")
		}
		return c.focus(args[0])
	case "copy":
		if len(args) > 1 || (len(args) == 1 && args[0] != "page-up") {
			return errors.New("expected optional page-up")
		}
		return c.copyMode(len(args) == 1)
	case "menu":
		if len(args) != 1 {
			return errors.New("expected client")
		}
		return c.menu(args[0])
	case "project-menu":
		if len(args) != 1 {
			return errors.New("expected client")
		}
		return c.openMenu(args[0])
	case "create":
		if len(args) != 2 {
			return errors.New("expected command index and client")
		}
		index, err := strconv.Atoi(args[0])
		if err != nil {
			return err
		}
		return c.create(index, args[1])
	case "serve":
		if len(args) != 1 {
			return errors.New("expected sidebar pane")
		}
		cleanup, err := c.setup(args[0])
		if err != nil {
			return err
		}
		defer cleanup()
		ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGHUP, syscall.SIGTERM, os.Interrupt)
		defer stop()
		initial, err := c.tmux("show-option", "-sqv", "@agent_overview_last")
		if err != nil {
			return err
		}
		active, err := c.tmux("display-message", "-p", "-t", args[0], "#{pane_active}")
		if err != nil {
			return err
		}
		_, err = tea.NewProgram(model{Controller: c, Initial: initial, Focused: active == "1"},
			tea.WithContext(ctx), tea.WithAltScreen(), tea.WithMouseCellMotion(), tea.WithReportFocus()).Run()
		if ctx.Err() != nil {
			return nil
		}
		return err
	default:
		return errors.New("unknown mode")
	}
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

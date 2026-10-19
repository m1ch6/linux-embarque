use std::path::PathBuf;
use std::time::{Duration, Instant};

use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph},
    Terminal,
};
use crossterm::{
    event::{self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};

mod sip;

struct User {
    id: &'static str,
    name: &'static str,
    number: &'static str,
}

const USERS: &[User] = &[
    User { id: "hadji",   name: "Hadji",   number: "1001" },
    User { id: "johnson", name: "Johnson", number: "1002" },
    User { id: "miora",   name: "Miora",   number: "1003" },
    User { id: "ulrich",  name: "Ulrich",  number: "1004" },
];

const USER_COLORS: &[Color] = &[Color::Cyan, Color::Green, Color::Magenta, Color::Yellow];

/// The doorbell IVR. It is called like any other number -- every call is
/// dialled full duplex, see `sip::dial` -- but the status line says so, because
/// dialling it is how you reach the menu.
const IVR_NUMBER: &str = "9999";

/// How often the TUI re-reads the PBX's recording directory. A message left on
/// the IVR is written by Asterisk while we are running, so the list can never
/// be a one-off snapshot taken at startup: whoever the message is for has to
/// see it appear, and be able to replay it, without touching a key.
const REFRESH_EVERY: Duration = Duration::from_secs(3);

/// One panel per user + the CONFIG panel.
const PANELS: usize = USERS.len() + 1;
const CONFIG_PANEL: usize = USERS.len();

struct App {
    endpoints: Vec<sip::BaresipInstance>,
    dial_buffers: Vec<String>,
    exit: bool,
    last_tick: Instant,
    active: usize,
    /// All recordings known to the PBX.
    recordings: Vec<String>,
    /// Per-panel selection index into that panel's recording list.
    selected: Vec<usize>,
    /// When `recordings` was last re-read from the PBX.
    last_refresh: Instant,
    /// Per-panel call state as of the previous tick, so we can spot the exact
    /// moment a call becomes active.
    prev_states: Vec<sip::CallState>,
    /// Per-panel: the number this panel dialled (empty = we did not place the
    /// call in progress). Tells an outgoing call apart from one we answered.
    dialled_to: Vec<String>,
    status_message: String,
}

impl App {
    fn new() -> Self {
        let mut endpoints = Vec::new();
        for u in USERS {
            let cfg = PathBuf::from(format!("./conf/{}", u.id));
            endpoints.push(sip::BaresipInstance::new(u.id, cfg));
        }
        Self {
            endpoints,
            dial_buffers: vec![String::new(); USERS.len()],
            exit: false,
            last_tick: Instant::now(),
            active: 0,
            recordings: Vec::new(),
            selected: vec![0; PANELS],
            last_refresh: Instant::now(),
            prev_states: vec![sip::CallState::Idle; USERS.len()],
            dialled_to: vec![String::new(); USERS.len()],
            status_message: "Ready. Type a number and press Enter to call.".to_string(),
        }
    }

    fn spawn(&mut self) -> Result<(), String> {
        let _ = std::process::Command::new("pkill").arg("-f").arg("baresip").output();
        std::thread::sleep(Duration::from_millis(500));
        // Sort out the microphone level first (the default source is the raw
        // mic at this point), then set up echo cancellation.
        sip::ensure_mic_gain();
        let ec = sip::ensure_echo_cancel();
        for ep in &mut self.endpoints {
            ep.spawn(ec.clone())?;
        }
        self.refresh_recordings();
        self.last_refresh = Instant::now();
        self.status_message = if ec.is_some() {
            "Spawning baresip instances (echo cancellation active)...".to_string()
        } else {
            "Spawning baresip instances (no echo-cancel module; using default audio)..."
                .to_string()
        };
        Ok(())
    }

    fn panel_is_user(&self) -> bool {
        self.active < USERS.len()
    }

    fn panel_title(&self) -> String {
        if self.panel_is_user() {
            format!("{} ({})", USERS[self.active].name, USERS[self.active].number)
        } else {
            "CONFIG".to_string()
        }
    }

    fn next_panel(&mut self) {
        self.active = (self.active + 1) % PANELS;
        self.status_message = format!("Switched to {}", self.panel_title());
    }

    fn prev_panel(&mut self) {
        self.active = if self.active == 0 { PANELS - 1 } else { self.active - 1 };
        self.status_message = format!("Switched to {}", self.panel_title());
    }

    // ---- Recordings -------------------------------------------------------

    /// Recordings belonging to one panel. A user panel shows only the calls
    /// it received (files prefixed with its number); CONFIG shows all.
    fn panel_recordings(&self, panel: usize) -> Vec<String> {
        if panel == CONFIG_PANEL {
            self.recordings.clone()
        } else {
            let prefix = format!("{}-", USERS[panel].number);
            self.recordings.iter().filter(|r| r.starts_with(&prefix)).cloned().collect()
        }
    }

    fn refresh_recordings(&mut self) {
        self.recordings = std::process::Command::new("docker")
            .args(["exec", "doorbell-device", "ls", "/var/spool/asterisk/monitor/"])
            .output()
            .map(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .lines()
                    .filter(|l| l.ends_with(".wav"))
                    .map(|l| l.to_string())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        self.recordings.sort();
        for p in 0..PANELS {
            let len = self.panel_recordings(p).len();
            if self.selected[p] >= len && len > 0 {
                self.selected[p] = len - 1;
            }
        }
    }

    fn move_selection(&mut self, delta: i32) {
        let len = self.panel_recordings(self.active).len();
        if len == 0 { return; }
        let mut sel = self.selected[self.active] as i32 + delta;
        sel = ((sel % len as i32) + len as i32) % len as i32;
        self.selected[self.active] = sel as usize;
    }

    fn play_selected(&mut self) {
        let list = self.panel_recordings(self.active);
        if list.is_empty() { return; }
        let idx = self.selected[self.active].min(list.len() - 1);
        let rec = list[idx].clone();
        let path = format!("/var/spool/asterisk/monitor/{}", rec);
        self.status_message = format!("Playing: {}", rec);
        let _ = std::process::Command::new("sh")
            .arg("-c")
            .arg(format!("docker exec doorbell-device cat '{}' | aplay -q -", path.replace('\'', "'\\''")))
            // Never let a child inherit our terminal: anything it writes would be
            // painted over the TUI and, because ratatui only repaints changed
            // cells, would stay there.
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }

    fn delete_selected(&mut self) {
        let list = self.panel_recordings(self.active);
        if list.is_empty() { return; }
        let idx = self.selected[self.active].min(list.len() - 1);
        let rec = list[idx].clone();
        let path = format!("/var/spool/asterisk/monitor/{}", rec);
        self.status_message = format!("Deleted: {}", rec);
        let _ = std::process::Command::new("docker")
            .args(["exec", "doorbell-device", "rm", &path])
            .output();
        self.refresh_recordings();
    }

    // ---- Key actions ------------------------------------------------------

    fn on_enter(&mut self) {
        if !self.panel_is_user() { return; }
        let i = self.active;
        let st = self.endpoints[i].state.lock().unwrap().call_state;
        match st {
            sip::CallState::Ringing => {
                // Answer receive-only; accept() also switches this endpoint's
                // mic to the silent device once the call is up. Clearing
                // `dialled_to` marks this as a call we answered, not one we
                // placed -- the difference decides whether the microphone is
                // turned back on when the call becomes active.
                self.dialled_to[i].clear();
                let _ = self.endpoints[i].accept();
                self.status_message = format!("{}: answered (mic off, recv-only)", USERS[i].name);
            }
            sip::CallState::Idle => {
                let num = self.dial_buffers[i].clone();
                if num.is_empty() {
                    self.status_message = format!("{}: type a number, then Enter", USERS[i].name);
                } else {
                    // Make sure our own mic is live before we call.
                    let _ = self.endpoints[i].mic_on();
                    let uri = format!("sip:{}@127.0.0.1", num);
                    let _ = self.endpoints[i].dial(&uri);
                    self.dial_buffers[i].clear();
                    // Remember that this call is ours (see on_tick).
                    self.dialled_to[i] = num.clone();
                    // Every call is dialled full duplex so the panel can hear
                    // Asterisk's prompts (the menu, and "leave your message
                    // after the beep" when a call is not answered). The callee
                    // still cannot be heard -- it answers receive-only.
                    self.status_message = if num == IVR_NUMBER {
                        format!("{}: calling the doorbell ({})...", USERS[i].name, num)
                    } else {
                        format!("{}: calling {}...", USERS[i].name, num)
                    };
                }
            }
            _ => {}
        }
    }

    fn on_digit(&mut self, c: char) {
        if !self.panel_is_user() { return; }
        let i = self.active;
        let st = self.endpoints[i].state.lock().unwrap().call_state;
        match st {
            sip::CallState::Active => {
                let _ = self.endpoints[i].dtmf(c);
                self.status_message = format!("{}: DTMF {}", USERS[i].name, c);
            }
            sip::CallState::Idle => {
                self.dial_buffers[i].push(c);
                self.status_message = format!("{}: dial {}", USERS[i].name, self.dial_buffers[i]);
            }
            sip::CallState::Ringing => {
                if c == '4' {
                    let _ = self.endpoints[i].hangup();
                    self.status_message = format!("{}: call declined", USERS[i].name);
                }
            }
            sip::CallState::Calling => {
                if c == '4' {
                    let _ = self.endpoints[i].hangup();
                    self.status_message = format!("{}: call cancelled", USERS[i].name);
                }
            }
        }
    }

    /// '*' and '#' are DTMF-only (never part of a dialed number).
    fn on_dtmf_special(&mut self, c: char) {
        if !self.panel_is_user() { return; }
        let i = self.active;
        let st = self.endpoints[i].state.lock().unwrap().call_state;
        if st == sip::CallState::Active {
            let _ = self.endpoints[i].dtmf(c);
            self.status_message = format!("{}: DTMF {}", USERS[i].name, c);
        }
    }

    fn hangup_active(&mut self) {
        if !self.panel_is_user() { return; }
        let i = self.active;
        let _ = self.endpoints[i].hangup();
        self.status_message = format!("{}: hanging up...", USERS[i].name);
    }

    fn on_backspace(&mut self) {
        if !self.panel_is_user() { return; }
        let i = self.active;
        let st = self.endpoints[i].state.lock().unwrap().call_state;
        if st == sip::CallState::Idle {
            if self.dial_buffers[i].pop().is_some() {
                self.status_message = format!("{}: dial {}", USERS[i].name, self.dial_buffers[i]);
            }
        } else {
            self.hangup_active();
        }
    }

    // ---- Tick -------------------------------------------------------------

    fn on_tick(&mut self) {
        // When a panel rings, put the operator on it so they can answer it.
        for (i, ep) in self.endpoints.iter().enumerate() {
            let st = ep.state.lock().unwrap().call_state;
            if st == sip::CallState::Ringing {
                if self.active != i {
                    self.active = i;
                    self.status_message =
                        format!("{} ({}) is ringing!", USERS[i].name, USERS[i].number);
                }
                break;
            }
        }

        // The other half of the dance. The moment a call becomes active while
        // nobody else here is in a call, the callee did not pick up and
        // Asterisk has moved on to the message flow: hand the caller its own
        // panel back, with its microphone, so the visitor can speak and then
        // press H -- which is what ends the call and saves the message.
        for i in 0..self.endpoints.len() {
            let st = self.endpoints[i].state.lock().unwrap().call_state;
            let was = self.prev_states[i];
            self.prev_states[i] = st;
            if st == sip::CallState::Idle {
                // Our own call just ended: come back to our own panel. Without
                // this the focus would stay parked on the panel that was
                // ringing, even though the call is over.
                if was != sip::CallState::Idle && !self.dialled_to[i].is_empty() {
                    self.active = i;
                    self.status_message = format!("{}: call ended", USERS[i].name);
                }
                // The call is over; forget who we called.
                self.dialled_to[i].clear();
                continue;
            }
            if st != sip::CallState::Active || was == sip::CallState::Active {
                continue;
            }
            // Only for a call this panel placed. A panel that *answered* must
            // keep its microphone off -- that is the one-way audio rule.
            let to = self.dialled_to[i].clone();
            if to.is_empty() {
                continue;
            }
            let others_busy = (0..self.endpoints.len()).any(|j| {
                j != i
                    && self.endpoints[j].state.lock().unwrap().call_state
                        != sip::CallState::Idle
            });
            if others_busy {
                continue;
            }
            self.active = i;
            let _ = self.endpoints[i].mic_on();
            self.status_message = if to == IVR_NUMBER {
                format!("{}: doorbell menu - press H when you are done", USERS[i].name)
            } else {
                format!("{}: leave your message after the beep, then press H", USERS[i].name)
            };
        }

        // Keep the message panels live. The IVR records a caller's message
        // while the TUI is already running, so poll the PBX and, when something
        // new shows up, point its owner's selection at it and say so.
        if self.last_refresh.elapsed() >= REFRESH_EVERY {
            let before = self.recordings.clone();
            self.refresh_recordings();
            self.last_refresh = Instant::now();

            let arrived: Vec<String> = self
                .recordings
                .iter()
                .filter(|r| !before.contains(r))
                .cloned()
                .collect();
            for rec in arrived {
                // The file is named after the recipient, so the prefix says
                // which panel it belongs to.
                for p in 0..USERS.len() {
                    if rec.starts_with(&format!("{}-", USERS[p].number)) {
                        let idx = self.panel_recordings(p).iter().position(|r| r == &rec);
                        if let Some(idx) = idx {
                            self.selected[p] = idx;
                        }
                        break;
                    }
                }
                self.status_message = format!("New message: {}", rec);
            }
        }

        self.last_tick = Instant::now();
    }

    // ---- Drawing ----------------------------------------------------------

    fn draw(&self, f: &mut ratatui::Frame) {
        let size = f.area();
        let constraints: Vec<Constraint> =
            (0..PANELS).map(|_| Constraint::Percentage(100 / PANELS as u16)).collect();
        let chunks = Layout::default()
            .direction(Direction::Horizontal)
            .constraints(constraints)
            .split(size);

        for (i, ep) in self.endpoints.iter().enumerate() {
            let state = ep.state.lock().unwrap();
            let active = self.active == i;
            let color = USER_COLORS[i % USER_COLORS.len()];
            let border = if active { color } else { Color::DarkGray };

            let block = Block::default()
                .title(Span::styled(
                    format!("{} {} {}", USERS[i].name, USERS[i].number, if active { "← ACTIVE" } else { "" }),
                    Style::default().add_modifier(Modifier::BOLD).fg(if active { color } else { Color::White }),
                ))
                .borders(Borders::ALL)
                .border_style(Style::default().fg(border));

            let dim = Style::default().fg(Color::DarkGray);
            let lit = Style::default().fg(Color::White);

            let mut lines: Vec<Line> = vec![
                Line::from(Span::styled(format!("My number: {}", USERS[i].number), Style::default().fg(Color::Yellow))),
                Line::from(Span::styled(format!("Registered: {}", if state.registered { "Yes" } else { "No" }), lit)),
                Line::from(Span::styled(format!("State: {}", state.call_state), lit)),
                Line::from(Span::styled(
                    format!("Remote: {}", if state.remote.is_empty() { "—" } else { &state.remote }),
                    lit,
                )),
                Line::from(Span::raw("")),
                Line::from(Span::styled(
                    format!("Dial: {}{}", self.dial_buffers[i], if active { "_" } else { "" }),
                    if active { Style::default().fg(Color::Green).add_modifier(Modifier::BOLD) } else { dim },
                )),
                Line::from(Span::styled("Enter = Dial / Answer (mic off)", if active { lit } else { dim })),
                Line::from(Span::styled("H = Hang up   Bksp = Delete digit", if active { lit } else { dim })),
                Line::from(Span::styled("0-9 = digits / DTMF", if active { lit } else { dim })),
                Line::from(Span::raw("")),
            ];

            // This panel's saved messages (calls it received).
            let msgs = self.panel_recordings(i);
            lines.push(Line::from(Span::styled(
                format!("Messages ({}):", msgs.len()),
                Style::default().add_modifier(Modifier::BOLD),
            )));
            if msgs.is_empty() {
                lines.push(Line::from(Span::styled("  (none)", dim)));
            } else {
                let sel = self.selected[i].min(msgs.len() - 1);
                for (k, m) in msgs.iter().enumerate() {
                    let short = m.trim_start_matches(&format!("{}-", USERS[i].number)).trim_end_matches(".wav");
                    let style = if active && k == sel {
                        Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)
                    } else {
                        dim
                    };
                    lines.push(Line::from(Span::styled(
                        format!("  {} {}", if active && k == sel { ">" } else { " " }, short),
                        style,
                    )));
                }
            }
            lines.push(Line::from(Span::raw("")));
            drop(state);
            f.render_widget(Paragraph::new(lines).block(block), chunks[i]);
        }

        // Config panel
        let active_cfg = self.active == CONFIG_PANEL;
        let config_block = Block::default()
            .title(Span::styled(
                format!("CONFIG {}", if active_cfg { "← ACTIVE" } else { "" }),
                Style::default().add_modifier(Modifier::BOLD).fg(Color::White),
            ))
            .borders(Borders::ALL)
            .border_style(Style::default().fg(if active_cfg { Color::Cyan } else { Color::DarkGray }));

        let mut config_lines: Vec<Line> = vec![
            Line::from(Span::styled("All recordings:", Style::default().add_modifier(Modifier::BOLD))),
        ];
        let sel = self.selected[CONFIG_PANEL].min(self.recordings.len().saturating_sub(1));
        for (i, rec) in self.recordings.iter().enumerate() {
            let selected = i == sel;
            let style = if selected {
                Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(Color::White)
            };
            config_lines.push(Line::from(Span::styled(format!("  {} {}", if selected { ">" } else { " " }, rec), style)));
        }
        if self.recordings.is_empty() {
            config_lines.push(Line::from(Span::styled("  (no recordings yet)", Style::default().fg(Color::DarkGray))));
        }
        config_lines.push(Line::from(Span::raw("")));
        config_lines.push(Line::from(Span::styled("Actions:", Style::default().add_modifier(Modifier::BOLD))));
        config_lines.push(Line::from(Span::styled("  ↑/↓  Select", Style::default().fg(Color::White))));
        config_lines.push(Line::from(Span::styled("  P    Play selected", Style::default().fg(Color::White))));
        config_lines.push(Line::from(Span::styled("  D    Delete selected", Style::default().fg(Color::White))));
        config_lines.push(Line::from(Span::styled("  R    Refresh list", Style::default().fg(Color::White))));
        config_lines.push(Line::from(Span::raw("")));
        config_lines.push(Line::from(Span::styled("Status:", Style::default().add_modifier(Modifier::BOLD))));
        config_lines.push(Line::from(Span::styled(format!("  {}", self.status_message), Style::default().fg(Color::DarkGray))));
        f.render_widget(Paragraph::new(config_lines).block(config_block), chunks[CONFIG_PANEL]);
    }
}

/// `docker` on this box is podman's compatibility shim, which prints
/// "Emulate Docker CLI using podman. Create /etc/containers/nodocker to quiet
/// msg." on stderr for *every* invocation. The message names its own fix: a
/// `nodocker` marker file. Create the per-user one (no root required) so no
/// command the TUI runs can emit that line.
fn quiet_podman_docker() {
    let base = std::env::var("XDG_CONFIG_HOME")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("HOME").ok().map(|h| format!("{}/.config", h)));
    if let Some(base) = base {
        let dir = std::path::Path::new(&base).join("containers");
        if std::fs::create_dir_all(&dir).is_ok() {
            let _ = std::fs::File::create(dir.join("nodocker"));
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    quiet_podman_docker();
    enable_raw_mode()?;
    let mut stdout = std::io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let mut app = App::new();
    app.spawn()?;

    let tick_rate = Duration::from_millis(200);
    loop {
        terminal.draw(|f| app.draw(f))?;

        let timeout = tick_rate
            .checked_sub(app.last_tick.elapsed())
            .unwrap_or_else(|| Duration::from_secs(0));
        if event::poll(timeout)? {
            if let Event::Key(key) = event::read()? {
                if key.kind != KeyEventKind::Press {
                    continue;
                }
                match key.code {
                    KeyCode::Char('q') | KeyCode::Esc => app.exit = true,
                    KeyCode::Tab | KeyCode::Right => app.next_panel(),
                    KeyCode::Left => app.prev_panel(),
                    KeyCode::Enter => app.on_enter(),
                    KeyCode::Backspace => app.on_backspace(),
                    KeyCode::Char('h') | KeyCode::Char('H') => app.hangup_active(),
                    KeyCode::Char('p') | KeyCode::Char('P') => app.play_selected(),
                    KeyCode::Char('d') | KeyCode::Char('D') => app.delete_selected(),
                    KeyCode::Char('r') | KeyCode::Char('R') => {
                        app.refresh_recordings();
                        app.status_message = "Recordings refreshed.".to_string();
                    }
                    KeyCode::Up => app.move_selection(-1),
                    KeyCode::Down => app.move_selection(1),
                    KeyCode::Char(c) if c.is_ascii_digit() => app.on_digit(c),
                    KeyCode::Char('*') | KeyCode::Char('#') => app.on_dtmf_special(key.code.as_char().unwrap_or('*')),
                    _ => {}
                }
            }
        }

        if app.exit {
            break;
        }
        if app.last_tick.elapsed() >= tick_rate {
            app.on_tick();
        }
    }

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen, DisableMouseCapture)?;

    Ok(())
}

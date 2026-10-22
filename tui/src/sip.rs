use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::io::{Write, BufRead, BufReader};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use std::time::Instant;
use std::fs;

#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub enum CallState {
    #[default]
    Idle,
    Calling,
    Ringing,
    Active,
}

impl std::fmt::Display for CallState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CallState::Idle => write!(f, "Idle"),
            CallState::Calling => write!(f, "Calling"),
            CallState::Ringing => write!(f, "Ringing (incoming)"),
            CallState::Active => write!(f, "Active"),
        }
    }
}

#[derive(Clone, Default)]
pub struct EndpointState {
    pub registered: bool,
    pub call_state: CallState,
    pub remote: String,
    pub call_start: Option<Instant>,
}

pub struct BaresipInstance {
    pub name: String,
    config_dir: PathBuf,
    process: Option<std::process::Child>,
    stdin_tx: Option<std::sync::mpsc::Sender<String>>,
    pub state: Arc<Mutex<EndpointState>>,
    /// ALSA device baresip captures from when the microphone should be live.
    /// Either `alsa,doorbell` (echo-cancelled) or `alsa,default` (plain).
    audio_dev: String,
    /// ALSA config file to hand baresip via `ALSA_CONFIG_PATH`, when the
    /// echo-cancelled `doorbell` PCM is available.
    alsa_conf: Option<PathBuf>,
}

/// Make sure the PipeWire echo-cancellation nodes exist and return the ALSA
/// config file that routes baresip through them.
///
/// `module-echo-cancel` creates two virtual nodes:
///   * `doorbell_mic`     — the real microphone with the speaker signal subtracted
///   * `doorbell_speaker` — the real speaker
///
/// Routing every baresip through that pair is what kills the echo on a single
/// machine: because both softphones share one sound card, the caller's
/// microphone would otherwise re-capture the callee's speaker output and send
/// it back. The AEC subtracts that output from the microphone instead.
///
/// Returns `None` when PipeWire or the module is unavailable (the caller then
/// falls back to the plain ALSA `default` device).
pub fn ensure_echo_cancel() -> Option<PathBuf> {
    let pactl = |args: &[&str]| -> Option<String> {
        Command::new("pactl")
            .args(args)
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
    };

    let modules = pactl(&["list", "short", "modules"]).unwrap_or_default();
    if !modules.contains("module-echo-cancel") {
        let _ = Command::new("pactl")
            .args([
                "load-module",
                "module-echo-cancel",
                "aec_method=webrtc",
                "source_name=doorbell_mic",
                "sink_name=doorbell_speaker",
            ])
            .output();
    }

    let sources = pactl(&["list", "short", "sources"]).unwrap_or_default();
    let sinks = pactl(&["list", "short", "sinks"]).unwrap_or_default();
    if !sources.contains("doorbell_mic") || !sinks.contains("doorbell_speaker") {
        return None;
    }

    let conf = PathBuf::from("./asound.conf");
    if !conf.is_file() {
        return None;
    }
    Some(fs::canonicalize(&conf).unwrap_or(conf))
}

/// Trim the microphone capture chain to a level with headroom.
///
/// The default ALSA capture gain is often far too hot — here it was
/// `Internal Mic Boost` at +20 dB stacked on top of `Capture` at +30 dB, which
/// pins the ADC at full scale. A clipped input is not just loud, it is harsh and
/// hard to understand, which is what "the sound is not clear" actually was.
///
/// `pactl` maps the source volume onto the hardware `Capture` control, so it is
/// the portable way to do this; the extra preamp stages (`*Mic Boost`) are
/// hardware specific and only lowered on a best-effort basis. A level the user
/// deliberately set lower is never raised.
pub fn ensure_mic_gain() {
    /// Percent to aim for; maps to roughly +10 dB on a Realtek ADC.
    const TARGET: u32 = 30;

    let current = Command::new("pactl")
        .args(["get-source-volume", "@DEFAULT_SOURCE@"])
        .output()
        .ok()
        .and_then(|o| {
            // "Volume: front-left: 61604 /  94% / -1.61 dB, ..."
            String::from_utf8_lossy(&o.stdout)
                .split('/')
                .nth(1)
                .and_then(|p| p.trim().trim_end_matches('%').parse::<u32>().ok())
        });

    let too_hot = match current {
        Some(c) => c > TARGET + 15,
        None => true,
    };
    if too_hot {
        let _ = Command::new("pactl")
            .args(["set-source-volume", "@DEFAULT_SOURCE@", &format!("{}%", TARGET)])
            .output();
    }
    let _ = Command::new("pactl")
        .args(["set-source-mute", "@DEFAULT_SOURCE@", "0"])
        .output();

    // Drop any extra preamp; it adds ~20 dB and a lot of noise floor.
    for ctl in ["Internal Mic Boost", "Mic Boost"] {
        let _ = Command::new("amixer")
            .args(["-c", "0", "sset", ctl, "0"])
            .output();
    }
}

impl BaresipInstance {
    pub fn new(name: &str, config_dir: PathBuf) -> Self {
        BaresipInstance {
            name: name.to_string(),
            config_dir,
            process: None,
            stdin_tx: None,
            state: Arc::new(Mutex::new(EndpointState::default())),
            audio_dev: "alsa,default".to_string(),
            alsa_conf: None,
        }
    }

    /// Point this endpoint's capture/playback at the chosen ALSA device. Kept in
    /// the config so it matches how the process is spawned (AEC vs plain
    /// `default`), and rewritten on every spawn so it self-corrects on machines
    /// that lack the echo-cancel module.
    fn write_audio_config(&self) {
        let path = self.config_dir.join("config");
        let Ok(text) = fs::read_to_string(&path) else { return };
        let keys = ["audio_player", "audio_source", "audio_alert"];
        let is_key = |line: &str, k: &str| -> bool {
            line.trim_start()
                .strip_prefix(k)
                .is_some_and(|rest| rest.starts_with([' ', '\t']))
        };
        let mut out = String::with_capacity(text.len() + 64);
        for line in text.lines() {
            if keys.iter().any(|k| is_key(line, k)) {
                continue;
            }
            out.push_str(line);
            out.push('\n');
        }
        for k in keys {
            out.push_str(&format!("{}\t\t{}\n", k, self.audio_dev));
        }
        let _ = fs::write(&path, out);
    }

    pub fn spawn(&mut self, ec: Option<PathBuf>) -> Result<(), String> {
        fs::create_dir_all(&self.config_dir).map_err(|e| e.to_string())?;

        // Choose the capture/playback device: echo-cancelled when available.
        self.alsa_conf = ec;
        self.audio_dev = if self.alsa_conf.is_some() {
            "alsa,doorbell".to_string()
        } else {
            "alsa,default".to_string()
        };
        self.write_audio_config();

        let accounts = self.config_dir.join("accounts");
        let entry = format!("<sip:{}@127.0.0.1>;auth_pass=pass_{}", self.name, self.name);
        fs::write(&accounts, &entry).map_err(|e| e.to_string())?;

        // Wrap baresip in `script` to give it a pseudo-terminal (pty).
        // baresip's stdio.so reads from the terminal — a plain pipe doesn't work.
        // `script -qec CMD /dev/null` allocates a pty and runs CMD inside it.
        let config_arg = format!("{}", self.config_dir.display());
        let mut cmd = Command::new("script");
        // When the echo-cancelled `doorbell` PCM is available, hand baresip the
        // ALSA config that defines it; the config file itself is repo-local.
        if let Some(conf) = &self.alsa_conf {
            cmd.env("ALSA_CONFIG_PATH", conf);
        }
        cmd.arg("-qec")
            .arg(format!("baresip -f {} -v", config_arg))
            .arg("/dev/null")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        let mut child = cmd.spawn().map_err(|e| format!("spawn failed: {}", e))?;
        let stdin = child.stdin.take().ok_or("no stdin")?;
        let stdout = child.stdout.take().ok_or("no stdout")?;

        let (tx, rx) = std::sync::mpsc::channel::<String>();
        let poll_tx = tx.clone();
        self.stdin_tx = Some(tx);

        let state = Arc::clone(&self.state);
        thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                let line = match line { Ok(l) => l, Err(_) => break };
                if line.trim().is_empty() { continue; }
                let mut s = state.lock().unwrap();
                Self::parse_line(&mut s, &line);
            }
        });

        // Ask baresip for its call list once a second. That answer is
        // authoritative, and reconciling against it is what unsticks a panel
        // whose call ended on a line we do not recognise -- a rejected ringing
        // call prints "call: rejecting incoming call ...", not any of the
        // end-of-call phrases the parser matches, so without this the panel
        // would sit on "Ringing (incoming)" for ever.
        thread::spawn(move || loop {
            thread::sleep(Duration::from_secs(1));
            if poll_tx.send("/listcalls\n".to_string()).is_err() {
                break;
            }
        });

        let mut writer = stdin;
        thread::spawn(move || {
            for cmd in rx {
                let _ = write!(writer, "{}", cmd);
                let _ = writer.flush();
            }
        });

        self.process = Some(child);
        Ok(())
    }

    fn parse_line(state: &mut EndpointState, line: &str) {
        let lower = line.to_lowercase();

        // --- Registration ---
        if lower.contains("registered successfully")
            || (lower.contains("200 ok") && lower.contains("register"))
        {
            state.registered = true;
        }
        if lower.contains("register failed")
            || lower.contains("registration failed")
            || lower.contains("401 unauthorized")
            || lower.contains("403 forbidden")
        {
            state.registered = false;
        }

        // --- Call state ---
        // Caller (outgoing) sees: "call: connecting to 'sip:...'"
        //   then "SIP Progress: 100 Trying" / "SIP Progress: 180 Ringing".
        // Callee (incoming) sees: "Incoming call from: <Name> sip:...".
        if lower.contains("call established") || lower.contains("connected:") {
            state.call_state = CallState::Active;
            if state.call_start.is_none() {
                state.call_start = Some(Instant::now());
            }
        } else if lower.contains("incoming call from") {
            state.call_state = CallState::Ringing;
        } else if lower.contains("connecting to") || lower.contains("sip progress: 100 trying") {
            state.call_state = CallState::Calling;
        }

        if lower.contains("terminated (duration")
            || lower.contains("call terminated")
            || lower.contains("session closed")
            || lower.contains("terminate call")
            || lower.contains("rejecting incoming call")
        {
            state.call_state = CallState::Idle;
            state.remote.clear();
            state.call_start = None;
        }

        // --- Reconciliation with baresip's own call list --------------------
        // "/listcalls" answers either "--- Active calls (0) ---" or one line
        // per call, e.g.
        //   > [line 1, id ...]  0:00:00   INCOMING   sip:hadji@127.0.0.1
        // "No calls at all" is the one answer we can always trust, and it is
        // what releases a panel stuck on a call that has already ended.
        if let Some(rest) = lower.split("--- active calls (").nth(1) {
            if rest.split(')').next().map(str::trim) == Some("0") {
                state.call_state = CallState::Idle;
                state.remote.clear();
                state.call_start = None;
            }
        }
        if line.trim_start().starts_with('>') {
            // A call does exist. Only fill in the state when we think we are
            // idle: this answer can be a fraction of a second older than what
            // the lines above already told us, and we must not undo them.
            if state.call_state == CallState::Idle {
                state.call_state = if lower.contains("incoming") {
                    CallState::Ringing
                } else if lower.contains("established") {
                    CallState::Active
                } else {
                    CallState::Calling
                };
            }
            if let Some(idx) = line.rfind("sip:") {
                state.remote = line[idx..].trim().to_string();
            }
        }

        // --- Remote party ---
        if lower.contains("incoming call from") {
            if let Some(idx) = line.find("from:") {
                let rest = line[idx + 5..].trim();
                let rest = rest.split(" - ").next().unwrap_or(rest).trim();
                state.remote = rest.to_string();
            }
        } else if lower.contains("connecting to") {
            if let Some(idx) = line.find("connecting to '") {
                let rest = &line[idx + 15..];
                let rest = rest.split('\'').next().unwrap_or(rest);
                state.remote = rest.to_string();
            }
        }
    }

    /// Send a command line to baresip (a newline is appended).
    pub fn send(&self, cmd: &str) -> Result<(), String> {
        match &self.stdin_tx {
            Some(tx) => tx.send(format!("{}\n", cmd)).map_err(|e| e.to_string()),
            None => Err("not spawned".into()),
        }
    }

    /// Send raw bytes to baresip with no trailing newline (used for DTMF digits,
    /// which baresip's menu handles as single keystrokes during a call).
    pub fn send_raw(&self, s: &str) -> Result<(), String> {
        match &self.stdin_tx {
            Some(tx) => tx.send(s.to_string()).map_err(|e| e.to_string()),
            None => Err("not spawned".into()),
        }
    }

    /// Place a call, full duplex on our side.
    ///
    /// The caller has to be able to *receive*: Asterisk talks to it -- the
    /// doorbell menu, and "please leave your message after the beep" whenever a
    /// call is not answered. A send-only caller is played to but never hears
    /// any of it. One-way audio between two people is still guaranteed from the
    /// other end: the callee answers receive-only and switches its microphone
    /// off (see `accept`), so it never transmits.
    pub fn dial(&self, uri: &str) -> Result<(), String> {
        // baresip 1.x has no /dialdir. A plain /dial is already full duplex
        // (audio=sendrecv), which is what the caller needs, and the TUI configs
        // load no video module, so the call is audio-only anyway.
        self.send(&format!("/dial {}", uri))
    }
    pub fn hangup(&self) -> Result<(), String> { self.send("/hangup") }
    pub fn accept(&self) -> Result<(), String> {
        // baresip 1.x has no /acceptdir. Accept the call, then mute the
        // microphone: the callee hears the caller but never transmits.
        self.send("/accept")?;
        self.send("/mute")
    }
    /// Turn this endpoint's microphone back on, using whichever device the
    /// process was spawned with (echo-cancelled when available).
    pub fn mic_on(&self) -> Result<(), String> {
        self.send(&format!("/ausrc {}", self.audio_dev))
    }
    pub fn dtmf(&self, digit: char) -> Result<(), String> { self.send_raw(&digit.to_string()) }

    pub fn quit(&mut self) {
        if let Some(mut child) = self.process.take() {
            let _ = self.send("/quit");
            thread::sleep(Duration::from_millis(100));
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

impl Drop for BaresipInstance {
    fn drop(&mut self) { self.quit(); }
}

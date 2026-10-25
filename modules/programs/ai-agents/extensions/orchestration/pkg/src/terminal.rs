use crate::{adapter, Config};
use anyhow::{bail, Context, Result};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc as blocking, Arc};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

enum Input {
    Bytes(Vec<u8>),
    Resize(u16, u16),
}

pub(crate) fn combine_results(primary: Result<()>, secondary: Result<()>) -> Result<()> {
    match (primary, secondary) {
        (Err(primary), Err(secondary)) => Err(anyhow::anyhow!("{primary:#}; {secondary:#}")),
        (Err(error), Ok(())) | (Ok(()), Err(error)) => Err(error),
        (Ok(()), Ok(())) => Ok(()),
    }
}

pub struct EmbeddedTerminal {
    pub title: String,
    pub parser: vt100::Parser,
    pub ready: bool,
    input: blocking::SyncSender<Input>,
    output: mpsc::Receiver<Result<Vec<u8>>>,
    stop: Option<oneshot::Sender<()>>,
    finished: Arc<AtomicBool>,
    task: JoinHandle<Result<()>>,
    token: String,
    sequence: Vec<u8>,
    started: Instant,
    size: (u16, u16),
    prefix: bool,
}

impl EmbeddedTerminal {
    pub async fn start(
        config: Config,
        location: serde_json::Value,
        title: String,
        rows: u16,
        cols: u16,
    ) -> Result<Self> {
        let rows = rows.max(1);
        let cols = cols.max(1);
        let token = uuid::Uuid::new_v4().to_string();
        let request = serde_json::json!({"location":location,"token":token});
        let mut command = CommandBuilder::new(&config.node);
        command.arg(
            config
                .tmux_adapter
                .as_ref()
                .context("tmux integration is disabled")?,
        );
        command.arg("attach-embedded");
        command.arg(request.to_string());
        command.env("TERM", "xterm-256color");
        let (master, mut child, mut reader, mut writer, viewer_pty) =
            tokio::task::spawn_blocking(move || -> Result<_> {
                let pair = native_pty_system().openpty(PtySize {
                    rows,
                    cols,
                    pixel_width: 0,
                    pixel_height: 0,
                })?;
                let fd = pair
                    .master
                    .as_raw_fd()
                    .context("PTY has no file descriptor")?;
                let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
                if flags < 0
                    || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
                {
                    return Err(std::io::Error::last_os_error().into());
                }
                let fd = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 0) };
                if fd < 0 {
                    return Err(std::io::Error::last_os_error().into());
                }
                let reader = unsafe { File::from_raw_fd(fd) };
                // Close the writer without portable-pty's EOF write on drop.
                let writer = reader.try_clone()?;
                let viewer_pty = reader.try_clone()?;
                let child = pair.slave.spawn_command(command)?;
                drop(pair.slave);
                Ok((pair.master, child, reader, writer, viewer_pty))
            })
            .await??;
        let pid = child.process_id().context("Viewer process has no pid")? as i32;
        let (input, input_rx) = blocking::sync_channel(32);
        let (output_tx, output) = mpsc::channel(32);
        let write_errors = output_tx.clone();
        let finished = Arc::new(AtomicBool::new(false));
        let read_finished = Arc::new(AtomicBool::new(false));
        let reading = read_finished.clone();
        let read_task = std::thread::spawn(move || -> Result<()> {
            let mut buffer = [0; 8192];
            while !reading.load(Ordering::Acquire) {
                let mut poll = libc::pollfd {
                    fd: reader.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                };
                let result = unsafe { libc::poll(&mut poll, 1, 50) };
                if result < 0 {
                    let error = std::io::Error::last_os_error();
                    if error.kind() == std::io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(error.into());
                }
                if result == 0 {
                    continue;
                }
                match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(size) => {
                        // Keep draining after the UI closes so macOS can finish the viewer's exit.
                        let _ = output_tx.blocking_send(Ok(buffer[..size].to_vec()));
                    }
                    Err(error) if error.raw_os_error() == Some(libc::EIO) => break,
                    Err(error)
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock
                        ) =>
                    {
                        continue;
                    }
                    Err(error) => {
                        let _ = output_tx
                            .blocking_send(Err(anyhow::anyhow!("PTY read failed: {error}")));
                        return Err(error.into());
                    }
                }
            }
            Ok(())
        });
        let writing = finished.clone();
        let write_task = std::thread::spawn(move || -> Result<()> {
            let result: Result<()> = (|| {
                while !writing.load(Ordering::Acquire) {
                    match input_rx.recv_timeout(Duration::from_millis(50)) {
                        Ok(Input::Bytes(bytes)) => {
                            let mut remaining = bytes.as_slice();
                            while !remaining.is_empty() && !writing.load(Ordering::Acquire) {
                                match writer.write(remaining) {
                                    Ok(0) => bail!("PTY write returned zero"),
                                    Ok(size) => remaining = &remaining[size..],
                                    Err(error)
                                        if error.kind() == std::io::ErrorKind::Interrupted =>
                                    {
                                        continue;
                                    }
                                    Err(error)
                                        if error.kind() == std::io::ErrorKind::WouldBlock =>
                                    {
                                        let mut poll = libc::pollfd {
                                            fd: writer.as_raw_fd(),
                                            events: libc::POLLOUT,
                                            revents: 0,
                                        };
                                        if unsafe { libc::poll(&mut poll, 1, 50) } < 0 {
                                            let error = std::io::Error::last_os_error();
                                            if error.kind() != std::io::ErrorKind::Interrupted {
                                                return Err(error.into());
                                            }
                                        }
                                    }
                                    Err(error) => return Err(error.into()),
                                }
                            }
                        }
                        Ok(Input::Resize(rows, cols)) => master.resize(PtySize {
                            rows,
                            cols,
                            pixel_width: 0,
                            pixel_height: 0,
                        })?,
                        Err(blocking::RecvTimeoutError::Timeout) => continue,
                        Err(blocking::RecvTimeoutError::Disconnected) => break,
                    }
                }
                Ok(())
            })();
            if let Err(error) = &result {
                let _ =
                    write_errors.blocking_send(Err(anyhow::anyhow!("PTY input failed: {error}")));
            }
            result
        });
        let (stop, mut stopped) = oneshot::channel();
        let finishing = finished.clone();
        let task = tokio::spawn(async move {
            let result: Result<()> = async {
                loop {
                    if let Some(status) = child.try_wait()? {
                        if !status.success() {
                            bail!("Agent connection ended: {status}");
                        }
                        return Ok(());
                    }
                    tokio::select! {
                        _ = &mut stopped => break,
                        _ = tokio::time::sleep(Duration::from_millis(50)) => {}
                    }
                }
                let deadline = Instant::now() + Duration::from_secs(3);
                let stop = adapter(&config, "embedded-stop", &request)
                    .await
                    .map(|_| ())
                    .context("Viewer detach failed");
                let termination: Result<()> = async {
                    while Instant::now() < deadline {
                        if child.try_wait()?.is_some() {
                            return Ok(());
                        }
                        tokio::time::sleep(Duration::from_millis(50)).await;
                    }
                    if child.try_wait()?.is_none() {
                        // Keep the leader unreaped while signalling its owned process group.
                        unsafe {
                            libc::kill(-pid, libc::SIGTERM);
                        }
                        tokio::time::sleep(Duration::from_secs(2)).await;
                        if unsafe { libc::kill(-pid, 0) } == 0 {
                            unsafe {
                                libc::kill(-pid, libc::SIGKILL);
                            }
                        }
                        tokio::task::spawn_blocking(move || child.wait()).await??;
                    }
                    Ok(())
                }
                .await;
                combine_results(stop, termination)
            }
            .await;
            finishing.store(true, Ordering::Release);
            read_finished.store(true, Ordering::Release);
            let cleanup = adapter(&config, "embedded-cleanup", &request)
                .await
                .map(|_| ())
                .context("Viewer cleanup failed");
            // Keep the PTY open until the viewer has detached and cleaned up.
            drop(viewer_pty);
            let workers = tokio::task::spawn_blocking(move || -> Result<()> {
                let read = read_task
                    .join()
                    .map_err(|_| anyhow::anyhow!("PTY reader panicked"))
                    .and_then(|result| result);
                let write = write_task
                    .join()
                    .map_err(|_| anyhow::anyhow!("PTY writer panicked"))
                    .and_then(|result| result);
                combine_results(read, write)
            })
            .await
            .context("PTY worker join failed")
            .and_then(|result| result);
            combine_results(combine_results(result, cleanup), workers)
        });
        Ok(Self {
            title,
            parser: vt100::Parser::new(rows, cols, 0),
            ready: false,
            input,
            output,
            stop: Some(stop),
            finished,
            task,
            token,
            sequence: Vec::new(),
            started: Instant::now(),
            size: (rows, cols),
            prefix: false,
        })
    }

    pub fn poll(&mut self) -> Result<bool> {
        let started = Instant::now();
        let mut changed = false;
        while started.elapsed() < Duration::from_millis(4) {
            let bytes = match self.output.try_recv() {
                Ok(bytes) => bytes?,
                Err(mpsc::error::TryRecvError::Empty) => break,
                Err(mpsc::error::TryRecvError::Disconnected) => bail!("Agent connection ended"),
            };
            changed = true;
            for byte in bytes {
                self.parser.process(&[byte]);
                if self.sequence.is_empty() {
                    if byte == 0x1b {
                        self.sequence.push(byte);
                    }
                    continue;
                }
                self.sequence.push(byte);
                let csi = self.sequence.get(1) == Some(&b'[');
                let osc = self.sequence.get(1) == Some(&b']');
                let complete = (csi && self.sequence.len() > 2 && (0x40..=0x7e).contains(&byte))
                    || (osc && (byte == 7 || self.sequence.ends_with(b"\x1b\\")))
                    || (!csi && !osc);
                if complete {
                    let reply = match self.sequence.as_slice() {
                        b"\x1b[c" | b"\x1b[0c" => Some(b"\x1b[?1;2c".to_vec()),
                        b"\x1b[>c" | b"\x1b[>0c" => Some(b"\x1b[>0;0;0c".to_vec()),
                        b"\x1b[5n" => Some(b"\x1b[0n".to_vec()),
                        b"\x1b[6n" => {
                            let (row, col) = self.parser.screen().cursor_position();
                            Some(format!("\x1b[{};{}R", row + 1, col + 1).into_bytes())
                        }
                        _ => None,
                    };
                    if self.sequence
                        == format!("\x1b]777;agent-hub-ready;{}\x07", self.token).as_bytes()
                    {
                        self.ready = true;
                    }
                    self.sequence.clear();
                    if let Some(reply) = reply {
                        self.send(reply)?;
                    }
                } else if self.sequence.len() > 4096 {
                    self.sequence.clear();
                }
            }
        }
        if !self.ready && self.started.elapsed() > Duration::from_secs(10) {
            bail!("Agent connection timed out");
        }
        if self.task.is_finished() {
            bail!("Agent connection ended");
        }
        Ok(changed)
    }

    fn send(&self, bytes: Vec<u8>) -> Result<()> {
        if !bytes.is_empty() {
            self.input
                .try_send(Input::Bytes(bytes))
                .map_err(|error| anyhow::anyhow!("Agent input unavailable: {error}"))?;
        }
        Ok(())
    }

    pub fn resize(&mut self, rows: u16, cols: u16) -> Result<()> {
        if rows > 0 && cols > 0 && self.size != (rows, cols) {
            self.input
                .try_send(Input::Resize(rows, cols))
                .map_err(|error| anyhow::anyhow!("Agent resize unavailable: {error}"))?;
            self.parser.set_size(rows, cols);
            self.size = (rows, cols);
        }
        Ok(())
    }

    pub fn paste(&self, text: &str) -> Result<()> {
        if self.parser.screen().bracketed_paste() {
            self.send(format!("\x1b[200~{text}\x1b[201~").into_bytes())
        } else {
            self.send(text.as_bytes().to_vec())
        }
    }

    pub fn key(&mut self, key: KeyEvent) -> Result<()> {
        if self.prefix {
            self.prefix = false;
            if key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL) {
                return self.send(vec![3]);
            }
            self.send(vec![17])?;
        }
        if key.code == KeyCode::Char('q') && key.modifiers.contains(KeyModifiers::CONTROL) {
            self.prefix = true;
            return Ok(());
        }
        self.send(encode(key, self.parser.screen().application_cursor()))
    }

    pub fn interrupt_pending(&self) -> bool {
        self.prefix
    }

    pub fn clear_prefix(&mut self) {
        self.prefix = false;
    }

    pub async fn stop(mut self) -> Result<()> {
        self.finished.store(true, Ordering::Release);
        self.output.close();
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        self.task.await?
    }
}

fn encode(key: KeyEvent, application: bool) -> Vec<u8> {
    let modifier = 1
        + u8::from(key.modifiers.contains(KeyModifiers::SHIFT))
        + 2 * u8::from(key.modifiers.contains(KeyModifiers::ALT))
        + 4 * u8::from(key.modifiers.contains(KeyModifiers::CONTROL));
    let final_byte = match key.code {
        KeyCode::Up => Some('A'),
        KeyCode::Down => Some('B'),
        KeyCode::Right => Some('C'),
        KeyCode::Left => Some('D'),
        KeyCode::Home => Some('H'),
        KeyCode::End => Some('F'),
        _ => None,
    };
    if let Some(end) = final_byte {
        return if modifier > 1 {
            format!("\x1b[1;{modifier}{end}")
        } else {
            format!("\x1b{}{end}", if application { 'O' } else { '[' })
        }
        .into_bytes();
    }
    let number = match key.code {
        KeyCode::Insert => Some(2),
        KeyCode::Delete => Some(3),
        KeyCode::PageUp => Some(5),
        KeyCode::PageDown => Some(6),
        KeyCode::F(n @ 5..=12) => Some([15, 17, 18, 19, 20, 21, 23, 24][(n - 5) as usize]),
        _ => None,
    };
    if let Some(number) = number {
        return if modifier > 1 {
            format!("\x1b[{number};{modifier}~")
        } else {
            format!("\x1b[{number}~")
        }
        .into_bytes();
    }
    if let KeyCode::F(n @ 1..=4) = key.code {
        let end = (b'P' + n - 1) as char;
        return if modifier > 1 {
            format!("\x1b[1;{modifier}{end}")
        } else {
            format!("\x1bO{end}")
        }
        .into_bytes();
    }
    let mut bytes = match key.code {
        KeyCode::Char(c) if key.modifiers.contains(KeyModifiers::CONTROL) && c.is_ascii() => {
            vec![if c == '?' { 127 } else { (c as u8) & 0x1f }]
        }
        KeyCode::Char(c) => c.to_string().into_bytes(),
        KeyCode::Enter => vec![13],
        KeyCode::Tab => vec![9],
        KeyCode::BackTab => b"\x1b[Z".to_vec(),
        KeyCode::Backspace => vec![127],
        KeyCode::Esc => vec![27],
        _ => Vec::new(),
    };
    if key.modifiers.contains(KeyModifiers::ALT) && !bytes.is_empty() {
        bytes.insert(0, 27);
    }
    bytes
}

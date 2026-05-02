use std::collections::VecDeque;
use std::ffi::CString;
use std::fs;
use std::io::{self, IsTerminal, Read, Write};
use std::net::Shutdown;
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use clap::Subcommand;

const FRAME_OUTPUT: u8 = 1;
const FRAME_INPUT: u8 = 2;
const FRAME_RESIZE: u8 = 3;
const FRAME_EXIT: u8 = 4;
const FRAME_STOP: u8 = 5;
const FRAME_ATTACH_OPTIONS: u8 = 6;
const FRAME_HEADER_LEN: usize = 5;
const OUTPUT_REPLAY_CHUNK_SIZE: usize = 16 * 1024;
const OUTPUT_REPLAY_LIMIT: usize = 512 * 1024;
const OUTPUT_BUFFER_LIMIT: usize = 4 * 1024 * 1024;

#[derive(Subcommand, Debug)]
pub enum TerminalCommands {
    /// Attach to, or create, a persistent terminal session.
    Attach(TerminalAttachArgs),
    /// Stop a persistent terminal session.
    Stop(TerminalStopArgs),
    #[command(hide = true)]
    Server(TerminalServerArgs),
}

#[derive(clap::Args, Debug, Clone)]
pub struct TerminalAttachArgs {
    #[arg(long)]
    session_id: String,
    #[arg(long)]
    storage_dir: Option<PathBuf>,
    /// Do not replay buffered output when attaching to an existing session.
    #[arg(long)]
    no_replay: bool,
    /// Command to create when the session does not already exist.
    #[arg(trailing_var_arg = true, required = true, allow_hyphen_values = true)]
    command: Vec<String>,
}

#[derive(clap::Args, Debug, Clone)]
pub struct TerminalStopArgs {
    #[arg(long)]
    session_id: String,
    #[arg(long)]
    storage_dir: Option<PathBuf>,
}

#[derive(clap::Args, Debug, Clone)]
pub struct TerminalServerArgs {
    #[arg(long)]
    session_id: String,
    #[arg(long)]
    storage_dir: Option<PathBuf>,
    #[arg(long)]
    cwd: Option<PathBuf>,
    /// Command to run inside the owned PTY.
    #[arg(trailing_var_arg = true, required = true, allow_hyphen_values = true)]
    command: Vec<String>,
}

pub fn run_terminal(command: TerminalCommands) -> Result<()> {
    match command {
        TerminalCommands::Attach(args) => run_attach(args),
        TerminalCommands::Stop(args) => run_stop(args),
        TerminalCommands::Server(args) => run_server(args),
    }
}

fn run_attach(args: TerminalAttachArgs) -> Result<()> {
    let paths = SessionPaths::new(args.storage_dir.clone(), &args.session_id)?;
    ensure_private_dir(&paths.storage_dir)?;

    let mut created_session = false;
    let mut stream = match UnixStream::connect(&paths.socket_path) {
        Ok(stream) => stream,
        Err(_) => {
            stop_recorded_server(&paths);
            start_server(&args, &paths)?;
            created_session = true;
            connect_with_retry(&paths.socket_path, Duration::from_secs(5))?
        }
    };

    write_attach_options(&mut stream, AttachOptions::from_args(&args))?;

    let raw_mode = RawTerminalMode::enter(io::stdin().as_raw_fd())?;
    if args.no_replay && !created_session {
        clear_local_terminal()?;
    }
    let writer = Arc::new(Mutex::new(stream.try_clone()?));
    send_resize_if_available(&writer, None);
    start_stdin_forwarder(Arc::clone(&writer));
    start_resize_forwarder(writer);

    let exit_code = attach_output_loop(&mut stream)?;
    drop(raw_mode);

    if let Some(code) = exit_code {
        std::process::exit(code.clamp(0, 255));
    }
    Ok(())
}

fn run_stop(args: TerminalStopArgs) -> Result<()> {
    let paths = SessionPaths::new(args.storage_dir, &args.session_id)?;
    let mut stream = match UnixStream::connect(&paths.socket_path) {
        Ok(stream) => stream,
        Err(_) => {
            stop_recorded_server(&paths);
            let _ = fs::remove_file(&paths.socket_path);
            return Ok(());
        }
    };
    write_frame(&mut stream, FRAME_STOP, &[])?;
    let _ = stream.shutdown(Shutdown::Write);
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let mut discard = [0; 8192];
    let mut saw_eof = false;
    loop {
        match stream.read(&mut discard) {
            Ok(0) => {
                saw_eof = true;
                break;
            }
            Ok(_) => {}
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                break;
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    if saw_eof {
        wait_for_socket_removal(&paths.socket_path, Duration::from_secs(2));
        if paths.socket_path.exists() || paths.pid_path.exists() {
            stop_recorded_server(&paths);
        }
    } else {
        stop_recorded_server(&paths);
    }
    Ok(())
}

fn run_server(args: TerminalServerArgs) -> Result<()> {
    let paths = SessionPaths::new(args.storage_dir, &args.session_id)?;
    ensure_private_dir(&paths.storage_dir)?;
    let _ = fs::remove_file(&paths.socket_path);
    let listener = UnixListener::bind(&paths.socket_path).with_context(|| {
        format!(
            "failed to bind terminal session socket {}",
            paths.socket_path.display()
        )
    })?;
    fs::write(&paths.pid_path, std::process::id().to_string()).with_context(|| {
        format!(
            "failed to write terminal session pid {}",
            paths.pid_path.display()
        )
    })?;
    listener.set_nonblocking(true)?;

    let cwd = match args.cwd {
        Some(cwd) => cwd,
        None => std::env::current_dir().context("failed to resolve current directory")?,
    };
    let initial_size = terminal_size(io::stdout().as_raw_fd()).unwrap_or_default();
    let mut child = PtyChild::spawn(&args.command, &cwd, initial_size)?;
    let result = run_server_loop(&listener, &mut child);
    let _ = fs::remove_file(&paths.socket_path);
    let _ = fs::remove_file(&paths.pid_path);
    result
}

fn start_server(args: &TerminalAttachArgs, paths: &SessionPaths) -> Result<()> {
    let executable = std::env::current_exe().context("failed to resolve argon executable")?;
    let cwd = std::env::current_dir().context("failed to resolve terminal session cwd")?;
    let mut command = Command::new(executable);
    command
        .arg("terminal")
        .arg("server")
        .arg("--session-id")
        .arg(&args.session_id)
        .arg("--storage-dir")
        .arg(&paths.storage_dir)
        .arg("--cwd")
        .arg(cwd)
        .arg("--")
        .args(&args.command)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    command
        .spawn()
        .context("failed to start terminal session server")?;
    Ok(())
}

fn connect_with_retry(socket_path: &Path, timeout: Duration) -> Result<UnixStream> {
    let deadline = Instant::now() + timeout;
    loop {
        match UnixStream::connect(socket_path) {
            Ok(stream) => return Ok(stream),
            Err(error) => {
                if Instant::now() >= deadline {
                    return Err(error).with_context(|| {
                        format!(
                            "failed to connect to terminal session socket {}",
                            socket_path.display()
                        )
                    });
                }
            }
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn wait_for_socket_removal(socket_path: &Path, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    while socket_path.exists() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(25));
    }
}

fn stop_recorded_server(paths: &SessionPaths) {
    let Ok(pid_text) = fs::read_to_string(&paths.pid_path) else {
        return;
    };
    let Ok(pid) = pid_text.trim().parse::<libc::pid_t>() else {
        let _ = fs::remove_file(&paths.pid_path);
        return;
    };
    if pid <= 0 {
        let _ = fs::remove_file(&paths.pid_path);
        return;
    }

    let _ = unsafe { libc::kill(-pid, libc::SIGHUP) };
    let _ = unsafe { libc::kill(pid, libc::SIGHUP) };
    let deadline = Instant::now() + Duration::from_secs(2);
    while process_exists(pid) && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(25));
    }
    let _ = fs::remove_file(&paths.socket_path);
    let _ = fs::remove_file(&paths.pid_path);
}

fn process_exists(pid: libc::pid_t) -> bool {
    if pid <= 0 {
        return false;
    }
    let result = unsafe { libc::kill(pid, 0) };
    if result == 0 {
        return true;
    }
    io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

fn attach_output_loop(stream: &mut UnixStream) -> Result<Option<i32>> {
    let mut stdout = io::stdout().lock();
    loop {
        let frame = match read_frame(stream) {
            Ok(frame) => frame,
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
            Err(error) => return Err(error.into()),
        };

        match frame.kind {
            FRAME_OUTPUT => {
                stdout.write_all(&frame.payload)?;
                stdout.flush()?;
            }
            FRAME_EXIT => {
                let code = frame
                    .payload
                    .get(..4)
                    .map(i32_from_be_bytes)
                    .unwrap_or_default();
                return Ok(Some(code));
            }
            _ => {}
        }
    }
}

fn start_stdin_forwarder(writer: Arc<Mutex<UnixStream>>) {
    thread::spawn(move || {
        let mut stdin = io::stdin().lock();
        let mut buffer = [0; 8192];
        loop {
            let count = match stdin.read(&mut buffer) {
                Ok(0) => return,
                Ok(count) => count,
                Err(_) => return,
            };
            let mut stream = match writer.lock() {
                Ok(stream) => stream,
                Err(_) => return,
            };
            if write_frame(&mut stream, FRAME_INPUT, &buffer[..count]).is_err() {
                return;
            }
        }
    });
}

fn start_resize_forwarder(writer: Arc<Mutex<UnixStream>>) {
    thread::spawn(move || {
        let mut last_size = None;
        loop {
            thread::sleep(Duration::from_millis(250));
            last_size = send_resize_if_available(&writer, last_size);
        }
    });
}

fn send_resize_if_available(
    writer: &Arc<Mutex<UnixStream>>,
    last_size: Option<TerminalSize>,
) -> Option<TerminalSize> {
    let size = terminal_size(io::stdout().as_raw_fd()).ok()?;
    if Some(size) == last_size {
        return last_size;
    }

    let mut payload = Vec::with_capacity(4);
    payload.extend_from_slice(&size.rows.to_be_bytes());
    payload.extend_from_slice(&size.cols.to_be_bytes());
    let mut stream = writer.lock().ok()?;
    write_frame(&mut stream, FRAME_RESIZE, &payload).ok()?;
    Some(size)
}

fn clear_local_terminal() -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    stdout.write_all(b"\x1b[H\x1b[2J\x1b[3J")?;
    stdout.flush()
}

fn run_server_loop(listener: &UnixListener, child: &mut PtyChild) -> Result<()> {
    let listener_fd = listener.as_raw_fd();
    let mut client: Option<ServerClient> = None;
    let mut output_buffer = OutputBuffer::new(OUTPUT_BUFFER_LIMIT);
    let mut child_exit_code: Option<i32> = None;
    let mut exit_without_client_deadline: Option<Instant> = None;

    loop {
        let mut poll_fds = Vec::new();
        let master_index = if child_exit_code.is_none() {
            let index = poll_fds.len();
            poll_fds.push(libc::pollfd {
                fd: child.master_fd,
                events: libc::POLLIN,
                revents: 0,
            });
            Some(index)
        } else {
            None
        };
        let listener_index = poll_fds.len();
        poll_fds.push(libc::pollfd {
            fd: listener_fd,
            events: libc::POLLIN,
            revents: 0,
        });
        let client_index = if let Some(client) = client.as_ref() {
            let index = poll_fds.len();
            poll_fds.push(libc::pollfd {
                fd: client.stream.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            });
            Some(index)
        } else {
            None
        };

        let poll_result = unsafe { libc::poll(poll_fds.as_mut_ptr(), poll_fds.len() as _, 250) };
        if poll_result == -1 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error).context("terminal session poll failed");
        }

        if poll_fds[listener_index].revents & libc::POLLIN != 0 {
            while let Some(mut accepted) = accept_client(listener)? {
                let _ = accepted
                    .stream
                    .set_write_timeout(Some(Duration::from_secs(10)));
                let attach_options = read_attach_options(&mut accepted);
                if attach_options.replay_output
                    && replay_output(
                        &mut accepted.stream,
                        &output_buffer.tail_slice(OUTPUT_REPLAY_LIMIT),
                    )
                    .is_err()
                {
                    continue;
                }
                if let Some(exit_code) = child_exit_code {
                    let payload = exit_code.to_be_bytes();
                    let _ = write_frame(&mut accepted.stream, FRAME_EXIT, &payload);
                    return Ok(());
                }
                if matches!(
                    process_client_frames(&mut accepted, child)?,
                    ClientReadOutcome::StopRequested
                ) {
                    child.terminate();
                    return Ok(());
                }
                client = Some(accepted);
            }
        }

        if let Some(index) = master_index
            && poll_fds[index].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0
        {
            let mut buffer = [0; 8192];
            let count = unsafe {
                libc::read(
                    child.master_fd,
                    buffer.as_mut_ptr().cast::<libc::c_void>(),
                    buffer.len(),
                )
            };
            if count > 0 {
                let bytes = &buffer[..count as usize];
                output_buffer.push(bytes);
                let should_drop_client = client.as_mut().is_some_and(|client| {
                    write_frame(&mut client.stream, FRAME_OUTPUT, bytes).is_err()
                });
                if should_drop_client {
                    client = None;
                }
            } else {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
            }
        }

        if let Some(index) = client_index
            && poll_fds[index].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0
            && let Some(active_client) = client.as_mut()
        {
            match read_client_frames(active_client, child)? {
                ClientReadOutcome::Continue => {}
                ClientReadOutcome::Disconnected => {
                    client = None;
                }
                ClientReadOutcome::StopRequested => {
                    child.terminate();
                    return Ok(());
                }
            }
        }

        if child_exit_code.is_none()
            && let Some(exit_code) = child.try_wait()?
        {
            child_exit_code = Some(exit_code);
            if let Some(client) = client.as_mut() {
                let payload = exit_code.to_be_bytes();
                let _ = write_frame(&mut client.stream, FRAME_EXIT, &payload);
                return Ok(());
            }
            exit_without_client_deadline = Some(Instant::now() + Duration::from_secs(5));
        }

        if child_exit_code.is_some()
            && client.is_none()
            && exit_without_client_deadline.is_some_and(|deadline| Instant::now() >= deadline)
        {
            return Ok(());
        }
    }
}

fn accept_client(listener: &UnixListener) -> Result<Option<ServerClient>> {
    match listener.accept() {
        Ok((stream, _)) => Ok(Some(ServerClient {
            stream,
            input_buffer: Vec::new(),
        })),
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(None),
        Err(error) => Err(error).context("failed to accept terminal session client"),
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct AttachOptions {
    replay_output: bool,
}

impl AttachOptions {
    fn from_args(args: &TerminalAttachArgs) -> Self {
        Self {
            replay_output: !args.no_replay,
        }
    }

    fn from_payload(payload: &[u8]) -> Self {
        Self {
            replay_output: payload.first().copied().unwrap_or(1) != 0,
        }
    }

    fn payload(self) -> [u8; 1] {
        [u8::from(self.replay_output)]
    }
}

fn write_attach_options(stream: &mut UnixStream, options: AttachOptions) -> io::Result<()> {
    write_frame(stream, FRAME_ATTACH_OPTIONS, &options.payload())
}

fn read_attach_options(client: &mut ServerClient) -> AttachOptions {
    let _ = client
        .stream
        .set_read_timeout(Some(Duration::from_millis(100)));
    let mut buffer = [0; 8192];
    match client.stream.read(&mut buffer) {
        Ok(0) => {}
        Ok(count) => client.input_buffer.extend_from_slice(&buffer[..count]),
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut | io::ErrorKind::Interrupted
            ) => {}
        Err(_) => {}
    }
    let _ = client.stream.set_read_timeout(None);

    let Some(frame) = pop_frame(&mut client.input_buffer) else {
        return AttachOptions {
            replay_output: true,
        };
    };
    if frame.kind == FRAME_ATTACH_OPTIONS {
        return AttachOptions::from_payload(&frame.payload);
    }

    let mut preserved = frame_bytes(&frame);
    preserved.extend_from_slice(&client.input_buffer);
    client.input_buffer = preserved;
    AttachOptions {
        replay_output: true,
    }
}

fn replay_output(stream: &mut UnixStream, output: &[u8]) -> io::Result<()> {
    for chunk in output.chunks(OUTPUT_REPLAY_CHUNK_SIZE) {
        write_frame(stream, FRAME_OUTPUT, chunk)?;
    }
    Ok(())
}

fn read_client_frames(
    client: &mut ServerClient,
    child: &mut PtyChild,
) -> Result<ClientReadOutcome> {
    let mut buffer = [0; 8192];
    match client.stream.read(&mut buffer) {
        Ok(0) => return Ok(ClientReadOutcome::Disconnected),
        Ok(count) => client.input_buffer.extend_from_slice(&buffer[..count]),
        Err(error) if error.kind() == io::ErrorKind::Interrupted => {
            return Ok(ClientReadOutcome::Continue);
        }
        Err(_) => return Ok(ClientReadOutcome::Disconnected),
    }

    process_client_frames(client, child)
}

fn process_client_frames(
    client: &mut ServerClient,
    child: &mut PtyChild,
) -> Result<ClientReadOutcome> {
    for frame in drain_frames(&mut client.input_buffer) {
        match frame.kind {
            FRAME_INPUT => child.write_input(&frame.payload),
            FRAME_RESIZE => {
                if let Some(size) = TerminalSize::from_payload(&frame.payload) {
                    child.resize(size);
                }
            }
            FRAME_STOP => return Ok(ClientReadOutcome::StopRequested),
            _ => {}
        }
    }

    Ok(ClientReadOutcome::Continue)
}

struct ServerClient {
    stream: UnixStream,
    input_buffer: Vec<u8>,
}

enum ClientReadOutcome {
    Continue,
    Disconnected,
    StopRequested,
}

struct PtyChild {
    master_fd: RawFd,
    pid: libc::pid_t,
}

impl PtyChild {
    fn spawn(command: &[String], cwd: &Path, size: TerminalSize) -> Result<Self> {
        if command.is_empty() {
            bail!("terminal session command cannot be empty");
        }

        let cstrings = command
            .iter()
            .map(|arg| CString::new(arg.as_bytes()).context("terminal command contains NUL byte"))
            .collect::<Result<Vec<_>>>()?;
        let mut argv = cstrings
            .iter()
            .map(|arg| arg.as_ptr())
            .chain(std::iter::once(std::ptr::null()))
            .collect::<Vec<_>>();
        let cwd = CString::new(cwd.as_os_str().as_bytes()).context("cwd contains NUL byte")?;

        let mut master_fd: RawFd = -1;
        let mut slave_fd: RawFd = -1;
        let mut winsize = libc::winsize {
            ws_row: size.rows,
            ws_col: size.cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let open_result = unsafe {
            libc::openpty(
                &mut master_fd,
                &mut slave_fd,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut winsize,
            )
        };
        if open_result == -1 {
            return Err(io::Error::last_os_error()).context("failed to open terminal session PTY");
        }

        let pid = unsafe { libc::fork() };
        if pid == -1 {
            unsafe {
                libc::close(master_fd);
                libc::close(slave_fd);
            }
            return Err(io::Error::last_os_error())
                .context("failed to fork terminal session child");
        }

        if pid == 0 {
            unsafe {
                libc::setsid();
                #[cfg(any(target_os = "macos", target_os = "linux"))]
                {
                    libc::ioctl(slave_fd, libc::TIOCSCTTY as libc::c_ulong, 0);
                }
                libc::dup2(slave_fd, libc::STDIN_FILENO);
                libc::dup2(slave_fd, libc::STDOUT_FILENO);
                libc::dup2(slave_fd, libc::STDERR_FILENO);
                libc::close(master_fd);
                if slave_fd > libc::STDERR_FILENO {
                    libc::close(slave_fd);
                }
                if libc::chdir(cwd.as_ptr()) == -1 {
                    libc::_exit(126);
                }
                libc::execvp(cstrings[0].as_ptr(), argv.as_mut_ptr());
                libc::_exit(127);
            }
        }

        unsafe {
            libc::close(slave_fd);
        }
        Ok(Self { master_fd, pid })
    }

    fn write_input(&self, bytes: &[u8]) {
        let _ = unsafe {
            libc::write(
                self.master_fd,
                bytes.as_ptr().cast::<libc::c_void>(),
                bytes.len(),
            )
        };
    }

    fn resize(&self, size: TerminalSize) {
        let mut winsize = libc::winsize {
            ws_row: size.rows,
            ws_col: size.cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let _ = unsafe { libc::ioctl(self.master_fd, libc::TIOCSWINSZ, &mut winsize) };
        let _ = unsafe { libc::kill(-self.pid, libc::SIGWINCH) };
    }

    fn try_wait(&self) -> Result<Option<i32>> {
        let mut status = 0;
        let result = unsafe { libc::waitpid(self.pid, &mut status, libc::WNOHANG) };
        if result == 0 {
            return Ok(None);
        }
        if result == -1 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ECHILD) {
                return Ok(Some(0));
            }
            return Err(error).context("failed to wait for terminal session child");
        }

        if libc::WIFEXITED(status) {
            return Ok(Some(libc::WEXITSTATUS(status)));
        }
        if libc::WIFSIGNALED(status) {
            return Ok(Some(128 + libc::WTERMSIG(status)));
        }
        Ok(Some(0))
    }

    fn terminate(&self) {
        let _ = unsafe { libc::kill(-self.pid, libc::SIGHUP) };
        let _ = unsafe { libc::kill(self.pid, libc::SIGHUP) };
    }
}

impl Drop for PtyChild {
    fn drop(&mut self) {
        if self.master_fd >= 0 {
            unsafe {
                libc::close(self.master_fd);
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct TerminalSize {
    rows: u16,
    cols: u16,
}

impl Default for TerminalSize {
    fn default() -> Self {
        Self { rows: 24, cols: 80 }
    }
}

impl TerminalSize {
    fn from_payload(payload: &[u8]) -> Option<Self> {
        if payload.len() != 4 {
            return None;
        }
        Some(Self {
            rows: u16::from_be_bytes([payload[0], payload[1]]),
            cols: u16::from_be_bytes([payload[2], payload[3]]),
        })
    }
}

fn terminal_size(fd: RawFd) -> io::Result<TerminalSize> {
    let mut winsize = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let result = unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut winsize) };
    if result == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(TerminalSize {
        rows: winsize.ws_row.max(24),
        cols: winsize.ws_col.max(80),
    })
}

struct RawTerminalMode {
    fd: RawFd,
    original: libc::termios,
    enabled: bool,
}

impl RawTerminalMode {
    fn enter(fd: RawFd) -> Result<Self> {
        if !io::stdin().is_terminal() {
            return Ok(Self {
                fd,
                original: unsafe { std::mem::zeroed() },
                enabled: false,
            });
        }

        let mut original = unsafe { std::mem::zeroed::<libc::termios>() };
        if unsafe { libc::tcgetattr(fd, &mut original) } == -1 {
            return Err(io::Error::last_os_error()).context("failed to read terminal mode");
        }
        let mut raw = original;
        unsafe {
            libc::cfmakeraw(&mut raw);
        }
        if unsafe { libc::tcsetattr(fd, libc::TCSANOW, &raw) } == -1 {
            return Err(io::Error::last_os_error()).context("failed to set terminal raw mode");
        }
        Ok(Self {
            fd,
            original,
            enabled: true,
        })
    }
}

impl Drop for RawTerminalMode {
    fn drop(&mut self) {
        if self.enabled {
            unsafe {
                libc::tcsetattr(self.fd, libc::TCSANOW, &self.original);
            }
        }
    }
}

struct OutputBuffer {
    bytes: VecDeque<u8>,
    limit: usize,
}

impl OutputBuffer {
    fn new(limit: usize) -> Self {
        Self {
            bytes: VecDeque::new(),
            limit,
        }
    }

    fn push(&mut self, payload: &[u8]) {
        if payload.len() >= self.limit {
            self.bytes.clear();
            self.bytes.extend(
                payload[payload.len().saturating_sub(self.limit)..]
                    .iter()
                    .copied(),
            );
            return;
        }

        let overflow = self.bytes.len() + payload.len();
        if overflow > self.limit {
            self.bytes.drain(..overflow - self.limit);
        }
        self.bytes.extend(payload.iter().copied());
    }

    #[cfg(test)]
    fn as_slice(&self) -> Vec<u8> {
        self.bytes.iter().copied().collect()
    }

    fn tail_slice(&self, limit: usize) -> Vec<u8> {
        let skip = self.bytes.len().saturating_sub(limit);
        self.bytes.iter().skip(skip).copied().collect()
    }
}

struct Frame {
    kind: u8,
    payload: Vec<u8>,
}

fn write_frame(stream: &mut UnixStream, kind: u8, payload: &[u8]) -> io::Result<()> {
    let len = u32::try_from(payload.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "frame payload too large"))?;
    let mut header = [0; FRAME_HEADER_LEN];
    header[0] = kind;
    header[1..].copy_from_slice(&len.to_be_bytes());
    stream.write_all(&header)?;
    stream.write_all(payload)
}

fn read_frame(stream: &mut UnixStream) -> io::Result<Frame> {
    let mut header = [0; FRAME_HEADER_LEN];
    stream.read_exact(&mut header)?;
    let len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
    let mut payload = vec![0; len];
    stream.read_exact(&mut payload)?;
    Ok(Frame {
        kind: header[0],
        payload,
    })
}

fn drain_frames(buffer: &mut Vec<u8>) -> Vec<Frame> {
    let mut frames = Vec::new();
    while let Some(frame) = pop_frame(buffer) {
        frames.push(frame);
    }
    frames
}

fn pop_frame(buffer: &mut Vec<u8>) -> Option<Frame> {
    if buffer.len() < FRAME_HEADER_LEN {
        return None;
    }
    let header = &buffer[..FRAME_HEADER_LEN];
    let len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
    let frame_end = FRAME_HEADER_LEN + len;
    if buffer.len() < frame_end {
        return None;
    }
    let frame = Frame {
        kind: header[0],
        payload: buffer[FRAME_HEADER_LEN..frame_end].to_vec(),
    };
    buffer.drain(..frame_end);
    Some(frame)
}

fn frame_bytes(frame: &Frame) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(FRAME_HEADER_LEN + frame.payload.len());
    bytes.push(frame.kind);
    bytes.extend_from_slice(&(frame.payload.len() as u32).to_be_bytes());
    bytes.extend_from_slice(&frame.payload);
    bytes
}

fn i32_from_be_bytes(bytes: &[u8]) -> i32 {
    i32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
}

struct SessionPaths {
    storage_dir: PathBuf,
    socket_path: PathBuf,
    pid_path: PathBuf,
}

impl SessionPaths {
    fn new(storage_dir: Option<PathBuf>, session_id: &str) -> Result<Self> {
        validate_session_id(session_id)?;
        let storage_dir = storage_dir.unwrap_or_else(default_storage_dir);
        Ok(Self {
            socket_path: storage_dir.join(format!("{session_id}.sock")),
            pid_path: storage_dir.join(format!("{session_id}.pid")),
            storage_dir,
        })
    }
}

fn default_storage_dir() -> PathBuf {
    if let Some(path) =
        std::env::var_os("ARGON_TERMINAL_SESSION_DIR").filter(|value| !value.is_empty())
    {
        return PathBuf::from(path);
    }
    let uid = unsafe { libc::getuid() };
    Path::new("/tmp").join(format!("argon-terminal-sessions-{uid}"))
}

fn validate_session_id(session_id: &str) -> Result<()> {
    if session_id.is_empty() {
        bail!("terminal session id cannot be empty");
    }
    if !session_id
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        bail!("terminal session id contains unsupported characters");
    }
    Ok(())
}

fn ensure_private_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path)
        .with_context(|| format!("failed to create terminal session dir {}", path.display()))?;
    let permissions = fs::Permissions::from_mode(0o700);
    fs::set_permissions(path, permissions).with_context(|| {
        format!(
            "failed to set terminal session dir permissions for {}",
            path.display()
        )
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn output_buffer_keeps_latest_bytes() {
        let mut buffer = OutputBuffer::new(5);
        buffer.push(b"abc");
        buffer.push(b"def");
        assert_eq!(buffer.as_slice(), b"bcdef");
    }

    #[test]
    fn output_buffer_handles_large_payloads() {
        let mut buffer = OutputBuffer::new(4);
        buffer.push(b"abcdef");
        assert_eq!(buffer.as_slice(), b"cdef");
    }

    #[test]
    fn output_buffer_returns_limited_tail_slice() {
        let mut buffer = OutputBuffer::new(10);
        buffer.push(b"abcdefghij");
        assert_eq!(buffer.tail_slice(4), b"ghij");
        assert_eq!(buffer.tail_slice(20), b"abcdefghij");
    }

    #[test]
    fn frames_round_trip_from_partial_buffer() {
        let mut bytes = Vec::new();
        bytes.push(FRAME_INPUT);
        bytes.extend_from_slice(&3u32.to_be_bytes());
        bytes.extend_from_slice(b"abc");
        bytes.push(FRAME_STOP);
        bytes.extend_from_slice(&0u32.to_be_bytes());

        let frames = drain_frames(&mut bytes);
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].kind, FRAME_INPUT);
        assert_eq!(frames[0].payload, b"abc");
        assert_eq!(frames[1].kind, FRAME_STOP);
        assert!(bytes.is_empty());
    }

    #[test]
    fn session_ids_are_restricted_to_socket_safe_characters() {
        assert!(validate_session_id("argon-abc_123").is_ok());
        assert!(validate_session_id("../bad").is_err());
        assert!(validate_session_id("").is_err());
    }
}

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    process::Stdio,
    sync::Arc,
    time::Duration,
};

use tokio::{
    io::{AsyncBufReadExt, BufReader},
    process::{Child, ChildStderr, ChildStdin, Command},
    sync::Mutex,
    time::timeout,
};
use tracing::{info, warn};

use super::{discovery::DiscoveredSession, live::LiveSessionStoreHandle};

const HELPER_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);
const PIMUX_LIVE_HELPER_ENV: &str = "PIMUX_LIVE_HELPER";

#[derive(Clone, Default)]
pub struct SessionHelperManagerHandle {
    inner: Arc<Mutex<SessionHelperManager>>,
}

#[derive(Default)]
struct SessionHelperManager {
    sessions: HashMap<String, RetainedSessionHelper>,
}

struct RetainedSessionHelper {
    retain_count: usize,
    process: Option<HelperProcess>,
}

struct HelperProcess {
    stdin: ChildStdin,
    child: Child,
}

impl SessionHelperManagerHandle {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn retain_session(
        &self,
        discovered_session: &DiscoveredSession,
        pi_agent_dir: &Path,
        live_store: &LiveSessionStoreHandle,
    ) -> Result<(), String> {
        let should_spawn = {
            let mut guard = self.inner.lock().await;
            let entry = guard
                .sessions
                .entry(discovered_session.id.clone())
                .or_insert_with(|| RetainedSessionHelper {
                    retain_count: 0,
                    process: None,
                });
            entry.retain_count += 1;
            refresh_process_state(&discovered_session.id, entry);
            entry.process.is_none()
        };

        if !should_spawn || live_store.has_command_connection(&discovered_session.id).await {
            return Ok(());
        }

        let process = spawn_helper_process(discovered_session, pi_agent_dir).await?;
        let mut guard = self.inner.lock().await;
        let entry = guard
            .sessions
            .entry(discovered_session.id.clone())
            .or_insert_with(|| RetainedSessionHelper {
                retain_count: 0,
                process: None,
            });
        refresh_process_state(&discovered_session.id, entry);
        if entry.process.is_none() {
            entry.process = Some(process);
        }
        Ok(())
    }

    pub async fn release_session(&self, session_id: &str) {
        let process = {
            let mut guard = self.inner.lock().await;
            let Some(entry) = guard.sessions.get_mut(session_id) else {
                return;
            };
            refresh_process_state(session_id, entry);
            if entry.retain_count > 0 {
                entry.retain_count -= 1;
            }
            if entry.retain_count > 0 {
                return;
            }
            guard.sessions.remove(session_id).and_then(|entry| entry.process)
        };

        if let Some(process) = process {
            stop_helper_process(session_id, process).await;
        }
    }

    pub async fn shutdown(&self) {
        let processes = {
            let mut guard = self.inner.lock().await;
            guard
                .sessions
                .drain()
                .filter_map(|(session_id, entry)| entry.process.map(|process| (session_id, process)))
                .collect::<Vec<_>>()
        };

        for (session_id, process) in processes {
            stop_helper_process(&session_id, process).await;
        }
    }
}

fn refresh_process_state(session_id: &str, entry: &mut RetainedSessionHelper) {
    let Some(process) = entry.process.as_mut() else {
        return;
    };

    match process.child.try_wait() {
        Ok(Some(status)) => {
            warn!(session_id, ?status, "detached pimux helper exited");
            entry.process = None;
        }
        Ok(None) => {}
        Err(error) => {
            warn!(session_id, %error, "failed to poll detached pimux helper");
            entry.process = None;
        }
    }
}

async fn spawn_helper_process(
    discovered_session: &DiscoveredSession,
    pi_agent_dir: &Path,
) -> Result<HelperProcess, String> {
    let session_id = discovered_session.id.clone();
    let mut command = Command::new("pi");
    command
        .arg("--mode")
        .arg("rpc")
        .arg("--session")
        .arg(&discovered_session.session_file)
        .env("PI_SKIP_VERSION_CHECK", "1")
        .env("PI_CODING_AGENT_DIR", pi_agent_dir)
        .env(PIMUX_LIVE_HELPER_ENV, "1")
        .current_dir(working_dir(discovered_session, pi_agent_dir))
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let mut child = command
        .spawn()
        .map_err(|error| format!("failed to start detached pi helper: {error}"))?;
    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| "detached pi helper did not expose stdin".to_string())?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| "detached pi helper did not expose stderr".to_string())?;

    tokio::spawn(log_stderr(session_id.clone(), stderr));
    info!(session_id, "started detached pimux helper");

    Ok(HelperProcess { stdin, child })
}

async fn stop_helper_process(session_id: &str, mut process: HelperProcess) {
    drop(process.stdin);

    match timeout(HELPER_SHUTDOWN_TIMEOUT, process.child.wait()).await {
        Ok(Ok(status)) => {
            info!(session_id, ?status, "stopped detached pimux helper");
            return;
        }
        Ok(Err(error)) => {
            warn!(session_id, %error, "failed waiting for detached pimux helper to exit");
        }
        Err(_) => {
            if let Err(error) = process.child.kill().await {
                warn!(session_id, %error, "failed to kill detached pimux helper");
            }
            let _ = process.child.wait().await;
        }
    }
}

async fn log_stderr(session_id: String, stderr: ChildStderr) {
    let mut lines = BufReader::new(stderr).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim();
        if !line.is_empty() {
            warn!(session_id, "detached pi helper stderr: {}", line);
        }
    }
}

fn working_dir(discovered_session: &DiscoveredSession, pi_agent_dir: &Path) -> PathBuf {
    let cwd = PathBuf::from(&discovered_session.cwd);
    if cwd.exists() {
        cwd
    } else {
        pi_agent_dir.to_path_buf()
    }
}

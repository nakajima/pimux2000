use std::{
    path::{Path, PathBuf},
    process::Stdio,
    time::{Duration, Instant},
};

use chrono::{DateTime, TimeZone, Utc};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::Command,
    sync::{mpsc::UnboundedSender, oneshot},
};
use tracing::{error, warn};

use crate::message::{
    ImageContent, Message, MessageContentBlock, Role, collapse_whitespace, normalized_display_text,
    tool_call_summary,
};

use super::{
    discovery::DiscoveredSession,
    live::{LiveSessionEvent, LiveSessionStoreHandle, LiveSessionTransport, LiveUpdate},
    transcript,
};

const PERSISTED_SNAPSHOT_POLL_INTERVAL: Duration = Duration::from_millis(25);
const PERSISTED_SNAPSHOT_TIMEOUT: Duration = Duration::from_secs(1);

pub async fn send_message_to_session(
    discovered_session: DiscoveredSession,
    body: String,
    images: Vec<ImageContent>,
    pi_agent_dir: PathBuf,
    live_store: LiveSessionStoreHandle,
    live_updates: UnboundedSender<LiveUpdate>,
) -> Result<(), String> {
    let session_id = discovered_session.id.clone();
    let existing_snapshot = live_store.snapshot_for_session(&session_id).await;
    let was_active = existing_snapshot
        .as_ref()
        .map(|snapshot| snapshot.activity.active)
        .unwrap_or(false);

    if !was_active {
        publish_event(
            &live_store,
            &live_updates,
            LiveSessionEvent::SessionAttached {
                session_id: session_id.clone(),
                transport: LiveSessionTransport::Helper,
            },
        )
        .await;
    }

    let initial_messages = match existing_snapshot {
        Some(snapshot) => Some(snapshot.messages),
        None => transcript::build_persisted_snapshot(&discovered_session)
            .ok()
            .map(|snapshot| snapshot.messages),
    };

    if let Some(messages) = initial_messages {
        publish_event(
            &live_store,
            &live_updates,
            LiveSessionEvent::SessionSnapshot {
                session_id: session_id.clone(),
                messages,
            },
        )
        .await;
    }

    let (ack_tx, ack_rx) = oneshot::channel();
    tokio::spawn(run_headless_prompt(
        discovered_session,
        body,
        images,
        pi_agent_dir,
        live_store,
        live_updates,
        was_active,
        ack_tx,
    ));

    ack_rx.await.map_err(|_| {
        format!(
            "headless pi runner for session {} ended before confirming message delivery",
            session_id
        )
    })?
}

async fn run_headless_prompt(
    discovered_session: DiscoveredSession,
    body: String,
    images: Vec<ImageContent>,
    pi_agent_dir: PathBuf,
    live_store: LiveSessionStoreHandle,
    live_updates: UnboundedSender<LiveUpdate>,
    was_active: bool,
    ack_tx: oneshot::Sender<Result<(), String>>,
) {
    let session_id = discovered_session.id.clone();
    let mut ack_tx = Some(ack_tx);

    let result = async {
        let mut command = Command::new(super::resolve_pi_executable(&pi_agent_dir));
        command
            .arg("--mode")
            .arg("rpc")
            .arg("--session")
            .arg(&discovered_session.session_file)
            .arg("--no-extensions")
            .env("PI_SKIP_VERSION_CHECK", "1")
            .env("PI_CODING_AGENT_DIR", &pi_agent_dir)
            .current_dir(working_dir(&discovered_session, &pi_agent_dir))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        let mut child = command
            .spawn()
            .map_err(|error| format!("failed to start pi rpc runner: {error}"))?;
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| "pi rpc runner did not expose stdin".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "pi rpc runner did not expose stdout".to_string())?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| "pi rpc runner did not expose stderr".to_string())?;

        tokio::spawn(log_stderr(session_id.clone(), stderr));

        let prompt_id = format!("send-{session_id}");
        let payload = prompt_payload(&prompt_id, &body, &images);
        stdin
            .write_all(payload.to_string().as_bytes())
            .await
            .map_err(|error| format!("failed to write prompt to pi rpc runner: {error}"))?;
        stdin
            .write_all(b"\n")
            .await
            .map_err(|error| format!("failed to write newline to pi rpc runner: {error}"))?;
        stdin
            .flush()
            .await
            .map_err(|error| format!("failed to flush pi rpc runner stdin: {error}"))?;

        let mut lines = BufReader::new(stdout).lines();
        let mut prompt_accepted = false;
        let mut delivery_confirmed = false;
        let mut saw_user_message_end = false;

        while let Some(line) = lines
            .next_line()
            .await
            .map_err(|error| format!("failed reading pi rpc output: {error}"))?
        {
            let event: Value = serde_json::from_str(&line)
                .map_err(|error| format!("failed to parse pi rpc event: {error}"))?;
            let event_type = event
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or_default();

            if event_type == "response"
                && event.get("id").and_then(Value::as_str) == Some(prompt_id.as_str())
            {
                let success = event
                    .get("success")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                if success {
                    // In pi RPC mode, the prompt command responds immediately after enqueueing work.
                    // Wait for the actual user message event (or turn completion as a fallback)
                    // before telling the server that delivery succeeded.
                    prompt_accepted = true;
                    if saw_user_message_end {
                        confirm_delivery(&mut ack_tx, &mut delivery_confirmed);
                    }
                } else {
                    let error = response_error_message(&event);
                    if let Some(ack_tx) = ack_tx.take() {
                        let _ = ack_tx.send(Err(error.clone()));
                    }
                    return Err(error);
                }
                continue;
            }

            match event_type {
                "message_update" => {
                    // Headless RPC message updates do not include durable pi entry IDs.
                    // Keep the live transcript aligned with persisted transcript IDs by
                    // only publishing snapshots after the message has been persisted.
                }
                "message_end" => {
                    if let Some(message) = event.get("message").and_then(rpc_message_to_message) {
                        let role = message.role.clone();
                        refresh_persisted_snapshot(
                            &discovered_session,
                            &live_store,
                            &live_updates,
                            Some(&message),
                        )
                        .await;

                        if role == Role::User {
                            saw_user_message_end = true;
                            if prompt_accepted {
                                confirm_delivery(&mut ack_tx, &mut delivery_confirmed);
                            }
                        }
                    }
                }
                "turn_end" => {
                    refresh_persisted_snapshot(
                        &discovered_session,
                        &live_store,
                        &live_updates,
                        None,
                    )
                    .await;

                    if prompt_accepted {
                        confirm_delivery(&mut ack_tx, &mut delivery_confirmed);
                    }
                }
                _ => {}
            }
        }

        if !prompt_accepted {
            return Err(format!(
                "pi rpc runner for session {} ended before accepting the prompt",
                session_id
            ));
        }

        if !delivery_confirmed {
            return Err(format!(
                "pi rpc runner for session {} ended before confirming message delivery",
                session_id
            ));
        }

        if let Err(error) = child.kill().await {
            warn!(session_id, %error, "failed to stop pi rpc runner");
        }
        let _ = child.wait().await;
        Ok(())
    }
    .await;

    if let Err(error) = result {
        if let Some(ack_tx) = ack_tx.take() {
            let _ = ack_tx.send(Err(error.clone()));
        }
        error!(session_id, %error, "headless pi runner failed");
    }

    if !was_active {
        publish_event(
            &live_store,
            &live_updates,
            LiveSessionEvent::SessionDetached { session_id },
        )
        .await;
    }
}

fn confirm_delivery(
    ack_tx: &mut Option<oneshot::Sender<Result<(), String>>>,
    delivery_confirmed: &mut bool,
) {
    if *delivery_confirmed {
        return;
    }

    if let Some(ack_tx) = ack_tx.take() {
        let _ = ack_tx.send(Ok(()));
    }
    *delivery_confirmed = true;
}

async fn publish_event(
    live_store: &LiveSessionStoreHandle,
    live_updates: &UnboundedSender<LiveUpdate>,
    event: LiveSessionEvent,
) {
    if let Some(snapshot) = live_store.apply_event(event).await {
        let _ = live_updates.send(LiveUpdate::Transcript {
            snapshot,
            active_session: None,
        });
    }
}

async fn refresh_persisted_snapshot(
    discovered_session: &DiscoveredSession,
    live_store: &LiveSessionStoreHandle,
    live_updates: &UnboundedSender<LiveUpdate>,
    expected_message: Option<&Message>,
) {
    let session_id = discovered_session.id.clone();
    let deadline = Instant::now() + PERSISTED_SNAPSHOT_TIMEOUT;
    let mut last_snapshot: Option<Vec<Message>> = None;
    let mut last_error: Option<String> = None;

    loop {
        match transcript::build_persisted_snapshot(discovered_session) {
            Ok(snapshot) => {
                let messages = snapshot.messages;
                let matches_expected = expected_message
                    .map(|message| snapshot_contains_message(&messages, message))
                    .unwrap_or(true);

                if matches_expected {
                    publish_event(
                        live_store,
                        live_updates,
                        LiveSessionEvent::SessionSnapshot {
                            session_id: session_id.clone(),
                            messages,
                        },
                    )
                    .await;
                    return;
                }

                last_snapshot = Some(messages);
            }
            Err(error) => {
                last_error = Some(error.to_string());
            }
        }

        if Instant::now() >= deadline {
            break;
        }

        tokio::time::sleep(PERSISTED_SNAPSHOT_POLL_INTERVAL).await;
    }

    if let Some(messages) = last_snapshot {
        publish_event(
            live_store,
            live_updates,
            LiveSessionEvent::SessionSnapshot {
                session_id: session_id.clone(),
                messages,
            },
        )
        .await;
    }

    if let Some(expected_message) = expected_message {
        warn!(
            session_id = session_id.as_str(),
            role = ?expected_message.role,
            created_at = %expected_message.created_at,
            "persisted transcript did not include message before timeout"
        );
    } else if let Some(error) = last_error {
        warn!(
            session_id = session_id.as_str(),
            error, "failed to rebuild persisted transcript snapshot"
        );
    }
}

fn snapshot_contains_message(messages: &[Message], expected: &Message) -> bool {
    messages
        .iter()
        .any(|message| same_message_ignoring_id(message, expected))
}

fn same_message_ignoring_id(lhs: &Message, rhs: &Message) -> bool {
    lhs.created_at == rhs.created_at
        && lhs.role == rhs.role
        && lhs.tool_name == rhs.tool_name
        && text_matches(&lhs.body, &rhs.body)
        && blocks_match(&lhs.blocks, &rhs.blocks)
}

fn blocks_match(lhs: &[MessageContentBlock], rhs: &[MessageContentBlock]) -> bool {
    lhs.len() == rhs.len()
        && lhs.iter().zip(rhs).all(|(lhs, rhs)| {
            lhs.kind == rhs.kind
                && option_text_matches(lhs.text.as_deref(), rhs.text.as_deref())
                && option_text_matches(lhs.tool_call_name.as_deref(), rhs.tool_call_name.as_deref())
                && lhs.mime_type == rhs.mime_type
                && lhs.data == rhs.data
                && lhs.attachment_id == rhs.attachment_id
        })
}

fn option_text_matches(lhs: Option<&str>, rhs: Option<&str>) -> bool {
    match (lhs, rhs) {
        (Some(lhs), Some(rhs)) => text_matches(lhs, rhs),
        (None, None) => true,
        _ => false,
    }
}

fn text_matches(lhs: &str, rhs: &str) -> bool {
    lhs == rhs || lhs.starts_with(rhs) || rhs.starts_with(lhs)
}

async fn log_stderr(session_id: String, stderr: tokio::process::ChildStderr) {
    let mut lines = BufReader::new(stderr).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim();
        if !line.is_empty() {
            warn!(session_id, "pi rpc stderr: {}", line);
        }
    }
}

fn prompt_payload(prompt_id: &str, body: &str, images: &[ImageContent]) -> Value {
    let mut payload = json!({
        "id": prompt_id,
        "type": "prompt",
        "message": body,
    });

    if !images.is_empty() {
        payload["images"] = serde_json::to_value(images).expect("images serialize");
    }

    payload
}

fn response_error_message(event: &Value) -> String {
    event
        .get("error")
        .and_then(Value::as_str)
        .or_else(|| event.get("message").and_then(Value::as_str))
        .or_else(|| {
            event
                .get("data")
                .and_then(|data| data.get("error"))
                .and_then(Value::as_str)
        })
        .unwrap_or("pi rpc prompt failed")
        .to_string()
}

fn working_dir(discovered_session: &DiscoveredSession, pi_agent_dir: &Path) -> PathBuf {
    let cwd = PathBuf::from(&discovered_session.cwd);
    if cwd.exists() {
        cwd
    } else {
        pi_agent_dir.to_path_buf()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeadlessSessionState {
    pub session_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeadlessForkMessage {
    pub entry_id: String,
    pub text: String,
}

pub async fn set_session_name(
    discovered_session: DiscoveredSession,
    name: String,
    pi_agent_dir: PathBuf,
) -> Result<(), String> {
    run_rpc_commands(
        discovered_session,
        vec![RpcCommand {
            command: "set_session_name",
            payload: json!({
                "type": "set_session_name",
                "name": name,
            }),
        }],
        pi_agent_dir,
    )
    .await
    .map(|_| ())
}

pub async fn compact_session(
    discovered_session: DiscoveredSession,
    custom_instructions: Option<String>,
    pi_agent_dir: PathBuf,
) -> Result<(), String> {
    run_rpc_commands(
        discovered_session,
        vec![RpcCommand {
            command: "compact",
            payload: json!({
                "type": "compact",
                "customInstructions": custom_instructions,
            }),
        }],
        pi_agent_dir,
    )
    .await
    .map(|_| ())
}

pub async fn new_session(
    discovered_session: DiscoveredSession,
    pi_agent_dir: PathBuf,
) -> Result<HeadlessSessionState, String> {
    let responses = run_rpc_commands(
        discovered_session,
        vec![
            RpcCommand {
                command: "new_session",
                payload: json!({ "type": "new_session" }),
            },
            RpcCommand {
                command: "get_state",
                payload: json!({ "type": "get_state" }),
            },
        ],
        pi_agent_dir,
    )
    .await?;

    let cancelled = rpc_response_data(&responses[0])
        .and_then(|data| data.get("cancelled"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if cancelled {
        return Err("new session cancelled".to_string());
    }

    extract_session_state(&responses[1])
}

pub async fn get_fork_messages(
    discovered_session: DiscoveredSession,
    pi_agent_dir: PathBuf,
) -> Result<Vec<HeadlessForkMessage>, String> {
    let responses = run_rpc_commands(
        discovered_session,
        vec![RpcCommand {
            command: "get_fork_messages",
            payload: json!({ "type": "get_fork_messages" }),
        }],
        pi_agent_dir,
    )
    .await?;

    let Some(messages) = rpc_response_data(&responses[0])
        .and_then(|data| data.get("messages"))
        .and_then(Value::as_array)
    else {
        return Ok(Vec::new());
    };

    Ok(messages
        .iter()
        .filter_map(|message| {
            Some(HeadlessForkMessage {
                entry_id: message.get("entryId")?.as_str()?.to_string(),
                text: message.get("text")?.as_str()?.to_string(),
            })
        })
        .collect())
}

pub async fn fork_session(
    discovered_session: DiscoveredSession,
    entry_id: String,
    pi_agent_dir: PathBuf,
) -> Result<HeadlessSessionState, String> {
    let responses = run_rpc_commands(
        discovered_session,
        vec![
            RpcCommand {
                command: "fork",
                payload: json!({
                    "type": "fork",
                    "entryId": entry_id,
                }),
            },
            RpcCommand {
                command: "get_state",
                payload: json!({ "type": "get_state" }),
            },
        ],
        pi_agent_dir,
    )
    .await?;

    let cancelled = rpc_response_data(&responses[0])
        .and_then(|data| data.get("cancelled"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if cancelled {
        return Err("fork cancelled".to_string());
    }

    extract_session_state(&responses[1])
}

struct RpcCommand {
    command: &'static str,
    payload: Value,
}

async fn run_rpc_commands(
    discovered_session: DiscoveredSession,
    commands: Vec<RpcCommand>,
    pi_agent_dir: PathBuf,
) -> Result<Vec<Value>, String> {
    let session_id = discovered_session.id.clone();
    let mut command = Command::new(super::resolve_pi_executable(&pi_agent_dir));
    command
        .arg("--mode")
        .arg("rpc")
        .arg("--session")
        .arg(&discovered_session.session_file)
        .arg("--no-extensions")
        .env("PI_SKIP_VERSION_CHECK", "1")
        .env("PI_CODING_AGENT_DIR", &pi_agent_dir)
        .current_dir(working_dir(&discovered_session, &pi_agent_dir))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let mut child = command
        .spawn()
        .map_err(|error| format!("failed to start pi rpc runner: {error}"))?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| "pi rpc runner did not expose stdin".to_string())?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "pi rpc runner did not expose stdout".to_string())?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| "pi rpc runner did not expose stderr".to_string())?;

    tokio::spawn(log_stderr(session_id.clone(), stderr));

    let mut lines = BufReader::new(stdout).lines();
    let mut responses = Vec::with_capacity(commands.len());

    for (index, rpc_command) in commands.into_iter().enumerate() {
        let request_id = format!("rpc-{session_id}-{index}");
        let mut payload = rpc_command.payload;
        let Some(object) = payload.as_object_mut() else {
            return Err("rpc command payload must be an object".to_string());
        };
        object.insert("id".to_string(), Value::String(request_id.clone()));

        stdin
            .write_all(payload.to_string().as_bytes())
            .await
            .map_err(|error| format!("failed to write command to pi rpc runner: {error}"))?;
        stdin
            .write_all(b"\n")
            .await
            .map_err(|error| format!("failed to write newline to pi rpc runner: {error}"))?;
        stdin
            .flush()
            .await
            .map_err(|error| format!("failed to flush pi rpc runner stdin: {error}"))?;

        let response = loop {
            let Some(line) = lines
                .next_line()
                .await
                .map_err(|error| format!("failed reading pi rpc output: {error}"))?
            else {
                return Err(format!(
                    "pi rpc runner for session {} ended before responding to {}",
                    session_id, rpc_command.command
                ));
            };

            let event: Value = serde_json::from_str(&line)
                .map_err(|error| format!("failed to parse pi rpc event: {error}"))?;
            let is_response = event.get("type").and_then(Value::as_str) == Some("response");
            let matches_id = event.get("id").and_then(Value::as_str) == Some(request_id.as_str());
            let matches_command =
                event.get("command").and_then(Value::as_str) == Some(rpc_command.command);
            if !is_response || (!matches_id && !matches_command) {
                continue;
            }

            let success = event
                .get("success")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            if !success {
                return Err(response_error_message(&event));
            }

            break event;
        };

        responses.push(response);
    }

    if let Err(error) = child.kill().await {
        warn!(session_id, %error, "failed to stop pi rpc runner");
    }
    let _ = child.wait().await;

    Ok(responses)
}

fn rpc_response_data(response: &Value) -> Option<&Value> {
    response.get("data")
}

fn extract_session_state(response: &Value) -> Result<HeadlessSessionState, String> {
    let session_id = rpc_response_data(response)
        .and_then(|data| data.get("sessionId"))
        .and_then(Value::as_str)
        .ok_or_else(|| "pi rpc get_state response did not include sessionId".to_string())?;

    Ok(HeadlessSessionState {
        session_id: session_id.to_string(),
    })
}

fn rpc_message_to_message(value: &Value) -> Option<Message> {
    let role = Role::from_raw(value.get("role").and_then(Value::as_str)?);

    let created_at = value.get("timestamp").and_then(parse_unix_millis)?;

    let mut parsed = match role.clone() {
        Role::User | Role::ToolResult | Role::Custom | Role::Other(_) => Message::from_blocks(
            created_at,
            role,
            content_blocks(value.get("content"), false),
        ),
        Role::Assistant => {
            Message::from_blocks(created_at, role, content_blocks(value.get("content"), true))
        }
        Role::BranchSummary => Message::from_text(
            created_at,
            role,
            collapse_whitespace(value.get("summary").and_then(Value::as_str)?),
        ),
        Role::CompactionSummary => Message::from_text(
            created_at,
            role,
            collapse_whitespace(value.get("summary").and_then(Value::as_str)?),
        ),
        Role::BashExecution => Message::from_text(created_at, role, flatten_bash_execution(value)?),
    }?;

    parsed.tool_name = message_tool_name(value);
    parsed.tool_call_id = message_tool_call_id(value);
    Some(parsed)
}

fn parse_unix_millis(value: &Value) -> Option<DateTime<Utc>> {
    let millis = if let Some(value) = value.as_i64() {
        value
    } else {
        let unsigned = value.as_u64()?;
        i64::try_from(unsigned).ok()?
    };

    Utc.timestamp_millis_opt(millis).single()
}

fn message_tool_name(message: &Value) -> Option<String> {
    let tool_name = message.get("toolName").and_then(Value::as_str)?;
    let tool_name = collapse_whitespace(tool_name);
    if tool_name.is_empty() {
        None
    } else {
        Some(tool_name)
    }
}

fn message_tool_call_id(message: &Value) -> Option<String> {
    message
        .get("toolCallId")
        .and_then(Value::as_str)
        .and_then(normalized_display_text)
}

fn content_blocks(content: Option<&Value>, include_tool_calls: bool) -> Vec<MessageContentBlock> {
    let Some(content) = content else {
        return Vec::new();
    };

    match content {
        Value::String(text) => MessageContentBlock::text(text).into_iter().collect(),
        Value::Array(blocks) => blocks
            .iter()
            .filter_map(|block| match block.get("type").and_then(Value::as_str) {
                Some("text") => block
                    .get("text")
                    .and_then(Value::as_str)
                    .and_then(MessageContentBlock::text),
                Some("thinking") => block
                    .get("thinking")
                    .and_then(Value::as_str)
                    .and_then(MessageContentBlock::thinking),
                Some("toolCall") if include_tool_calls => {
                    let name = block.get("name").and_then(Value::as_str)?;
                    let summary = tool_call_summary(name, block.get("arguments"));
                    match block.get("id").and_then(Value::as_str) {
                        Some(tool_call_id) => MessageContentBlock::tool_call_with_id(
                            Some(tool_call_id),
                            name,
                            summary.as_deref(),
                        ),
                        None => MessageContentBlock::tool_call(name, summary.as_deref()),
                    }
                }
                Some("image") => Some(MessageContentBlock::image(
                    block.get("mimeType").and_then(Value::as_str),
                    block.get("data").and_then(Value::as_str),
                )),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}

fn flatten_bash_execution(value: &Value) -> Option<String> {
    let mut parts = Vec::new();

    if let Some(command) = value.get("command").and_then(Value::as_str)
        && let Some(command) = normalized_display_text(command)
    {
        parts.push(format!("$ {command}"));
    }

    if let Some(output) = value.get("output").and_then(Value::as_str)
        && let Some(output) = normalized_display_text(output)
    {
        parts.push(output);
    }

    let mut metadata = Vec::new();
    if let Some(exit_code) = value.get("exitCode").and_then(Value::as_i64) {
        metadata.push(format!("exit code: {exit_code}"));
    }
    if value.get("cancelled").and_then(Value::as_bool) == Some(true) {
        metadata.push("cancelled".to_string());
    }
    if value.get("truncated").and_then(Value::as_bool) == Some(true) {
        metadata.push("truncated".to_string());
    }
    if let Some(path) = value.get("fullOutputPath").and_then(Value::as_str)
        && let Some(path) = normalized_display_text(path)
    {
        metadata.push(format!("full output: {path}"));
    }
    if !metadata.is_empty() {
        parts.push(metadata.join("\n"));
    }

    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n\n"))
    }
}

#[cfg(test)]
mod tests {
    use chrono::Utc;
    use serde_json::json;

    use super::{content_blocks, prompt_payload, rpc_message_to_message, same_message_ignoring_id};
    use crate::message::{ImageContent, Message, MessageContentBlockKind, Role};

    #[test]
    fn prompt_payload_includes_images_when_present() {
        let payload = prompt_payload(
            "req-1",
            "what is this",
            &[ImageContent::new("image/png", "ZmFrZQ==")],
        );

        assert_eq!(payload["id"], "req-1");
        assert_eq!(payload["type"], "prompt");
        assert_eq!(payload["message"], "what is this");
        assert_eq!(payload["images"][0]["type"], "image");
        assert_eq!(payload["images"][0]["mimeType"], "image/png");
    }

    #[test]
    fn content_blocks_preserve_image_blocks() {
        let content = json!([
            {
                "type": "image",
                "mimeType": "image/png",
                "data": "ZmFrZQ=="
            }
        ]);

        let blocks = content_blocks(Some(&content), false);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].kind, MessageContentBlockKind::Image);
        assert_eq!(blocks[0].mime_type.as_deref(), Some("image/png"));
        assert_eq!(blocks[0].data.as_deref(), Some("ZmFrZQ=="));
    }

    #[test]
    fn same_message_ignoring_id_allows_truncated_persisted_text() {
        let timestamp = Utc::now();
        let live = Message::from_text(timestamp, Role::Assistant, "abcdef").unwrap();
        let mut persisted = live.clone();
        persisted.message_id = Some("entry-1".to_string());
        persisted.body = "abc".to_string();
        persisted.blocks[0].text = Some("abc".to_string());

        assert!(same_message_ignoring_id(&persisted, &live));
    }

    #[test]
    fn rpc_messages_preserve_tool_call_id_and_unknown_role() {
        let message = json!({
            "timestamp": 1_000,
            "role": "futureRole",
            "toolCallId": "call-xyz",
            "content": [
                { "type": "text", "text": "hello" }
            ]
        });

        let parsed = rpc_message_to_message(&message).unwrap();
        assert_eq!(parsed.role, Role::Other("futureRole".to_string()));
        assert_eq!(parsed.tool_call_id.as_deref(), Some("call-xyz"));
    }
}

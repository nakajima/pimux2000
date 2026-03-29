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

use crate::message::{
    ImageContent, Message, MessageContentBlock, Role, collapse_whitespace, normalized_display_text,
};

use super::{
    discovery::DiscoveredSession,
    live::{LiveSessionEvent, LiveSessionStoreHandle, LiveUpdate},
    transcript,
};

const PARTIAL_UPDATE_THROTTLE: Duration = Duration::from_millis(150);

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
        let mut command = Command::new("pi");
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
        let mut pending_partial: Option<Message> = None;
        let mut last_partial_sent_at: Option<Instant> = None;

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
                    if let Some(message) = event.get("message").and_then(rpc_message_to_message)
                        && message.role == Role::Assistant
                    {
                        let now = Instant::now();
                        let should_publish = last_partial_sent_at
                            .map(|last| now.duration_since(last) >= PARTIAL_UPDATE_THROTTLE)
                            .unwrap_or(true);

                        if should_publish {
                            publish_event(
                                &live_store,
                                &live_updates,
                                LiveSessionEvent::AssistantPartial {
                                    session_id: session_id.clone(),
                                    message,
                                },
                            )
                            .await;
                            last_partial_sent_at = Some(now);
                            pending_partial = None;
                        } else {
                            pending_partial = Some(message);
                        }
                    }
                }
                "message_end" => {
                    if let Some(message) = event.get("message").and_then(rpc_message_to_message) {
                        let role = message.role.clone();
                        publish_event(
                            &live_store,
                            &live_updates,
                            LiveSessionEvent::SessionAppend {
                                session_id: session_id.clone(),
                                messages: vec![message],
                            },
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
                    if prompt_accepted {
                        confirm_delivery(&mut ack_tx, &mut delivery_confirmed);
                    }
                    flush_pending_partial(
                        &session_id,
                        &live_store,
                        &live_updates,
                        &mut pending_partial,
                    )
                    .await;
                }
                _ => {}
            }
        }

        flush_pending_partial(
            &session_id,
            &live_store,
            &live_updates,
            &mut pending_partial,
        )
        .await;

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
            eprintln!("failed to stop pi rpc runner for {}: {error}", session_id);
        }
        let _ = child.wait().await;
        Ok(())
    }
    .await;

    if let Err(error) = result {
        if let Some(ack_tx) = ack_tx.take() {
            let _ = ack_tx.send(Err(error.clone()));
        }
        eprintln!("headless pi runner failed for {}: {error}", session_id);
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
        let _ = live_updates.send(LiveUpdate {
            snapshot,
            active_session: None,
        });
    }
}

async fn flush_pending_partial(
    session_id: &str,
    live_store: &LiveSessionStoreHandle,
    live_updates: &UnboundedSender<LiveUpdate>,
    pending_partial: &mut Option<Message>,
) {
    let Some(message) = pending_partial.take() else {
        return;
    };

    publish_event(
        live_store,
        live_updates,
        LiveSessionEvent::AssistantPartial {
            session_id: session_id.to_string(),
            message,
        },
    )
    .await;
}

async fn log_stderr(session_id: String, stderr: tokio::process::ChildStderr) {
    let mut lines = BufReader::new(stderr).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim();
        if !line.is_empty() {
            eprintln!("pi rpc stderr [{}]: {}", session_id, line);
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

fn rpc_message_to_message(value: &Value) -> Option<Message> {
    let role = match value.get("role").and_then(Value::as_str)? {
        "user" => Role::User,
        "assistant" => Role::Assistant,
        "toolResult" => Role::ToolResult,
        "bashExecution" => Role::BashExecution,
        "custom" => Role::Custom,
        "branchSummary" => Role::BranchSummary,
        "compactionSummary" => Role::CompactionSummary,
        _ => Role::Other,
    };

    let created_at = value.get("timestamp").and_then(parse_unix_millis)?;

    match role {
        Role::User | Role::ToolResult | Role::Custom | Role::Other => Message::from_blocks(
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
    }
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
                Some("toolCall") if include_tool_calls => block
                    .get("name")
                    .and_then(Value::as_str)
                    .and_then(MessageContentBlock::tool_call),
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

    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n\n"))
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{content_blocks, prompt_payload};
    use crate::message::{ImageContent, MessageContentBlockKind};

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
}

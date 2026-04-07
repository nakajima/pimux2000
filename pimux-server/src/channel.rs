use serde::{Deserialize, Serialize};

use crate::{
    host::HostIdentity,
    message::ImageContent,
    session::{
        ActiveSession, SessionBuiltinCommandRequest, SessionBuiltinCommandResponse, SessionCommand,
        SessionCommandCompletion,
    },
    transcript::{
        SessionMessagesResponse, SessionTerminalOnlyUiState, SessionUiDialogAction,
        SessionUiDialogState, SessionUiState,
    },
};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum AgentToServerMessage {
    Hello {
        host: HostIdentity,
    },
    HostSnapshot {
        sessions: Vec<ActiveSession>,
    },
    LiveSessionUpdate {
        session: SessionMessagesResponse,
        active_session: Option<ActiveSession>,
    },
    LiveUiUpdate {
        session_id: String,
        ui_state: SessionUiState,
    },
    LiveUiDialogUpdate {
        session_id: String,
        ui_dialog_state: Option<SessionUiDialogState>,
    },
    LiveTerminalOnlyUiUpdate {
        session_id: String,
        terminal_only_ui_state: Option<SessionTerminalOnlyUiState>,
    },
    FetchTranscriptResult {
        request_id: String,
        session: Option<SessionMessagesResponse>,
        error: Option<String>,
    },
    FetchAttachmentResult {
        request_id: String,
        mime_type: Option<String>,
        data: Option<String>,
        error: Option<String>,
    },
    SendMessageResult {
        request_id: String,
        error: Option<String>,
    },
    GetCommandsResult {
        request_id: String,
        commands: Option<Vec<SessionCommand>>,
        error: Option<String>,
    },
    GetCommandArgumentCompletionsResult {
        request_id: String,
        completions: Option<Vec<SessionCommandCompletion>>,
        error: Option<String>,
    },
    GetAtCompletionsResult {
        request_id: String,
        completions: Option<Vec<SessionCommandCompletion>>,
        error: Option<String>,
    },
    UiDialogActionResult {
        request_id: String,
        error: Option<String>,
    },
    BuiltinCommandResult {
        request_id: String,
        response: Option<SessionBuiltinCommandResponse>,
        error: Option<String>,
    },
    Ping,
    Pong,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ServerToAgentMessage {
    FetchTranscript {
        request_id: String,
        session_id: String,
    },
    FetchAttachment {
        request_id: String,
        session_id: String,
        attachment_id: String,
    },
    SendMessage {
        request_id: String,
        session_id: String,
        body: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        images: Vec<ImageContent>,
    },
    GetCommands {
        request_id: String,
        session_id: String,
    },
    GetCommandArgumentCompletions {
        request_id: String,
        session_id: String,
        command_name: String,
        argument_prefix: String,
    },
    GetAtCompletions {
        request_id: String,
        session_id: String,
        prefix: String,
    },
    UiDialogAction {
        request_id: String,
        session_id: String,
        dialog_id: String,
        action: SessionUiDialogAction,
    },
    BuiltinCommand {
        request_id: String,
        session_id: String,
        action: SessionBuiltinCommandRequest,
    },
    RetainSessionHelper {
        session_id: String,
    },
    ReleaseSessionHelper {
        session_id: String,
    },
    InterruptSession {
        session_id: String,
    },
    Ping,
    Pong,
}

use std::{env, time::Duration};

use chrono::{DateTime, Utc};
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_postgres::{Client, GenericClient, NoTls};
use tracing::{info, warn};

use crate::{
    host::{HostAuth, HostIdentity},
    message::{Message, Role},
    session::ActiveSession,
    transcript::{SessionMessagesResponse, TranscriptFreshnessState, TranscriptSource},
};

use super::BoxError;

pub const POSTGRES_BACKUP_URL_ENV: &str = "PIMUX_BACKUP_POSTGRES_URL";
const BACKUP_QUEUE_CAPACITY: usize = 256;
const RECONNECT_DELAY: Duration = Duration::from_secs(2);
const SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS sessions (
    host_location TEXT NOT NULL,
    session_id TEXT NOT NULL,
    host_auth TEXT NOT NULL,
    summary TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    last_user_message_at TIMESTAMPTZ,
    last_assistant_message_at TIMESTAMPTZ,
    cwd TEXT,
    model TEXT,
    context_usage_used_tokens BIGINT,
    context_usage_max_tokens BIGINT,
    supports_images BOOLEAN,
    transcript_freshness_state TEXT,
    transcript_freshness_source TEXT,
    transcript_freshness_as_of TIMESTAMPTZ,
    activity_active BOOLEAN,
    activity_attached BOOLEAN,
    warnings_json JSONB,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (host_location, session_id)
);
CREATE INDEX IF NOT EXISTS sessions_updated_at_idx
    ON sessions (updated_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS sessions_last_seen_at_idx
    ON sessions (last_seen_at DESC);

CREATE TABLE IF NOT EXISTS messages (
    host_location TEXT NOT NULL,
    session_id TEXT NOT NULL,
    dedupe_key TEXT NOT NULL,
    message_id TEXT,
    ordinal INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    role TEXT NOT NULL,
    body TEXT NOT NULL,
    tool_name TEXT,
    message_json JSONB NOT NULL,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (host_location, session_id, dedupe_key),
    FOREIGN KEY (host_location, session_id)
        REFERENCES sessions (host_location, session_id)
        ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS messages_session_created_at_idx
    ON messages (host_location, session_id, created_at, ordinal);
CREATE INDEX IF NOT EXISTS messages_message_id_idx
    ON messages (message_id)
    WHERE message_id IS NOT NULL;
"#;

#[derive(Debug, Clone)]
pub struct PostgresBackupHandle {
    sender: mpsc::Sender<BackupEvent>,
}

#[derive(Debug, Clone)]
enum BackupEvent {
    SessionsSnapshot {
        host: HostIdentity,
        sessions: Vec<ActiveSession>,
        observed_at: DateTime<Utc>,
    },
    Transcript {
        host: HostIdentity,
        active_session: Option<ActiveSession>,
        transcript: SessionMessagesResponse,
        observed_at: DateTime<Utc>,
    },
}

#[derive(Debug, Clone)]
struct Config {
    url: String,
}

pub struct PostgresBackupStore {
    client: Client,
}

struct SessionRow {
    host_location: String,
    session_id: String,
    host_auth: String,
    summary: Option<String>,
    created_at: Option<DateTime<Utc>>,
    updated_at: Option<DateTime<Utc>>,
    last_user_message_at: Option<DateTime<Utc>>,
    last_assistant_message_at: Option<DateTime<Utc>>,
    cwd: Option<String>,
    model: Option<String>,
    context_usage_used_tokens: Option<i64>,
    context_usage_max_tokens: Option<i64>,
    supports_images: Option<bool>,
    transcript_freshness_state: Option<String>,
    transcript_freshness_source: Option<String>,
    transcript_freshness_as_of: Option<DateTime<Utc>>,
    activity_active: Option<bool>,
    activity_attached: Option<bool>,
    warnings_json: Option<Value>,
    last_seen_at: DateTime<Utc>,
}

pub async fn start_from_env() -> Result<Option<PostgresBackupHandle>, BoxError> {
    let Some(url) = postgres_url_from_env() else {
        return Ok(None);
    };

    start(Config { url }).await.map(Some)
}

pub async fn connect_from_env_required() -> Result<PostgresBackupStore, BoxError> {
    let Some(url) = postgres_url_from_env() else {
        return Err(format!("{POSTGRES_BACKUP_URL_ENV} is not set").into());
    };

    PostgresBackupStore::connect(&url).await
}

impl PostgresBackupHandle {
    pub async fn record_sessions_snapshot(
        &self,
        host: &HostIdentity,
        sessions: &[ActiveSession],
    ) -> Result<(), ()> {
        self.sender
            .send(BackupEvent::SessionsSnapshot {
                host: host.clone(),
                sessions: sessions.to_vec(),
                observed_at: Utc::now(),
            })
            .await
            .map_err(|_| ())
    }

    pub async fn record_transcript(
        &self,
        host: &HostIdentity,
        active_session: Option<&ActiveSession>,
        transcript: &SessionMessagesResponse,
    ) -> Result<(), ()> {
        self.sender
            .send(BackupEvent::Transcript {
                host: host.clone(),
                active_session: active_session.cloned(),
                transcript: transcript.clone(),
                observed_at: Utc::now(),
            })
            .await
            .map_err(|_| ())
    }
}

impl PostgresBackupStore {
    pub async fn connect(url: &str) -> Result<Self, BoxError> {
        let client = connect_and_initialize(url).await?;
        Ok(Self { client })
    }

    pub async fn upsert_active_session(
        &mut self,
        host: &HostIdentity,
        session: &ActiveSession,
        observed_at: DateTime<Utc>,
    ) -> Result<(), BoxError> {
        let row = session_row(host, Some(session), None, observed_at)?;
        upsert_session_row(&self.client, &row).await
    }

    pub async fn upsert_transcript(
        &mut self,
        host: &HostIdentity,
        active_session: Option<&ActiveSession>,
        transcript: &SessionMessagesResponse,
        observed_at: DateTime<Utc>,
    ) -> Result<usize, BoxError> {
        let row = session_row(host, active_session, Some(transcript), observed_at)?;
        let transaction = self.client.transaction().await?;
        upsert_session_row(&transaction, &row).await?;
        let inserted = upsert_message_rows(&transaction, host, transcript, observed_at).await?;
        transaction.commit().await?;
        Ok(inserted)
    }
}

async fn start(config: Config) -> Result<PostgresBackupHandle, BoxError> {
    let store = PostgresBackupStore::connect(&config.url).await?;
    let (sender, receiver) = mpsc::channel(BACKUP_QUEUE_CAPACITY);
    tokio::spawn(run_worker(config, receiver, store));
    info!(env = POSTGRES_BACKUP_URL_ENV, "postgres backup enabled");
    Ok(PostgresBackupHandle { sender })
}

async fn run_worker(
    config: Config,
    mut receiver: mpsc::Receiver<BackupEvent>,
    mut store: PostgresBackupStore,
) {
    let mut pending: Option<BackupEvent> = None;

    loop {
        let event = match pending.take() {
            Some(event) => event,
            None => match receiver.recv().await {
                Some(event) => event,
                None => break,
            },
        };

        match apply_event(&mut store, &event).await {
            Ok(()) => {}
            Err(error) => {
                warn!(%error, "postgres backup write failed");
                pending = Some(event);
                store = reconnect_loop(&config.url).await;
            }
        }
    }
}

async fn apply_event(store: &mut PostgresBackupStore, event: &BackupEvent) -> Result<(), BoxError> {
    match event {
        BackupEvent::SessionsSnapshot {
            host,
            sessions,
            observed_at,
        } => {
            for session in sessions {
                store
                    .upsert_active_session(host, session, *observed_at)
                    .await?;
            }
            Ok(())
        }
        BackupEvent::Transcript {
            host,
            active_session,
            transcript,
            observed_at,
        } => {
            store
                .upsert_transcript(host, active_session.as_ref(), transcript, *observed_at)
                .await?;
            Ok(())
        }
    }
}

async fn reconnect_loop(url: &str) -> PostgresBackupStore {
    loop {
        tokio::time::sleep(RECONNECT_DELAY).await;
        match PostgresBackupStore::connect(url).await {
            Ok(store) => return store,
            Err(error) => {
                warn!(
                    %error,
                    retry_after_seconds = RECONNECT_DELAY.as_secs(),
                    "failed to reconnect postgres backup"
                );
            }
        }
    }
}

async fn connect_and_initialize(url: &str) -> Result<Client, BoxError> {
    let (client, connection) = tokio_postgres::connect(url, NoTls).await?;
    tokio::spawn(async move {
        if let Err(error) = connection.await {
            warn!(%error, "postgres backup connection ended");
        }
    });
    client.batch_execute(SCHEMA_SQL).await?;
    Ok(client)
}

async fn upsert_session_row(client: &impl GenericClient, row: &SessionRow) -> Result<(), BoxError> {
    client
        .execute(
            "INSERT INTO sessions (host_location, session_id, host_auth, summary, created_at, updated_at, last_user_message_at, last_assistant_message_at, cwd, model, context_usage_used_tokens, context_usage_max_tokens, supports_images, transcript_freshness_state, transcript_freshness_source, transcript_freshness_as_of, activity_active, activity_attached, warnings_json, last_seen_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20) ON CONFLICT (host_location, session_id) DO UPDATE SET host_auth = EXCLUDED.host_auth, summary = COALESCE(EXCLUDED.summary, sessions.summary), created_at = COALESCE(EXCLUDED.created_at, sessions.created_at), updated_at = COALESCE(EXCLUDED.updated_at, sessions.updated_at), last_user_message_at = COALESCE(EXCLUDED.last_user_message_at, sessions.last_user_message_at), last_assistant_message_at = COALESCE(EXCLUDED.last_assistant_message_at, sessions.last_assistant_message_at), cwd = COALESCE(EXCLUDED.cwd, sessions.cwd), model = COALESCE(EXCLUDED.model, sessions.model), context_usage_used_tokens = COALESCE(EXCLUDED.context_usage_used_tokens, sessions.context_usage_used_tokens), context_usage_max_tokens = COALESCE(EXCLUDED.context_usage_max_tokens, sessions.context_usage_max_tokens), supports_images = COALESCE(EXCLUDED.supports_images, sessions.supports_images), transcript_freshness_state = COALESCE(EXCLUDED.transcript_freshness_state, sessions.transcript_freshness_state), transcript_freshness_source = COALESCE(EXCLUDED.transcript_freshness_source, sessions.transcript_freshness_source), transcript_freshness_as_of = COALESCE(EXCLUDED.transcript_freshness_as_of, sessions.transcript_freshness_as_of), activity_active = COALESCE(EXCLUDED.activity_active, sessions.activity_active), activity_attached = COALESCE(EXCLUDED.activity_attached, sessions.activity_attached), warnings_json = COALESCE(EXCLUDED.warnings_json, sessions.warnings_json), last_seen_at = GREATEST(sessions.last_seen_at, EXCLUDED.last_seen_at)",
            &[
                &row.host_location,
                &row.session_id,
                &row.host_auth,
                &row.summary,
                &row.created_at,
                &row.updated_at,
                &row.last_user_message_at,
                &row.last_assistant_message_at,
                &row.cwd,
                &row.model,
                &row.context_usage_used_tokens,
                &row.context_usage_max_tokens,
                &row.supports_images,
                &row.transcript_freshness_state,
                &row.transcript_freshness_source,
                &row.transcript_freshness_as_of,
                &row.activity_active,
                &row.activity_attached,
                &row.warnings_json,
                &row.last_seen_at,
            ],
        )
        .await?;
    Ok(())
}

async fn upsert_message_rows(
    client: &impl GenericClient,
    host: &HostIdentity,
    transcript: &SessionMessagesResponse,
    observed_at: DateTime<Utc>,
) -> Result<usize, BoxError> {
    let mut count = 0;
    for (ordinal, message) in transcript.messages.iter().enumerate() {
        let dedupe_key = message_dedupe_key(message)?;
        let message_json = serde_json::to_value(message)?;
        let ordinal = i32::try_from(ordinal).unwrap_or(i32::MAX);
        let role = role_name(message.role);

        client
            .execute(
                "INSERT INTO messages (host_location, session_id, dedupe_key, message_id, ordinal, created_at, role, body, tool_name, message_json, last_seen_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) ON CONFLICT (host_location, session_id, dedupe_key) DO UPDATE SET message_id = COALESCE(EXCLUDED.message_id, messages.message_id), ordinal = EXCLUDED.ordinal, created_at = EXCLUDED.created_at, role = EXCLUDED.role, body = EXCLUDED.body, tool_name = COALESCE(EXCLUDED.tool_name, messages.tool_name), message_json = EXCLUDED.message_json, last_seen_at = GREATEST(messages.last_seen_at, EXCLUDED.last_seen_at)",
                &[
                    &host.location,
                    &transcript.session_id,
                    &dedupe_key,
                    &message.message_id,
                    &ordinal,
                    &message.created_at,
                    &role,
                    &message.body,
                    &message.tool_name,
                    &message_json,
                    &observed_at,
                ],
            )
            .await?;
        count += 1;
    }

    Ok(count)
}

fn postgres_url_from_env() -> Option<String> {
    env::var(POSTGRES_BACKUP_URL_ENV)
        .ok()
        .filter(|value| !value.trim().is_empty())
}

fn session_row(
    host: &HostIdentity,
    active_session: Option<&ActiveSession>,
    transcript: Option<&SessionMessagesResponse>,
    observed_at: DateTime<Utc>,
) -> Result<SessionRow, BoxError> {
    let active_session = match (active_session, transcript) {
        (Some(session), Some(transcript)) if session.id != transcript.session_id => None,
        _ => active_session,
    };

    let session_id = transcript
        .map(|transcript| transcript.session_id.clone())
        .or_else(|| active_session.map(|session| session.id.clone()))
        .ok_or_else(|| "session row requires active session or transcript".to_string())?;

    let warnings_json = transcript
        .map(|transcript| serde_json::to_value(&transcript.warnings))
        .transpose()?;

    Ok(SessionRow {
        host_location: host.location.clone(),
        session_id,
        host_auth: host_auth_name(host.auth).to_string(),
        summary: active_session.map(|session| session.summary.clone()),
        created_at: active_session.map(|session| session.created_at),
        updated_at: active_session.map(|session| session.updated_at),
        last_user_message_at: active_session.map(|session| session.last_user_message_at),
        last_assistant_message_at: active_session.map(|session| session.last_assistant_message_at),
        cwd: active_session.map(|session| session.cwd.clone()),
        model: active_session.map(|session| session.model.clone()),
        context_usage_used_tokens: active_session.and_then(|session| {
            session
                .context_usage
                .as_ref()
                .and_then(|usage| usage.used_tokens)
                .map(saturating_u64_to_i64)
        }),
        context_usage_max_tokens: active_session.and_then(|session| {
            session
                .context_usage
                .as_ref()
                .and_then(|usage| usage.max_tokens)
                .map(saturating_u64_to_i64)
        }),
        supports_images: active_session.and_then(|session| session.supports_images),
        transcript_freshness_state: transcript
            .map(|transcript| freshness_state_name(transcript.freshness.state).to_string()),
        transcript_freshness_source: transcript
            .map(|transcript| freshness_source_name(transcript.freshness.source).to_string()),
        transcript_freshness_as_of: transcript.map(|transcript| transcript.freshness.as_of),
        activity_active: transcript.map(|transcript| transcript.activity.active),
        activity_attached: transcript.map(|transcript| transcript.activity.attached),
        warnings_json,
        last_seen_at: observed_at,
    })
}

fn host_auth_name(auth: HostAuth) -> &'static str {
    match auth {
        HostAuth::None => "none",
        HostAuth::Pk => "pk",
    }
}

fn freshness_state_name(state: TranscriptFreshnessState) -> &'static str {
    match state {
        TranscriptFreshnessState::Live => "live",
        TranscriptFreshnessState::Persisted => "persisted",
        TranscriptFreshnessState::LiveUnknown => "liveUnknown",
    }
}

fn freshness_source_name(source: TranscriptSource) -> &'static str {
    match source {
        TranscriptSource::Extension => "extension",
        TranscriptSource::Helper => "helper",
        TranscriptSource::File => "file",
    }
}

fn role_name(role: Role) -> &'static str {
    match role {
        Role::User => "user",
        Role::Assistant => "assistant",
        Role::ToolResult => "toolResult",
        Role::BashExecution => "bashExecution",
        Role::Custom => "custom",
        Role::BranchSummary => "branchSummary",
        Role::CompactionSummary => "compactionSummary",
        Role::Other => "other",
    }
}

fn saturating_u64_to_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn message_dedupe_key(message: &Message) -> Result<String, BoxError> {
    if let Some(message_id) = message.message_id.as_deref()
        && !message_id.is_empty()
    {
        return Ok(format!("id:{message_id}"));
    }

    let fingerprint = serde_json::to_string(message)?;
    Ok(format!("fnv1a64:{:016x}", fnv1a64(fingerprint.as_bytes())))
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    const FNV_OFFSET: u64 = 0xcbf29ce484222325;
    const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

    let mut hash = FNV_OFFSET;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    hash
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;

    use crate::{message::MessageContentBlock, transcript::SessionActivity};

    use super::*;

    #[test]
    fn message_dedupe_key_prefers_message_id() {
        let mut message =
            Message::from_text(Utc.timestamp_opt(1_000, 0).unwrap(), Role::User, "hi").unwrap();
        message.message_id = Some("entry-123".to_string());

        assert_eq!(message_dedupe_key(&message).unwrap(), "id:entry-123");
    }

    #[test]
    fn message_dedupe_key_is_stable_without_message_id() {
        let message = Message::from_blocks(
            Utc.timestamp_opt(1_000, 0).unwrap(),
            Role::Assistant,
            vec![MessageContentBlock::text("hello").unwrap()],
        )
        .unwrap();

        let first = message_dedupe_key(&message).unwrap();
        let second = message_dedupe_key(&message).unwrap();
        assert_eq!(first, second);
    }

    #[test]
    fn session_row_includes_transcript_metadata() {
        let host = HostIdentity {
            location: "dev@mac".to_string(),
            auth: HostAuth::None,
        };
        let transcript = SessionMessagesResponse {
            session_id: "session-1".to_string(),
            messages: vec![
                Message::from_text(Utc.timestamp_opt(1_000, 0).unwrap(), Role::User, "hi").unwrap(),
            ],
            freshness: crate::transcript::TranscriptFreshness {
                state: TranscriptFreshnessState::Live,
                source: TranscriptSource::Extension,
                as_of: Utc.timestamp_opt(2_000, 0).unwrap(),
            },
            activity: SessionActivity {
                active: true,
                attached: false,
            },
            warnings: vec!["warn".to_string()],
        };

        let row = session_row(
            &host,
            None,
            Some(&transcript),
            Utc.timestamp_opt(3_000, 0).unwrap(),
        )
        .unwrap();

        assert_eq!(row.session_id, "session-1");
        assert_eq!(row.transcript_freshness_state.as_deref(), Some("live"));
        assert_eq!(row.activity_active, Some(true));
        assert!(row.warnings_json.is_some());
    }
}

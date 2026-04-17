use std::{env, time::Duration};

use chrono::{DateTime, Utc};
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_postgres::{Client, GenericClient, NoTls};
use tracing::{info, warn};

use crate::{
    host::{HostAuth, HostIdentity},
    message::{Message, MessageContentBlockKind, Role},
    session::{ActiveSession, SessionContextUsage},
    transcript::{
        SessionActivity, SessionMessagesResponse, TranscriptFreshness, TranscriptFreshnessState,
        TranscriptSource,
    },
};

use super::BoxError;

pub const POSTGRES_BACKUP_URL_ENV: &str = "PIMUX_BACKUP_POSTGRES_URL";
const BACKUP_QUEUE_CAPACITY: usize = 256;
const RECONNECT_DELAY: Duration = Duration::from_secs(2);
const TRANSCRIPT_SCHEMA_VERSION_V2: i16 = 2;
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
    transcript_schema_version SMALLINT NOT NULL DEFAULT 1,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (host_location, session_id)
);
ALTER TABLE sessions
    ADD COLUMN IF NOT EXISTS transcript_schema_version SMALLINT NOT NULL DEFAULT 1;
CREATE INDEX IF NOT EXISTS sessions_updated_at_idx
    ON sessions (updated_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS sessions_last_seen_at_idx
    ON sessions (last_seen_at DESC);
CREATE INDEX IF NOT EXISTS sessions_session_id_idx
    ON sessions (session_id);

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
    tool_call_id TEXT,
    message_json JSONB NOT NULL,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (host_location, session_id, dedupe_key),
    FOREIGN KEY (host_location, session_id)
        REFERENCES sessions (host_location, session_id)
        ON DELETE CASCADE
);
ALTER TABLE messages
    ADD COLUMN IF NOT EXISTS tool_call_id TEXT;
CREATE INDEX IF NOT EXISTS messages_session_created_at_idx
    ON messages (host_location, session_id, created_at, ordinal);
CREATE INDEX IF NOT EXISTS messages_message_id_idx
    ON messages (message_id)
    WHERE message_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS messages_tool_call_id_idx
    ON messages (tool_call_id)
    WHERE tool_call_id IS NOT NULL;
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
    transcript_schema_version: i16,
    last_seen_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct ArchivedSession {
    pub host_location: String,
    pub session_id: String,
    pub host_auth: HostAuth,
    pub summary: Option<String>,
    pub created_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
    pub last_user_message_at: Option<DateTime<Utc>>,
    pub last_assistant_message_at: Option<DateTime<Utc>>,
    pub cwd: Option<String>,
    pub model: Option<String>,
    pub context_usage: Option<SessionContextUsage>,
    pub supports_images: Option<bool>,
    pub transcript_freshness: Option<TranscriptFreshness>,
    pub activity: Option<SessionActivity>,
    pub warnings: Vec<String>,
    pub last_seen_at: DateTime<Utc>,
}

impl ArchivedSession {
    pub fn active_session(&self) -> Option<ActiveSession> {
        Some(ActiveSession {
            id: self.session_id.clone(),
            summary: self.summary.clone()?,
            created_at: self.created_at?,
            updated_at: self.updated_at?,
            last_user_message_at: self.last_user_message_at?,
            last_assistant_message_at: self.last_assistant_message_at?,
            cwd: self.cwd.clone()?,
            model: self.model.clone()?,
            context_usage: self.context_usage.clone(),
            supports_images: self.supports_images,
        })
    }

    pub fn transcript_response(&self, messages: Vec<Message>) -> SessionMessagesResponse {
        SessionMessagesResponse {
            session_id: self.session_id.clone(),
            messages,
            freshness: self
                .transcript_freshness
                .clone()
                .unwrap_or(TranscriptFreshness {
                    state: TranscriptFreshnessState::Persisted,
                    source: TranscriptSource::File,
                    as_of: self.last_seen_at,
                }),
            activity: self.activity.clone().unwrap_or(SessionActivity {
                active: false,
                attached: false,
            }),
            warnings: self.warnings.clone(),
        }
    }
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

pub async fn connect_read_client_from_env_required() -> Result<Client, BoxError> {
    let Some(url) = postgres_url_from_env() else {
        return Err(format!("{POSTGRES_BACKUP_URL_ENV} is not set").into());
    };

    connect_read_client(&url).await
}

pub async fn load_sessions(client: &Client) -> Result<Vec<ArchivedSession>, BoxError> {
    let rows = client
        .query(
            concat!(
                "SELECT host_location, session_id, host_auth, summary, created_at, updated_at, ",
                "last_user_message_at, last_assistant_message_at, cwd, model, ",
                "context_usage_used_tokens, context_usage_max_tokens, supports_images, ",
                "transcript_freshness_state, transcript_freshness_source, transcript_freshness_as_of, ",
                "activity_active, activity_attached, warnings_json, last_seen_at ",
                "FROM sessions ",
                "ORDER BY COALESCE(updated_at, last_seen_at) DESC, host_location ASC, session_id ASC"
            ),
            &[],
        )
        .await?;

    Ok(rows.into_iter().map(map_archived_session_row).collect())
}

pub async fn load_session(
    client: &Client,
    host_location: &str,
    session_id: &str,
) -> Result<Option<ArchivedSession>, BoxError> {
    let row = client
        .query_opt(
            concat!(
                "SELECT host_location, session_id, host_auth, summary, created_at, updated_at, ",
                "last_user_message_at, last_assistant_message_at, cwd, model, ",
                "context_usage_used_tokens, context_usage_max_tokens, supports_images, ",
                "transcript_freshness_state, transcript_freshness_source, transcript_freshness_as_of, ",
                "activity_active, activity_attached, warnings_json, last_seen_at ",
                "FROM sessions ",
                "WHERE host_location = $1 AND session_id = $2"
            ),
            &[&host_location, &session_id],
        )
        .await?;

    Ok(row.map(map_archived_session_row))
}

pub async fn load_sessions_by_session_id(
    client: &Client,
    session_id: &str,
) -> Result<Vec<ArchivedSession>, BoxError> {
    let rows = client
        .query(
            concat!(
                "SELECT host_location, session_id, host_auth, summary, created_at, updated_at, ",
                "last_user_message_at, last_assistant_message_at, cwd, model, ",
                "context_usage_used_tokens, context_usage_max_tokens, supports_images, ",
                "transcript_freshness_state, transcript_freshness_source, transcript_freshness_as_of, ",
                "activity_active, activity_attached, warnings_json, last_seen_at ",
                "FROM sessions ",
                "WHERE session_id = $1 ",
                "ORDER BY COALESCE(updated_at, last_seen_at) DESC, host_location ASC"
            ),
            &[&session_id],
        )
        .await?;

    Ok(rows.into_iter().map(map_archived_session_row).collect())
}

pub async fn load_messages(
    client: &Client,
    host_location: &str,
    session_id: &str,
) -> Result<Vec<Message>, BoxError> {
    let rows = client
        .query(
            concat!(
                "SELECT message_id, created_at, role, body, tool_name, tool_call_id, message_json ",
                "FROM messages ",
                "WHERE host_location = $1 AND session_id = $2 ",
                "ORDER BY created_at ASC, ordinal ASC"
            ),
            &[&host_location, &session_id],
        )
        .await?;

    Ok(rows.into_iter().map(map_archived_message_row).collect())
}

pub async fn load_transcript(
    client: &Client,
    host_location: &str,
    session_id: &str,
) -> Result<Option<SessionMessagesResponse>, BoxError> {
    let Some(session) = load_session(client, host_location, session_id).await? else {
        return Ok(None);
    };

    let messages = load_messages(client, host_location, session_id).await?;
    Ok(Some(session.transcript_response(messages)))
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

    pub async fn replace_transcript(
        &mut self,
        host: &HostIdentity,
        active_session: Option<&ActiveSession>,
        transcript: &SessionMessagesResponse,
        observed_at: DateTime<Utc>,
    ) -> Result<usize, BoxError> {
        let row = session_row(host, active_session, Some(transcript), observed_at)?;
        let transaction = self.client.transaction().await?;
        upsert_session_row(&transaction, &row).await?;
        delete_message_rows(&transaction, &row.host_location, &row.session_id).await?;
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

async fn connect_read_client(url: &str) -> Result<Client, BoxError> {
    let (client, connection) = tokio_postgres::connect(url, NoTls).await?;
    tokio::spawn(async move {
        if let Err(error) = connection.await {
            warn!(%error, "postgres read connection ended");
        }
    });
    Ok(client)
}

fn map_archived_session_row(row: tokio_postgres::Row) -> ArchivedSession {
    let host_location = row.get("host_location");
    let session_id = row.get("session_id");
    let last_seen_at = row.get("last_seen_at");
    let context_usage_used_tokens = row
        .get::<_, Option<i64>>("context_usage_used_tokens")
        .and_then(nonnegative_i64_to_u64);
    let context_usage_max_tokens = row
        .get::<_, Option<i64>>("context_usage_max_tokens")
        .and_then(nonnegative_i64_to_u64);
    let transcript_freshness_state = row.get::<_, Option<String>>("transcript_freshness_state");
    let transcript_freshness_source = row.get::<_, Option<String>>("transcript_freshness_source");
    let transcript_freshness_as_of: Option<DateTime<Utc>> = row.get("transcript_freshness_as_of");
    let activity_active: Option<bool> = row.get("activity_active");
    let activity_attached: Option<bool> = row.get("activity_attached");
    let warnings = row
        .get::<_, Option<Value>>("warnings_json")
        .and_then(|value| serde_json::from_value::<Vec<String>>(value).ok())
        .unwrap_or_default();

    ArchivedSession {
        host_location,
        session_id,
        host_auth: host_auth_from_raw(&row.get::<_, String>("host_auth")),
        summary: row.get("summary"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
        last_user_message_at: row.get("last_user_message_at"),
        last_assistant_message_at: row.get("last_assistant_message_at"),
        cwd: row.get("cwd"),
        model: row.get("model"),
        context_usage: if context_usage_used_tokens.is_some() || context_usage_max_tokens.is_some()
        {
            Some(SessionContextUsage {
                used_tokens: context_usage_used_tokens,
                max_tokens: context_usage_max_tokens,
            })
        } else {
            None
        },
        supports_images: row.get("supports_images"),
        transcript_freshness: match (
            transcript_freshness_state
                .as_deref()
                .and_then(transcript_freshness_state_from_raw),
            transcript_freshness_source
                .as_deref()
                .and_then(transcript_freshness_source_from_raw),
        ) {
            (Some(state), Some(source)) => Some(TranscriptFreshness {
                state,
                source,
                as_of: transcript_freshness_as_of.unwrap_or(last_seen_at),
            }),
            _ => None,
        },
        activity: if activity_active.is_some() || activity_attached.is_some() {
            Some(SessionActivity {
                active: activity_active.unwrap_or(false),
                attached: activity_attached.unwrap_or(false),
            })
        } else {
            None
        },
        warnings,
        last_seen_at,
    }
}

fn map_archived_message_row(row: tokio_postgres::Row) -> Message {
    let message_json = row.get::<_, Value>("message_json");
    match serde_json::from_value::<Message>(message_json) {
        Ok(message) => message,
        Err(_) => Message {
            created_at: row.get("created_at"),
            role: Role::from_raw(&row.get::<_, String>("role")),
            body: row.get("body"),
            tool_name: row.get("tool_name"),
            tool_call_id: row.get("tool_call_id"),
            blocks: Vec::new(),
            message_id: row.get("message_id"),
        },
    }
}

async fn upsert_session_row(client: &impl GenericClient, row: &SessionRow) -> Result<(), BoxError> {
    client
        .execute(
            "INSERT INTO sessions (host_location, session_id, host_auth, summary, created_at, updated_at, last_user_message_at, last_assistant_message_at, cwd, model, context_usage_used_tokens, context_usage_max_tokens, supports_images, transcript_freshness_state, transcript_freshness_source, transcript_freshness_as_of, activity_active, activity_attached, warnings_json, transcript_schema_version, last_seen_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21) ON CONFLICT (host_location, session_id) DO UPDATE SET host_auth = EXCLUDED.host_auth, summary = COALESCE(EXCLUDED.summary, sessions.summary), created_at = COALESCE(EXCLUDED.created_at, sessions.created_at), updated_at = COALESCE(EXCLUDED.updated_at, sessions.updated_at), last_user_message_at = COALESCE(EXCLUDED.last_user_message_at, sessions.last_user_message_at), last_assistant_message_at = COALESCE(EXCLUDED.last_assistant_message_at, sessions.last_assistant_message_at), cwd = COALESCE(EXCLUDED.cwd, sessions.cwd), model = COALESCE(EXCLUDED.model, sessions.model), context_usage_used_tokens = COALESCE(EXCLUDED.context_usage_used_tokens, sessions.context_usage_used_tokens), context_usage_max_tokens = COALESCE(EXCLUDED.context_usage_max_tokens, sessions.context_usage_max_tokens), supports_images = COALESCE(EXCLUDED.supports_images, sessions.supports_images), transcript_freshness_state = COALESCE(EXCLUDED.transcript_freshness_state, sessions.transcript_freshness_state), transcript_freshness_source = COALESCE(EXCLUDED.transcript_freshness_source, sessions.transcript_freshness_source), transcript_freshness_as_of = COALESCE(EXCLUDED.transcript_freshness_as_of, sessions.transcript_freshness_as_of), activity_active = COALESCE(EXCLUDED.activity_active, sessions.activity_active), activity_attached = COALESCE(EXCLUDED.activity_attached, sessions.activity_attached), warnings_json = COALESCE(EXCLUDED.warnings_json, sessions.warnings_json), transcript_schema_version = GREATEST(sessions.transcript_schema_version, EXCLUDED.transcript_schema_version), last_seen_at = GREATEST(sessions.last_seen_at, EXCLUDED.last_seen_at)",
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
                &row.transcript_schema_version,
                &row.last_seen_at,
            ],
        )
        .await?;
    Ok(())
}

async fn delete_message_rows(
    client: &impl GenericClient,
    host_location: &str,
    session_id: &str,
) -> Result<(), BoxError> {
    client
        .execute(
            "DELETE FROM messages WHERE host_location = $1 AND session_id = $2",
            &[&host_location, &session_id],
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
    let host_location = sanitize_postgres_text(&host.location);
    let session_id = sanitize_postgres_text(&transcript.session_id);
    for (ordinal, message) in transcript.messages.iter().enumerate() {
        let dedupe_key = sanitize_postgres_text(&message_dedupe_key(message)?);
        let message_id = sanitize_option_postgres_text(message.message_id.clone());
        let body = sanitize_postgres_text(&message.body);
        let tool_name = sanitize_option_postgres_text(message.tool_name.clone());
        let tool_call_id = sanitize_option_postgres_text(message.tool_call_id.clone());
        let message_json = sanitize_json_value(serde_json::to_value(message)?);
        let ordinal = i32::try_from(ordinal).unwrap_or(i32::MAX);
        let role = sanitize_postgres_text(message.role.raw_value());

        client
            .execute(
                "INSERT INTO messages (host_location, session_id, dedupe_key, message_id, ordinal, created_at, role, body, tool_name, tool_call_id, message_json, last_seen_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12) ON CONFLICT (host_location, session_id, dedupe_key) DO UPDATE SET message_id = COALESCE(EXCLUDED.message_id, messages.message_id), ordinal = EXCLUDED.ordinal, created_at = EXCLUDED.created_at, role = EXCLUDED.role, body = EXCLUDED.body, tool_name = COALESCE(EXCLUDED.tool_name, messages.tool_name), tool_call_id = COALESCE(EXCLUDED.tool_call_id, messages.tool_call_id), message_json = EXCLUDED.message_json, last_seen_at = GREATEST(messages.last_seen_at, EXCLUDED.last_seen_at)",
                &[
                    &host_location,
                    &session_id,
                    &dedupe_key,
                    &message_id,
                    &ordinal,
                    &message.created_at,
                    &role,
                    &body,
                    &tool_name,
                    &tool_call_id,
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
        .map(|transcript| serde_json::to_value(&transcript.warnings).map(sanitize_json_value))
        .transpose()?;

    Ok(SessionRow {
        host_location: sanitize_postgres_text(&host.location),
        session_id: sanitize_postgres_text(&session_id),
        host_auth: sanitize_postgres_text(host_auth_name(host.auth)),
        summary: active_session.map(|session| sanitize_postgres_text(&session.summary)),
        created_at: active_session.map(|session| session.created_at),
        updated_at: active_session.map(|session| session.updated_at),
        last_user_message_at: active_session.map(|session| session.last_user_message_at),
        last_assistant_message_at: active_session.map(|session| session.last_assistant_message_at),
        cwd: active_session.map(|session| sanitize_postgres_text(&session.cwd)),
        model: active_session.map(|session| sanitize_postgres_text(&session.model)),
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
        transcript_freshness_state: transcript.map(|transcript| {
            sanitize_postgres_text(freshness_state_name(transcript.freshness.state))
        }),
        transcript_freshness_source: transcript.map(|transcript| {
            sanitize_postgres_text(freshness_source_name(transcript.freshness.source))
        }),
        transcript_freshness_as_of: transcript.map(|transcript| transcript.freshness.as_of),
        activity_active: transcript.map(|transcript| transcript.activity.active),
        activity_attached: transcript.map(|transcript| transcript.activity.attached),
        warnings_json,
        transcript_schema_version: if transcript.is_some() {
            TRANSCRIPT_SCHEMA_VERSION_V2
        } else {
            1
        },
        last_seen_at: observed_at,
    })
}

fn host_auth_name(auth: HostAuth) -> &'static str {
    match auth {
        HostAuth::None => "none",
        HostAuth::Pk => "pk",
    }
}

fn host_auth_from_raw(value: &str) -> HostAuth {
    match value {
        "pk" => HostAuth::Pk,
        _ => HostAuth::None,
    }
}

fn transcript_freshness_state_from_raw(value: &str) -> Option<TranscriptFreshnessState> {
    match value {
        "live" => Some(TranscriptFreshnessState::Live),
        "persisted" => Some(TranscriptFreshnessState::Persisted),
        "liveUnknown" => Some(TranscriptFreshnessState::LiveUnknown),
        _ => None,
    }
}

fn transcript_freshness_source_from_raw(value: &str) -> Option<TranscriptSource> {
    match value {
        "extension" => Some(TranscriptSource::Extension),
        "helper" => Some(TranscriptSource::Helper),
        "file" => Some(TranscriptSource::File),
        _ => None,
    }
}

fn nonnegative_i64_to_u64(value: i64) -> Option<u64> {
    u64::try_from(value).ok()
}

fn sanitize_postgres_text(value: &str) -> String {
    if value.contains('\0') {
        value.replace('\0', r"\u0000")
    } else {
        value.to_string()
    }
}

fn sanitize_option_postgres_text(value: Option<String>) -> Option<String> {
    value.map(|value| sanitize_postgres_text(&value))
}

fn sanitize_json_value(value: Value) -> Value {
    match value {
        Value::Null | Value::Bool(_) | Value::Number(_) => value,
        Value::String(value) => Value::String(sanitize_postgres_text(&value)),
        Value::Array(values) => Value::Array(values.into_iter().map(sanitize_json_value).collect()),
        Value::Object(entries) => Value::Object(
            entries
                .into_iter()
                .map(|(key, value)| (sanitize_postgres_text(&key), sanitize_json_value(value)))
                .collect(),
        ),
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

fn saturating_u64_to_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn message_dedupe_key(message: &Message) -> Result<String, BoxError> {
    if let Some(message_id) = message.message_id.as_deref()
        && !message_id.is_empty()
    {
        return Ok(format!("id:{message_id}"));
    }

    #[derive(serde::Serialize)]
    #[serde(rename_all = "camelCase")]
    struct LegacyBlockFingerprint<'a> {
        #[serde(rename = "type")]
        kind: MessageContentBlockKind,
        #[serde(skip_serializing_if = "Option::is_none")]
        text: Option<&'a str>,
        #[serde(skip_serializing_if = "Option::is_none")]
        tool_call_name: Option<&'a str>,
        #[serde(skip_serializing_if = "Option::is_none")]
        mime_type: Option<&'a str>,
        #[serde(skip_serializing_if = "Option::is_none")]
        data: Option<&'a str>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        attachment_id: Option<&'a str>,
    }

    #[derive(serde::Serialize)]
    struct LegacyMessageFingerprint<'a> {
        created_at: DateTime<Utc>,
        role: &'a str,
        body: &'a str,
        #[serde(skip_serializing_if = "Option::is_none")]
        tool_name: Option<&'a str>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        blocks: Vec<LegacyBlockFingerprint<'a>>,
        #[serde(default, skip_serializing_if = "Option::is_none", rename = "messageId")]
        message_id: Option<&'a str>,
    }

    let fingerprint = LegacyMessageFingerprint {
        created_at: message.created_at,
        role: message.role.dedupe_value(),
        body: &message.body,
        tool_name: message.tool_name.as_deref(),
        blocks: message
            .blocks
            .iter()
            .map(|block| LegacyBlockFingerprint {
                kind: block.kind,
                text: block.text.as_deref(),
                tool_call_name: block.tool_call_name.as_deref(),
                mime_type: block.mime_type.as_deref(),
                data: block.data.as_deref(),
                attachment_id: block.attachment_id.as_deref(),
            })
            .collect(),
        message_id: message.message_id.as_deref(),
    };

    let fingerprint = serde_json::to_string(&fingerprint)?;
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
    fn message_dedupe_key_ignores_new_tool_call_linkage_fields() {
        let mut message = Message::from_blocks(
            Utc.timestamp_opt(1_000, 0).unwrap(),
            Role::Assistant,
            vec![
                MessageContentBlock::tool_call_with_id(Some("call-123"), "read", Some("foo.txt"))
                    .unwrap(),
            ],
        )
        .unwrap();
        let baseline = message_dedupe_key(&message).unwrap();

        message.tool_call_id = Some("result-call-123".to_string());
        message.blocks[0].tool_call_id = Some("call-999".to_string());

        assert_eq!(message_dedupe_key(&message).unwrap(), baseline);
    }

    #[test]
    fn sanitize_postgres_text_replaces_nul() {
        assert_eq!(sanitize_postgres_text("a\0b"), "a\\u0000b");
    }

    #[test]
    fn sanitize_json_value_replaces_nul_recursively() {
        let value = serde_json::json!({
            "a\0b": ["x\0y", { "nested": "z\0w" }]
        });

        let sanitized = sanitize_json_value(value);
        assert_eq!(sanitized["a\\u0000b"][0], "x\\u0000y");
        assert_eq!(sanitized["a\\u0000b"][1]["nested"], "z\\u0000w");
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
        assert_eq!(row.transcript_schema_version, TRANSCRIPT_SCHEMA_VERSION_V2);
        assert!(row.warnings_json.is_some());
    }

    #[test]
    fn session_row_sanitizes_nul_bytes() {
        let host = HostIdentity {
            location: "dev@mac\0bad".to_string(),
            auth: HostAuth::None,
        };
        let session = ActiveSession {
            id: "session\0-1".to_string(),
            summary: "sum\0mary".to_string(),
            created_at: Utc.timestamp_opt(1_000, 0).unwrap(),
            updated_at: Utc.timestamp_opt(1_000, 0).unwrap(),
            last_user_message_at: Utc.timestamp_opt(1_000, 0).unwrap(),
            last_assistant_message_at: Utc.timestamp_opt(1_000, 0).unwrap(),
            cwd: "/tmp/\0project".to_string(),
            model: "claude\0model".to_string(),
            context_usage: None,
            supports_images: None,
        };

        let row = session_row(
            &host,
            Some(&session),
            None,
            Utc.timestamp_opt(3_000, 0).unwrap(),
        )
        .unwrap();

        assert_eq!(row.host_location, "dev@mac\\u0000bad");
        assert_eq!(row.session_id, "session\\u0000-1");
        assert_eq!(row.summary.as_deref(), Some("sum\\u0000mary"));
        assert_eq!(row.cwd.as_deref(), Some("/tmp/\\u0000project"));
        assert_eq!(row.model.as_deref(), Some("claude\\u0000model"));
    }
}

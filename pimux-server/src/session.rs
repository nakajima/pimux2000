use chrono::{DateTime, Days, Local, LocalResult, NaiveDate, TimeZone, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionContextUsage {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub used_tokens: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActiveSession {
    pub id: String,
    pub summary: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub last_user_message_at: DateTime<Utc>,
    pub last_assistant_message_at: DateTime<Utc>,
    pub cwd: String,
    pub model: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_usage: Option<SessionContextUsage>,
}

impl ActiveSession {
    pub fn last_activity_at(&self) -> DateTime<Utc> {
        self.last_user_message_at
            .max(self.last_assistant_message_at)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListedSession {
    pub host_location: String,
    pub host_connected: bool,
    pub host_missing: bool,
    pub host_last_seen_at: Option<DateTime<Utc>>,
    #[serde(flatten)]
    pub session: ActiveSession,
}

impl ListedSession {
    pub fn new(
        host_location: String,
        host_connected: bool,
        host_missing: bool,
        host_last_seen_at: Option<DateTime<Utc>>,
        session: ActiveSession,
    ) -> Self {
        Self {
            host_location,
            host_connected,
            host_missing,
            host_last_seen_at,
            session,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionCommand {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    pub source: String,
}

pub fn parse_local_date_filter(value: &str) -> Result<NaiveDate, String> {
    NaiveDate::parse_from_str(value, "%Y-%m-%d")
        .map_err(|_| format!("invalid date `{value}`; expected YYYY-MM-DD"))
}

pub fn utc_range_for_local_date(date: NaiveDate) -> Result<(DateTime<Utc>, DateTime<Utc>), String> {
    let start = local_midnight(date)?;
    let next_day = date
        .checked_add_days(Days::new(1))
        .ok_or_else(|| format!("date `{date}` is out of supported range"))?;
    let end = local_midnight(next_day)?;
    Ok((start.with_timezone(&Utc), end.with_timezone(&Utc)))
}

fn local_midnight(date: NaiveDate) -> Result<DateTime<Local>, String> {
    let naive = date
        .and_hms_opt(0, 0, 0)
        .ok_or_else(|| format!("date `{date}` is out of supported range"))?;

    match Local.from_local_datetime(&naive) {
        LocalResult::Single(value) => Ok(value),
        LocalResult::Ambiguous(first, _) => Ok(first),
        LocalResult::None => Err(format!(
            "local midnight for `{date}` is not representable in the system timezone"
        )),
    }
}

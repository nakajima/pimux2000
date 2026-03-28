use std::{
    fmt, fs,
    path::{Path, PathBuf},
};

use super::discovery::resolve_pi_agent_dir;

type BoxError = Box<dyn std::error::Error + Send + Sync>;
const LIVE_EXTENSION_SOURCE: &str = include_str!("../../extensions/pimux-live.ts");

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncStatus {
    Installed,
    Updated,
    AlreadyCurrent,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncResult {
    pub path: PathBuf,
    pub status: SyncStatus,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileStatus {
    Missing,
    Stale,
    Current,
}

impl fmt::Display for FileStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Missing => write!(f, "missing"),
            Self::Stale => write!(f, "stale"),
            Self::Current => write!(f, "current"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub path: PathBuf,
    pub state: FileStatus,
}

pub fn path(pi_agent_dir: Option<PathBuf>) -> Result<PathBuf, BoxError> {
    let pi_agent_dir = resolve_pi_agent_dir(pi_agent_dir)?;
    Ok(path_from_root(&pi_agent_dir))
}

pub fn status(pi_agent_dir: Option<PathBuf>) -> Result<Status, BoxError> {
    let pi_agent_dir = resolve_pi_agent_dir(pi_agent_dir)?;
    let path = path_from_root(&pi_agent_dir);
    let state = match fs::read_to_string(&path) {
        Ok(contents) if contents == LIVE_EXTENSION_SOURCE => FileStatus::Current,
        Ok(_) => FileStatus::Stale,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => FileStatus::Missing,
        Err(error) => return Err(error.into()),
    };

    Ok(Status { path, state })
}

pub fn install(pi_agent_dir: Option<PathBuf>, force: bool) -> Result<PathBuf, BoxError> {
    let extension_path = path(pi_agent_dir)?;

    if let Some(parent) = extension_path.parent() {
        fs::create_dir_all(parent)?;
    }

    if extension_path.exists() {
        let existing = fs::read_to_string(&extension_path)?;
        if existing == LIVE_EXTENSION_SOURCE {
            return Ok(extension_path);
        }

        if !force {
            return Err(format!(
                "{} already exists with different contents; rerun with --force to overwrite",
                extension_path.display()
            )
            .into());
        }
    }

    fs::write(&extension_path, LIVE_EXTENSION_SOURCE)?;
    Ok(extension_path)
}

pub fn ensure_current(pi_agent_dir: &Path) -> Result<SyncResult, BoxError> {
    let extension_path = path_from_root(pi_agent_dir);

    if let Some(parent) = extension_path.parent() {
        fs::create_dir_all(parent)?;
    }

    let status = match fs::read_to_string(&extension_path) {
        Ok(existing) if existing == LIVE_EXTENSION_SOURCE => SyncStatus::AlreadyCurrent,
        Ok(_) => {
            fs::write(&extension_path, LIVE_EXTENSION_SOURCE)?;
            SyncStatus::Updated
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::write(&extension_path, LIVE_EXTENSION_SOURCE)?;
            SyncStatus::Installed
        }
        Err(error) => return Err(error.into()),
    };

    Ok(SyncResult {
        path: extension_path,
        status,
    })
}

fn path_from_root(pi_agent_dir: &Path) -> PathBuf {
    pi_agent_dir.join("extensions").join("pimux-live.ts")
}

#[cfg(test)]
mod tests {
    use super::{FileStatus, SyncStatus, ensure_current, install, status};
    use std::{fs, path::PathBuf};

    fn temp_root(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "pimux-extension-test-{name}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn ensure_current_installs_when_missing_then_reports_current() {
        let root = temp_root("missing");
        let result = ensure_current(&root).unwrap();
        assert_eq!(result.status, SyncStatus::Installed);

        let status = status(Some(root.clone())).unwrap();
        assert_eq!(status.state, FileStatus::Current);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn ensure_current_updates_stale_file() {
        let root = temp_root("stale");
        let extension_path = root.join("extensions").join("pimux-live.ts");
        fs::create_dir_all(extension_path.parent().unwrap()).unwrap();
        fs::write(&extension_path, "stale").unwrap();

        let result = ensure_current(&root).unwrap();
        assert_eq!(result.status, SyncStatus::Updated);

        let status = status(Some(root.clone())).unwrap();
        assert_eq!(status.state, FileStatus::Current);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn install_without_force_rejects_stale_file() {
        let root = temp_root("manual-stale");
        let extension_path = root.join("extensions").join("pimux-live.ts");
        fs::create_dir_all(extension_path.parent().unwrap()).unwrap();
        fs::write(&extension_path, "stale").unwrap();

        let error = install(Some(root.clone()), false).unwrap_err();
        assert!(error.to_string().contains("rerun with --force"));

        let status = status(Some(root.clone())).unwrap();
        assert_eq!(status.state, FileStatus::Stale);

        let _ = fs::remove_dir_all(root);
    }
}

use std::{fs, path::PathBuf};

use super::discovery::resolve_pi_agent_dir;

type BoxError = Box<dyn std::error::Error + Send + Sync>;
const LIVE_EXTENSION_SOURCE: &str = include_str!("../../extensions/pimux-live.ts");

pub fn install(pi_agent_dir: Option<PathBuf>, force: bool) -> Result<PathBuf, BoxError> {
    let pi_agent_dir = resolve_pi_agent_dir(pi_agent_dir)?;
    let extension_path = pi_agent_dir.join("extensions").join("pimux-live.ts");

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

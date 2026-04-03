use std::{
    env, fs,
    io::{Cursor, Write as _},
    path::{Path, PathBuf},
    process,
    time::{SystemTime, UNIX_EPOCH},
};

use flate2::read::GzDecoder;
use reqwest::Client;
use serde::Deserialize;
use tar::Archive;

use crate::{agent, server};

pub type BoxError = Box<dyn std::error::Error + Send + Sync>;

const GITHUB_REPO: &str = "nakajima/pimux2000";
const GITHUB_API_BASE_URL: &str = "https://api.github.com";
const RELEASE_BINARY_NAME: &str = env!("CARGO_PKG_NAME");

pub struct Options {
    pub check: bool,
    pub force: bool,
}

pub enum AutoUpdateResult {
    AlreadyCurrent,
    Updated { from: String, to: String },
}

#[derive(Debug, Clone, Deserialize)]
struct GithubRelease {
    tag_name: String,
    assets: Vec<GithubReleaseAsset>,
}

#[derive(Debug, Clone, Deserialize)]
struct GithubReleaseAsset {
    name: String,
    browser_download_url: String,
}

pub async fn run(options: Options) -> Result<(), BoxError> {
    let current_version = env!("CARGO_PKG_VERSION");
    let current_executable = env::current_exe()?;
    let target = current_release_target()?;
    let client = github_client()?;
    let release = fetch_latest_release(&client).await?;
    let latest_version = normalize_release_tag(&release.tag_name);
    let matching_asset = select_asset(
        &release.assets,
        RELEASE_BINARY_NAME,
        &latest_version,
        &target,
    );

    if options.check {
        if latest_version != current_version && matching_asset.is_none() {
            return Err(format!(
                "latest release v{} does not contain a {} archive for target {}",
                latest_version, RELEASE_BINARY_NAME, target
            )
            .into());
        }
        print_check_result(
            current_version,
            &latest_version,
            &current_executable,
            &target,
        );
        return Ok(());
    }

    if !options.force && latest_version == current_version {
        println!(
            "{} is already up to date at v{} ({})",
            current_executable.display(),
            current_version,
            target
        );
        return Ok(());
    }

    let asset = matching_asset.ok_or_else(|| {
        format!(
            "latest release v{} does not contain a {} archive for target {}",
            latest_version, RELEASE_BINARY_NAME, target
        )
    })?;

    println!(
        "downloading {} for {} from {}",
        asset.name, target, GITHUB_REPO
    );
    let archive_bytes = download_asset(&client, &asset.browser_download_url).await?;
    replace_current_executable_from_archive(
        &archive_bytes,
        &current_executable,
        RELEASE_BINARY_NAME,
    )?;

    if latest_version == current_version {
        println!(
            "reinstalled v{} to {}",
            latest_version,
            current_executable.display()
        );
    } else {
        println!(
            "updated {} from v{} to v{}",
            current_executable.display(),
            current_version,
            latest_version
        );
    }

    print_restart_summary(restart_managed_services());

    Ok(())
}

struct RestartSummary {
    restarted: Vec<String>,
    failed: Vec<String>,
}

fn restart_managed_services() -> RestartSummary {
    let mut summary = RestartSummary {
        restarted: Vec::new(),
        failed: Vec::new(),
    };

    record_restart_attempt(
        &mut summary,
        "server",
        server::restart_service_if_installed(),
    );
    record_restart_attempt(&mut summary, "agent", agent::restart_service_if_installed());

    summary
}

fn record_restart_attempt(
    summary: &mut RestartSummary,
    name: &str,
    result: Result<Option<&'static str>, BoxError>,
) {
    match result {
        Ok(Some(kind)) => summary.restarted.push(format!("{name} ({kind})")),
        Ok(None) => {}
        Err(error) => summary.failed.push(format!("{name}: {error}")),
    }
}

fn print_restart_summary(summary: RestartSummary) {
    if !summary.restarted.is_empty() {
        println!(
            "restarted managed services: {}",
            summary.restarted.join(", ")
        );
        println!("restart any additional foreground pimux server or agent processes manually");
    } else {
        println!("restart any running pimux server or agent processes to use the new binary");
    }

    for failure in summary.failed {
        eprintln!("warning: updated the binary but could not restart managed service {failure}");
    }
}

fn print_check_result(
    current_version: &str,
    latest_version: &str,
    executable: &Path,
    target: &str,
) {
    if latest_version == current_version {
        println!(
            "{} is up to date at v{} ({})",
            executable.display(),
            current_version,
            target
        );
    } else {
        println!(
            "update available for {}: v{} -> v{} ({})",
            executable.display(),
            current_version,
            latest_version,
            target
        );
    }
}

fn github_client() -> Result<Client, BoxError> {
    Ok(Client::builder()
        .user_agent(format!(
            "{}/{}",
            env!("CARGO_PKG_NAME"),
            env!("CARGO_PKG_VERSION")
        ))
        .build()?)
}

async fn fetch_latest_release(client: &Client) -> Result<GithubRelease, BoxError> {
    let url = format!("{GITHUB_API_BASE_URL}/repos/{GITHUB_REPO}/releases/latest");
    let response = client
        .get(url)
        .header("accept", "application/vnd.github+json")
        .send()
        .await?
        .error_for_status()?;

    Ok(response.json::<GithubRelease>().await?)
}

async fn download_asset(client: &Client, url: &str) -> Result<Vec<u8>, BoxError> {
    let response = client
        .get(url)
        .header("accept", "application/octet-stream")
        .send()
        .await?
        .error_for_status()?;
    let bytes = response.bytes().await?;
    Ok(bytes.to_vec())
}

fn normalize_release_tag(tag: &str) -> String {
    tag.trim().trim_start_matches('v').to_string()
}

fn current_release_target() -> Result<String, BoxError> {
    release_target_for(env::consts::OS, env::consts::ARCH)
}

fn release_target_for(os: &str, arch: &str) -> Result<String, BoxError> {
    let os_target = match os {
        "linux" => "unknown-linux-gnu",
        "macos" => "apple-darwin",
        other => return Err(format!("self-update is not supported on {other}").into()),
    };

    let arch_target = match arch {
        "x86_64" | "amd64" => "x86_64",
        "aarch64" | "arm64" => "aarch64",
        other => {
            return Err(format!("self-update is not supported on architecture {other}").into());
        }
    };

    Ok(format!("{arch_target}-{os_target}"))
}

fn select_asset<'a>(
    assets: &'a [GithubReleaseAsset],
    binary_name: &str,
    version: &str,
    target: &str,
) -> Option<&'a GithubReleaseAsset> {
    let expected_name = expected_asset_name(binary_name, version, target);
    assets
        .iter()
        .find(|asset| asset.name == expected_name)
        .or_else(|| {
            assets.iter().find(|asset| {
                asset.name.starts_with(&format!("{binary_name}-"))
                    && asset.name.ends_with(&format!("-{target}.tar.gz"))
            })
        })
}

fn expected_asset_name(binary_name: &str, version: &str, target: &str) -> String {
    format!("{binary_name}-{version}-{target}.tar.gz")
}

fn replace_current_executable_from_archive(
    archive_bytes: &[u8],
    current_executable: &Path,
    binary_name: &str,
) -> Result<(), BoxError> {
    let temp_path = temporary_replacement_path(current_executable)?;
    extract_binary_from_archive(archive_bytes, binary_name, &temp_path)?;
    sync_file(&temp_path)?;

    #[cfg(unix)]
    ensure_executable_permissions(&temp_path)?;

    match fs::rename(&temp_path, current_executable) {
        Ok(()) => Ok(()),
        Err(error) => {
            let _ = fs::remove_file(&temp_path);
            Err(format!(
                "failed to replace {}: {error}",
                current_executable.display()
            )
            .into())
        }
    }
}

fn temporary_replacement_path(current_executable: &Path) -> Result<PathBuf, BoxError> {
    let file_name = current_executable
        .file_name()
        .ok_or_else(|| format!("invalid executable path {}", current_executable.display()))?
        .to_string_lossy();
    let unique = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();

    Ok(
        current_executable
            .with_file_name(format!(".{file_name}.update-{}-{unique}", process::id())),
    )
}

fn extract_binary_from_archive(
    archive_bytes: &[u8],
    binary_name: &str,
    destination: &Path,
) -> Result<(), BoxError> {
    if destination.exists() {
        fs::remove_file(destination)?;
    }

    let decoder = GzDecoder::new(Cursor::new(archive_bytes));
    let mut archive = Archive::new(decoder);

    for entry in archive.entries()? {
        let mut entry = entry?;
        if !entry.header().entry_type().is_file() {
            continue;
        }

        let entry_path = entry.path()?;
        let Some(name) = entry_path.file_name() else {
            continue;
        };
        if name != binary_name {
            continue;
        }

        entry.unpack(destination)?;
        return Ok(());
    }

    Err(format!("downloaded archive did not contain {binary_name}").into())
}

fn sync_file(path: &Path) -> Result<(), BoxError> {
    let mut file = fs::OpenOptions::new().read(true).write(true).open(path)?;
    file.flush()?;
    file.sync_all()?;
    Ok(())
}

#[cfg(unix)]
fn ensure_executable_permissions(path: &Path) -> Result<(), BoxError> {
    use std::os::unix::fs::PermissionsExt;

    let mut permissions = fs::metadata(path)?.permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions)?;
    Ok(())
}

pub async fn check_and_apply() -> Result<AutoUpdateResult, BoxError> {
    let current_version = env!("CARGO_PKG_VERSION");
    let current_executable = env::current_exe()?;
    let target = current_release_target()?;
    let client = github_client()?;
    let release = fetch_latest_release(&client).await?;
    let latest_version = normalize_release_tag(&release.tag_name);

    if latest_version == current_version {
        return Ok(AutoUpdateResult::AlreadyCurrent);
    }

    let asset = select_asset(
        &release.assets,
        RELEASE_BINARY_NAME,
        &latest_version,
        &target,
    )
    .ok_or_else(|| {
        format!(
            "latest release v{} does not contain a {} archive for target {}",
            latest_version, RELEASE_BINARY_NAME, target
        )
    })?;

    let archive_bytes = download_asset(&client, &asset.browser_download_url).await?;
    replace_current_executable_from_archive(
        &archive_bytes,
        &current_executable,
        RELEASE_BINARY_NAME,
    )?;

    restart_managed_services();

    Ok(AutoUpdateResult::Updated {
        from: current_version.to_string(),
        to: latest_version,
    })
}

pub fn spawn_auto_update_task() {
    if auto_update_disabled() {
        return;
    }

    tokio::spawn(auto_update_loop());
}

const AUTO_UPDATE_INITIAL_DELAY: std::time::Duration = std::time::Duration::from_secs(60);
const AUTO_UPDATE_INTERVAL: std::time::Duration = std::time::Duration::from_secs(3600);

async fn auto_update_loop() {
    tokio::time::sleep(AUTO_UPDATE_INITIAL_DELAY).await;

    let mut interval = tokio::time::interval(AUTO_UPDATE_INTERVAL);
    loop {
        interval.tick().await;
        match check_and_apply().await {
            Ok(AutoUpdateResult::AlreadyCurrent) => {}
            Ok(AutoUpdateResult::Updated { from, to }) => {
                eprintln!("auto-update: updated from v{from} to v{to}, restarting");
            }
            Err(error) => {
                eprintln!("auto-update: check failed: {error}");
            }
        }
    }
}

fn auto_update_disabled() -> bool {
    let Ok(value) = env::var("PIMUX_AUTO_UPDATE") else {
        return false;
    };
    let normalized = value.trim().to_ascii_lowercase();
    matches!(normalized.as_str(), "0" | "false" | "no" | "off")
}

#[cfg(test)]
mod tests {
    use std::{fs, io::Cursor, path::PathBuf};

    use flate2::{Compression, write::GzEncoder};
    use tar::{Builder, Header};

    use super::*;

    #[test]
    fn normalizes_release_tags() {
        assert_eq!(normalize_release_tag("v1.2.3"), "1.2.3");
        assert_eq!(normalize_release_tag("1.2.3"), "1.2.3");
        assert_eq!(normalize_release_tag("  v2.0.0  "), "2.0.0");
    }

    #[test]
    fn maps_supported_release_targets() {
        assert_eq!(
            release_target_for("macos", "aarch64").unwrap(),
            "aarch64-apple-darwin"
        );
        assert_eq!(
            release_target_for("macos", "x86_64").unwrap(),
            "x86_64-apple-darwin"
        );
        assert_eq!(
            release_target_for("linux", "aarch64").unwrap(),
            "aarch64-unknown-linux-gnu"
        );
        assert_eq!(
            release_target_for("linux", "x86_64").unwrap(),
            "x86_64-unknown-linux-gnu"
        );
    }

    #[test]
    fn rejects_unsupported_release_targets() {
        assert!(release_target_for("windows", "x86_64").is_err());
        assert!(release_target_for("linux", "riscv64").is_err());
    }

    #[test]
    fn selects_matching_release_asset() {
        let assets = vec![
            GithubReleaseAsset {
                name: "pimux-server-0.1.0-x86_64-apple-darwin.tar.gz".to_string(),
                browser_download_url: "https://example.com/macos-x86_64".to_string(),
            },
            GithubReleaseAsset {
                name: "pimux-server-0.1.0-aarch64-apple-darwin.tar.gz".to_string(),
                browser_download_url: "https://example.com/macos-aarch64".to_string(),
            },
        ];

        let selected =
            select_asset(&assets, "pimux-server", "0.1.0", "aarch64-apple-darwin").unwrap();
        assert_eq!(
            selected.browser_download_url,
            "https://example.com/macos-aarch64"
        );
    }

    #[test]
    fn extracts_binary_from_release_archive() {
        let archive = test_archive();
        let destination = unique_test_path("extracts-binary");

        extract_binary_from_archive(&archive, "pimux-server", &destination).unwrap();

        let contents = fs::read_to_string(&destination).unwrap();
        assert_eq!(contents, "hello from pimux");

        let _ = fs::remove_file(destination);
    }

    fn test_archive() -> Vec<u8> {
        let encoder = GzEncoder::new(Vec::new(), Compression::default());
        let mut builder = Builder::new(encoder);

        append_file(&mut builder, "README.txt", b"ignore me");
        append_file(&mut builder, "pimux-server", b"hello from pimux");

        let encoder = builder.into_inner().unwrap();
        encoder.finish().unwrap()
    }

    fn append_file(builder: &mut Builder<GzEncoder<Vec<u8>>>, path: &str, contents: &[u8]) {
        let mut header = Header::new_gnu();
        header.set_size(contents.len() as u64);
        header.set_mode(0o755);
        header.set_cksum();
        builder
            .append_data(&mut header, path, Cursor::new(contents))
            .unwrap();
    }

    fn unique_test_path(label: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "pimux-self-update-{label}-{}-{unique}",
            process::id()
        ))
    }
}

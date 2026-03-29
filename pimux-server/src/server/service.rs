use std::{
    env,
    fs::{self, OpenOptions},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use super::BoxError;

const SYSTEMD_UNIT_NAME: &str = "pimux-server.service";
const LAUNCH_AGENT_LABEL: &str = "dev.pimux.server";
const LAUNCH_AGENT_FILE_NAME: &str = "dev.pimux.server.plist";

pub struct Config {
    pub port: Option<u16>,
}

pub struct InstallResult {
    pub kind: &'static str,
    pub path: PathBuf,
}

pub struct UninstallResult {
    pub kind: &'static str,
    pub path: PathBuf,
    pub removed: bool,
}

pub fn install(config: Config) -> Result<InstallResult, BoxError> {
    match env::consts::OS {
        "linux" => install_systemd_user_service(&config),
        "macos" => install_launch_agent(&config),
        other => Err(format!("server service install is not supported on {other}").into()),
    }
}

pub fn uninstall() -> Result<UninstallResult, BoxError> {
    match env::consts::OS {
        "linux" => uninstall_systemd_user_service(),
        "macos" => uninstall_launch_agent(),
        other => Err(format!("server service uninstall is not supported on {other}").into()),
    }
}

pub fn restart_if_installed() -> Result<Option<&'static str>, BoxError> {
    match env::consts::OS {
        "linux" => restart_systemd_user_service_if_installed(),
        "macos" => restart_launch_agent_if_installed(),
        other => Err(format!("server service restart is not supported on {other}").into()),
    }
}

fn install_systemd_user_service(config: &Config) -> Result<InstallResult, BoxError> {
    let unit_path = systemd_unit_path()?;
    let executable = current_executable()?;
    let path_env = env::var("PATH").ok();
    let unit = render_systemd_unit(&executable, path_env.as_deref(), config.port);

    write_file(&unit_path, &unit)?;
    run_command("systemctl", &["--user", "daemon-reload"])?;
    run_command(
        "systemctl",
        &["--user", "enable", "--now", SYSTEMD_UNIT_NAME],
    )?;
    run_command("systemctl", &["--user", "restart", SYSTEMD_UNIT_NAME])?;

    Ok(InstallResult {
        kind: "systemd --user",
        path: unit_path,
    })
}

fn uninstall_systemd_user_service() -> Result<UninstallResult, BoxError> {
    let unit_path = systemd_unit_path()?;

    let _ = run_command(
        "systemctl",
        &["--user", "disable", "--now", SYSTEMD_UNIT_NAME],
    );
    let removed = remove_file_if_exists(&unit_path)?;
    let _ = run_command("systemctl", &["--user", "daemon-reload"]);

    Ok(UninstallResult {
        kind: "systemd --user",
        path: unit_path,
        removed,
    })
}

fn restart_systemd_user_service_if_installed() -> Result<Option<&'static str>, BoxError> {
    let unit_path = systemd_unit_path()?;
    if !unit_path.exists() {
        return Ok(None);
    }

    run_command("systemctl", &["--user", "daemon-reload"])?;
    run_command("systemctl", &["--user", "restart", SYSTEMD_UNIT_NAME])?;
    Ok(Some("systemd --user"))
}

fn install_launch_agent(config: &Config) -> Result<InstallResult, BoxError> {
    let plist_path = launch_agent_path()?;
    let executable = current_executable()?;
    let path_env = env::var("PATH").ok();
    let stdout_log = launch_agent_log_path("out")?;
    let stderr_log = launch_agent_log_path("err")?;
    let plist = render_launch_agent_plist(
        &executable,
        path_env.as_deref(),
        config.port,
        &stdout_log,
        &stderr_log,
    );

    touch_file(&stdout_log)?;
    touch_file(&stderr_log)?;
    write_file(&plist_path, &plist)?;

    let domain = launchctl_domain()?;
    let label = format!("{domain}/{LAUNCH_AGENT_LABEL}");
    let _ = run_command("launchctl", &["bootout", &label]);
    run_command(
        "launchctl",
        &["bootstrap", &domain, &plist_path.display().to_string()],
    )?;
    run_command("launchctl", &["kickstart", "-k", &label])?;

    Ok(InstallResult {
        kind: "launchctl",
        path: plist_path,
    })
}

fn uninstall_launch_agent() -> Result<UninstallResult, BoxError> {
    let plist_path = launch_agent_path()?;
    let domain = launchctl_domain()?;

    let _ = run_command(
        "launchctl",
        &["bootout", &format!("{domain}/{LAUNCH_AGENT_LABEL}")],
    );
    let removed = remove_file_if_exists(&plist_path)?;

    Ok(UninstallResult {
        kind: "launchctl",
        path: plist_path,
        removed,
    })
}

fn restart_launch_agent_if_installed() -> Result<Option<&'static str>, BoxError> {
    let plist_path = launch_agent_path()?;
    if !plist_path.exists() {
        return Ok(None);
    }

    let domain = launchctl_domain()?;
    let label = format!("{domain}/{LAUNCH_AGENT_LABEL}");
    if command_succeeds("launchctl", &["print", &label]) {
        run_command("launchctl", &["kickstart", "-k", &label])?;
    } else {
        run_command(
            "launchctl",
            &["bootstrap", &domain, &plist_path.display().to_string()],
        )?;
        run_command("launchctl", &["kickstart", "-k", &label])?;
    }

    Ok(Some("launchctl"))
}

fn current_executable() -> Result<PathBuf, BoxError> {
    Ok(env::current_exe()?)
}

fn systemd_unit_path() -> Result<PathBuf, BoxError> {
    Ok(home_dir()?
        .join(".config")
        .join("systemd")
        .join("user")
        .join(SYSTEMD_UNIT_NAME))
}

fn launch_agent_path() -> Result<PathBuf, BoxError> {
    Ok(home_dir()?
        .join("Library")
        .join("LaunchAgents")
        .join(LAUNCH_AGENT_FILE_NAME))
}

fn launch_agent_log_path(suffix: &str) -> Result<PathBuf, BoxError> {
    Ok(home_dir()?
        .join("Library")
        .join("Logs")
        .join(format!("pimux-server.{suffix}.log")))
}

fn launchctl_domain() -> Result<String, BoxError> {
    let uid = env::var("SUDO_UID")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| run_command("id", &["-u"]).unwrap_or_default());
    Ok(format!("gui/{}", uid.trim()))
}

fn home_dir() -> Result<PathBuf, BoxError> {
    Ok(PathBuf::from(env::var("HOME")?))
}

fn write_file(path: &Path, contents: &str) -> Result<(), BoxError> {
    ensure_parent_dir(path)?;
    fs::write(path, contents)?;
    Ok(())
}

fn touch_file(path: &Path) -> Result<(), BoxError> {
    ensure_parent_dir(path)?;
    OpenOptions::new().create(true).append(true).open(path)?;
    Ok(())
}

fn ensure_parent_dir(path: &Path) -> Result<(), BoxError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    Ok(())
}

fn remove_file_if_exists(path: &Path) -> Result<bool, BoxError> {
    if path.exists() {
        fs::remove_file(path)?;
        Ok(true)
    } else {
        Ok(false)
    }
}

fn render_systemd_unit(executable: &Path, path_env: Option<&str>, port: Option<u16>) -> String {
    let exec_start = quote_systemd_arg(&executable.display().to_string());

    let mut lines = vec![
        "[Unit]".to_string(),
        "Description=pimux server".to_string(),
        String::new(),
        "[Service]".to_string(),
        "Type=simple".to_string(),
        format!("ExecStart={exec_start} \"server\""),
        "Restart=always".to_string(),
        "RestartSec=2".to_string(),
    ];

    if let Some(path_env) = path_env {
        lines.push(format!(
            "Environment=PATH={}",
            quote_systemd_env_value(path_env)
        ));
    }
    if let Some(port) = port {
        lines.push(format!(
            "Environment=PORT={}",
            quote_systemd_env_value(&port.to_string())
        ));
    }

    lines.push(String::new());
    lines.push("[Install]".to_string());
    lines.push("WantedBy=default.target".to_string());
    lines.push(String::new());

    lines.join("\n")
}

fn render_launch_agent_plist(
    executable: &Path,
    path_env: Option<&str>,
    port: Option<u16>,
    stdout_log: &Path,
    stderr_log: &Path,
) -> String {
    let mut program_args = Vec::new();
    program_args.push(plist_string(&executable.display().to_string()));
    program_args.push(plist_string("server"));

    let mut environment_entries = Vec::new();
    if let Some(path_env) = path_env {
        environment_entries.push(("PATH", path_env.to_string()));
    }
    if let Some(port) = port {
        environment_entries.push(("PORT", port.to_string()));
    }

    let environment = if environment_entries.is_empty() {
        String::new()
    } else {
        let entries = environment_entries
            .into_iter()
            .map(|(key, value)| {
                format!(
                    "\n\t\t<key>{}</key>\n\t\t{}",
                    xml_escape(key),
                    plist_string(&value)
                )
            })
            .collect::<String>();
        format!("\n\t<key>EnvironmentVariables</key>\n\t<dict>{entries}\n\t</dict>")
    };

    format!(
        concat!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n",
            "<plist version=\"1.0\">\n",
            "<dict>\n",
            "\t<key>Label</key>\n",
            "\t<string>{label}</string>\n",
            "\t<key>ProgramArguments</key>\n",
            "\t<array>\n",
            "{program_args}\n",
            "\t</array>{environment}\n",
            "\t<key>RunAtLoad</key>\n",
            "\t<true/>\n",
            "\t<key>KeepAlive</key>\n",
            "\t<true/>\n",
            "\t<key>StandardOutPath</key>\n",
            "\t<string>{stdout_log}</string>\n",
            "\t<key>StandardErrorPath</key>\n",
            "\t<string>{stderr_log}</string>\n",
            "</dict>\n",
            "</plist>\n"
        ),
        label = xml_escape(LAUNCH_AGENT_LABEL),
        program_args = program_args.join("\n"),
        environment = environment,
        stdout_log = xml_escape(&stdout_log.display().to_string()),
        stderr_log = xml_escape(&stderr_log.display().to_string()),
    )
}

fn quote_systemd_arg(value: &str) -> String {
    format!(
        "\"{}\"",
        value
            .replace('%', "%%")
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
    )
}

fn quote_systemd_env_value(value: &str) -> String {
    quote_systemd_arg(value)
}

fn plist_string(value: &str) -> String {
    format!("\t\t<string>{}</string>", xml_escape(value))
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn command_succeeds(command: &str, args: &[&str]) -> bool {
    Command::new(command)
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn run_command(command: &str, args: &[&str]) -> Result<String, BoxError> {
    let output = Command::new(command).args(args).output()?;
    if output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        return Ok(stdout);
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let details = if !stderr.is_empty() {
        stderr
    } else if !stdout.is_empty() {
        stdout
    } else {
        format!("{command} exited with status {}", output.status)
    };

    Err(format!("{command} {}: {details}", args.join(" ")).into())
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;

    #[test]
    fn renders_systemd_unit_with_port() {
        let unit = render_systemd_unit(
            Path::new("/tmp/pimux-server"),
            Some("/usr/bin:/opt/bin"),
            Some(4123),
        );

        assert!(unit.contains("ExecStart=\"/tmp/pimux-server\" \"server\""));
        assert!(unit.contains("Environment=PATH=\"/usr/bin:/opt/bin\""));
        assert!(unit.contains("Environment=PORT=\"4123\""));
        assert!(unit.contains("WantedBy=default.target"));
    }

    #[test]
    fn renders_launch_agent_plist_with_port() {
        let plist = render_launch_agent_plist(
            Path::new("/tmp/pimux-server"),
            Some("/usr/bin:/opt/bin"),
            Some(4123),
            Path::new("/tmp/out.log"),
            Path::new("/tmp/err.log"),
        );

        assert!(plist.contains("<string>dev.pimux.server</string>"));
        assert!(plist.contains("<string>/tmp/pimux-server</string>"));
        assert!(plist.contains("<string>server</string>"));
        assert!(plist.contains("<key>PATH</key>"));
        assert!(plist.contains("<string>/usr/bin:/opt/bin</string>"));
        assert!(plist.contains("<key>PORT</key>"));
        assert!(plist.contains("<string>4123</string>"));
        assert!(plist.contains("<string>/tmp/out.log</string>"));
        assert!(plist.contains("<string>/tmp/err.log</string>"));
    }
}

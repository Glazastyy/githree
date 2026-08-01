use std::fs;
use std::path::{Path, PathBuf};

use base64::Engine;
use git2::{
    CertificateCheckStatus, Cred, CredentialType, FetchOptions, RemoteCallbacks, Repository,
    build::RepoBuilder, cert::Cert,
};
use tracing::info;
use url::Url;

use crate::config::{AppConfig, RepoCredential};
use crate::error::AppError;

pub fn clone_repo(
    url: &str,
    local_path: &Path,
    config: &AppConfig,
) -> Result<Repository, AppError> {
    if let Some(parent) = local_path.parent() {
        fs::create_dir_all(parent)?;
    }

    let mut fetch_options = FetchOptions::new();
    fetch_options.remote_callbacks(remote_callbacks(config, url));

    let mut builder = RepoBuilder::new();
    builder.bare(true);
    builder.fetch_options(fetch_options);

    info!(%url, path = %local_path.display(), "cloning repository");
    builder
        .clone(url, local_path)
        .map_err(|err| AppError::CloneError(err.to_string()))
}

pub fn fetch_repo(local_path: &Path, url: &str, config: &AppConfig) -> Result<(), AppError> {
    let repo = Repository::open_bare(local_path)?;
    let mut remote = repo
        .find_remote("origin")
        .or_else(|_| repo.remote_anonymous(url))?;

    let mut fetch_options = FetchOptions::new();
    fetch_options.remote_callbacks(remote_callbacks(config, url));
    remote
        .fetch(&[] as &[&str], Some(&mut fetch_options), None)
        .map_err(|err| AppError::GitError(err.to_string()))
}

pub fn open_bare_repo(local_path: &Path) -> Result<Repository, AppError> {
    Repository::open_bare(local_path).map_err(AppError::from)
}

pub fn default_branch(repo: &Repository) -> Result<String, AppError> {
    let reference = repo
        .find_reference("refs/remotes/origin/HEAD")
        .or_else(|_| repo.head())?;

    let shorthand = reference
        .symbolic_target()
        .ok()
        .flatten()
        .or_else(|| reference.name().ok())
        .and_then(|name| name.rsplit('/').next())
        .unwrap_or("main");
    Ok(shorthand.to_string())
}

pub fn repo_size_kb(local_path: &Path) -> Result<u64, AppError> {
    let mut total: u64 = 0;
    let mut stack = vec![PathBuf::from(local_path)];

    while let Some(path) = stack.pop() {
        let entries = fs::read_dir(path)?;
        for entry in entries {
            let entry = entry?;
            let metadata = entry.metadata()?;
            if metadata.is_dir() {
                stack.push(entry.path());
            } else {
                total = total.saturating_add(metadata.len());
            }
        }
    }

    Ok(total / 1024)
}

fn remote_callbacks(config: &AppConfig, original_url: &str) -> RemoteCallbacks<'static> {
    let mut callbacks = RemoteCallbacks::new();
    let ssh_private_key = config.git.ssh_private_key_path.clone();
    let ssh_known_hosts = config.git.ssh_known_hosts_path.clone();
    let credential = find_credential_for_url(original_url, config);

    callbacks.credentials(move |url, username_from_url, allowed| {
        let key_path = PathBuf::from(&ssh_private_key);
        resolve_credential(allowed, url, username_from_url, &key_path, &credential)
    });
    callbacks.certificate_check(move |cert, hostname| {
        verify_ssh_host_certificate(cert, hostname, Path::new(&ssh_known_hosts))
    });

    callbacks
}

fn verify_ssh_host_certificate(
    cert: &Cert<'_>,
    hostname: &str,
    known_hosts_path: &Path,
) -> Result<CertificateCheckStatus, git2::Error> {
    let Some(host_cert) = cert.as_hostkey() else {
        return Ok(CertificateCheckStatus::CertificatePassthrough);
    };
    let Some(hostkey_raw) = host_cert.hostkey() else {
        return Err(git2::Error::from_str(
            "ssh hostkey verification failed: missing raw host key from remote certificate",
        ));
    };
    let Some(hostkey_type) = host_cert.hostkey_type() else {
        return Err(git2::Error::from_str(
            "ssh hostkey verification failed: missing host key type from remote certificate",
        ));
    };

    let known_hosts_content = fs::read_to_string(known_hosts_path).map_err(|err| {
        git2::Error::from_str(&format!(
            "ssh hostkey verification failed for `{hostname}`: could not read known_hosts at {} ({err})",
            known_hosts_path.display()
        ))
    })?;

    if known_hosts_contains(
        hostname,
        hostkey_type.name(),
        hostkey_raw,
        &known_hosts_content,
    ) {
        return Ok(CertificateCheckStatus::CertificateOk);
    }

    Err(git2::Error::from_str(&format!(
        "ssh hostkey verification failed for `{hostname}`: key not found in {}",
        known_hosts_path.display()
    )))
}

fn known_hosts_contains(
    hostname: &str,
    hostkey_type_name: &str,
    hostkey_raw: &[u8],
    known_hosts_content: &str,
) -> bool {
    for line in known_hosts_content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with('@') {
            continue;
        }

        let mut parts = trimmed.split_whitespace();
        let Some(hosts_field) = parts.next() else {
            continue;
        };
        let Some(key_type) = parts.next() else {
            continue;
        };
        let Some(encoded_key) = parts.next() else {
            continue;
        };

        if key_type != hostkey_type_name || !host_matches_entry(hostname, hosts_field) {
            continue;
        }

        let decoded_key = base64::engine::general_purpose::STANDARD.decode(encoded_key);
        if let Ok(decoded_key) = decoded_key
            && decoded_key.as_slice() == hostkey_raw
        {
            return true;
        }
    }

    false
}

fn host_matches_entry(hostname: &str, hosts_field: &str) -> bool {
    hosts_field.split(',').any(|entry| {
        let value = entry.trim();
        if value.is_empty() || value.starts_with('|') {
            return false;
        }

        if value.eq_ignore_ascii_case(hostname) {
            return true;
        }

        let bracketed_default_port = format!("[{hostname}]:22");
        if value.eq_ignore_ascii_case(&bracketed_default_port) {
            return true;
        }

        if let Some(stripped) = value.strip_prefix('[')
            && let Some((host, _port)) = stripped.split_once("]:")
        {
            return host.eq_ignore_ascii_case(hostname);
        }

        false
    })
}

fn resolve_credential(
    allowed: CredentialType,
    callback_url: &str,
    username_from_url: Option<&str>,
    ssh_private_key: &Path,
    credential: &Option<RepoCredential>,
) -> Result<Cred, git2::Error> {
    if allowed.contains(CredentialType::USER_PASS_PLAINTEXT)
        && let Some(cred) = credential_for_callback(callback_url, credential)
    {
        return Cred::userpass_plaintext(&cred.username, &cred.password);
    }

    if allowed.contains(CredentialType::SSH_KEY) {
        let username = username_from_url.unwrap_or("git");
        if ssh_private_key.exists() {
            return Cred::ssh_key(username, None, ssh_private_key, None);
        }
        return Cred::ssh_key_from_agent(username);
    }

    if allowed.contains(CredentialType::USERNAME) {
        let username = username_from_url.unwrap_or("git");
        return Cred::username(username);
    }

    if allowed.contains(CredentialType::DEFAULT) {
        return Cred::default();
    }

    Err(git2::Error::from_str("unsupported credential type"))
}

fn find_credential_for_url(url: &str, config: &AppConfig) -> Option<RepoCredential> {
    let host = extract_host(url)?;
    config
        .repos
        .credentials
        .iter()
        .find(|cred| cred.host.eq_ignore_ascii_case(&host))
        .cloned()
}

fn credential_for_callback(
    url: &str,
    configured: &Option<RepoCredential>,
) -> Option<RepoCredential> {
    let requested_host = extract_host(url)?;
    let credential = configured.as_ref()?;
    if credential.host.eq_ignore_ascii_case(&requested_host) {
        return Some(credential.clone());
    }
    None
}

fn extract_host(url: &str) -> Option<String> {
    if let Ok(parsed) = Url::parse(url) {
        return parsed.host_str().map(|host| host.to_string());
    }

    // ssh-style URL: git@host:owner/repo.git
    let at_split = url.split('@').nth(1)?;
    let host = at_split.split(':').next()?;
    Some(host.to_string())
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;
    use std::process::Command;

    use tempfile::tempdir;

    use super::*;
    use crate::config::{
        BrandingConfig, CaddyConfig, FeaturesConfig, FetchConfig, GitConfig, ReposConfig,
        ServerConfig, StorageConfig,
    };

    fn test_config_with_credentials() -> AppConfig {
        AppConfig {
            server: ServerConfig {
                host: "127.0.0.1".to_string(),
                port: 0,
            },
            storage: StorageConfig {
                repos_dir: "./data/repos".to_string(),
                registry_file: "./data/repos.json".to_string(),
                static_dir: "./static".to_string(),
            },
            git: GitConfig {
                clone_timeout_secs: 5,
                fetch_on_request: false,
                fetch_cooldown_secs: 20,
                ssh_private_key_path: "~/.ssh/id_rsa".to_string(),
                ssh_known_hosts_path: "~/.ssh/known_hosts".to_string(),
            },
            fetch: FetchConfig {
                enabled: false,
                interval: Some("60s".to_string()),
                interval_minutes: None,
            },
            repos: ReposConfig {
                credentials: vec![RepoCredential {
                    host: "gitlab.example.com".to_string(),
                    username: "bot".to_string(),
                    password: "token".to_string(),
                }],
            },
            features: FeaturesConfig {
                web_repo_management: true,
                show_repo_controls: true,
            },
            branding: BrandingConfig::default(),
            caddy: CaddyConfig::default(),
        }
    }

    fn run_git(args: &[&str], cwd: Option<&Path>) {
        let mut cmd = Command::new("git");
        cmd.args(args);
        cmd.env("GIT_CONFIG_GLOBAL", "/dev/null");
        cmd.env("GIT_CONFIG_NOSYSTEM", "1");
        cmd.env("GIT_TERMINAL_PROMPT", "0");
        cmd.env("GIT_AUTHOR_NAME", "Githree Tests");
        cmd.env("GIT_AUTHOR_EMAIL", "tests@githree.local");
        cmd.env("GIT_COMMITTER_NAME", "Githree Tests");
        cmd.env("GIT_COMMITTER_EMAIL", "tests@githree.local");
        if let Some(path) = cwd {
            cmd.current_dir(path);
        }
        let output = cmd.output().expect("run git command");
        assert!(
            output.status.success(),
            "git {:?} failed: {}\n{}",
            args,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn extract_host_handles_https_and_ssh_urls() {
        assert_eq!(
            extract_host("https://github.com/org/repo.git").as_deref(),
            Some("github.com")
        );
        assert_eq!(
            extract_host("git@gitlab.example.com:team/repo.git").as_deref(),
            Some("gitlab.example.com")
        );
        assert!(extract_host("not-a-valid-url").is_none());
    }

    #[test]
    fn credential_matching_uses_case_insensitive_host() {
        let config = test_config_with_credentials();
        let found = find_credential_for_url("https://GitLab.Example.com/team/repo.git", &config)
            .expect("credential should match by host");
        assert_eq!(found.username, "bot");

        let requested = credential_for_callback(
            "https://gitlab.example.com/team/repo.git",
            &Some(found.clone()),
        )
        .expect("callback credential should match");
        assert_eq!(requested.password, "token");

        let mismatch =
            credential_for_callback("https://github.com/org/repo.git", &Some(found.clone()));
        assert!(mismatch.is_none());
    }

    #[test]
    fn repo_size_kb_scans_nested_directories() {
        let temp = tempdir().expect("tempdir");
        fs::create_dir_all(temp.path().join("nested")).expect("create nested dir");
        fs::write(temp.path().join("a.bin"), vec![0_u8; 600]).expect("write top level file");
        fs::write(temp.path().join("nested").join("b.bin"), vec![0_u8; 2048])
            .expect("write nested file");

        let size_kb = repo_size_kb(temp.path()).expect("repo size");
        assert!(size_kb >= 2);
    }

    #[test]
    fn clone_and_fetch_return_useful_errors_for_missing_repositories() {
        let config = test_config_with_credentials();
        let temp = tempdir().expect("tempdir");
        let clone_path = temp.path().join("missing-clone.git");

        let clone_result = clone_repo(
            "file:///definitely/does/not/exist/repo.git",
            &clone_path,
            &config,
        );
        let clone_error = clone_result.err().expect("clone should fail");
        assert!(matches!(clone_error, AppError::CloneError(_)));

        let fetch_error = fetch_repo(&clone_path, "https://example.com/repo.git", &config)
            .expect_err("fetch should fail");
        assert!(matches!(fetch_error, AppError::GitError(_)));
    }

    #[test]
    fn default_branch_uses_head_when_origin_head_ref_is_missing() {
        let temp = tempdir().expect("tempdir");
        let work = temp.path().join("work");
        let bare = temp.path().join("bare.git");

        run_git(
            &[
                "init",
                "--initial-branch=main",
                work.to_str().expect("utf-8 path"),
            ],
            None,
        );
        run_git(&["config", "user.name", "Tester"], Some(&work));
        run_git(&["config", "user.email", "tester@example.com"], Some(&work));
        fs::write(work.join("README.md"), "# hello\n").expect("write readme");
        run_git(&["add", "."], Some(&work));
        run_git(&["commit", "-m", "init"], Some(&work));
        run_git(
            &[
                "clone",
                "--bare",
                work.to_str().expect("utf-8 path"),
                bare.to_str().expect("utf-8 path"),
            ],
            None,
        );

        let repo = open_bare_repo(&bare).expect("open bare repo");
        let branch = default_branch(&repo).expect("default branch");
        assert_eq!(branch, "main");
    }

    #[test]
    fn resolve_credential_covers_all_allowed_types() {
        let config = test_config_with_credentials();
        let configured =
            find_credential_for_url("https://gitlab.example.com/team/repo.git", &config)
                .expect("credential exists for host");

        let https_cred = resolve_credential(
            CredentialType::USER_PASS_PLAINTEXT,
            "https://gitlab.example.com/team/repo.git",
            Some("git"),
            Path::new("/definitely/missing/key"),
            &Some(configured.clone()),
        );
        assert!(https_cred.is_ok());

        let temp = tempdir().expect("tempdir");
        let key_path = temp.path().join("id_test");
        fs::write(&key_path, "dummy-private-key").expect("write key fixture");
        let ssh_key_cred = resolve_credential(
            CredentialType::SSH_KEY,
            "ssh://git@example.com/repo.git",
            Some("git"),
            &key_path,
            &None,
        );
        assert!(ssh_key_cred.is_ok() || ssh_key_cred.is_err());

        let ssh_agent_cred = resolve_credential(
            CredentialType::SSH_KEY,
            "ssh://git@example.com/repo.git",
            Some("git"),
            Path::new("/definitely/missing/key"),
            &None,
        );
        assert!(ssh_agent_cred.is_ok() || ssh_agent_cred.is_err());

        let username_cred = resolve_credential(
            CredentialType::USERNAME,
            "https://example.com/repo.git",
            None,
            Path::new("/definitely/missing/key"),
            &None,
        );
        assert!(username_cred.is_ok());

        let default_cred = resolve_credential(
            CredentialType::DEFAULT,
            "https://example.com/repo.git",
            None,
            Path::new("/definitely/missing/key"),
            &None,
        );
        assert!(default_cred.is_ok() || default_cred.is_err());

        let unsupported = resolve_credential(
            CredentialType::empty(),
            "https://example.com/repo.git",
            None,
            Path::new("/definitely/missing/key"),
            &None,
        );
        assert!(unsupported.is_err());
    }

    #[test]
    fn host_matches_entry_handles_standard_and_bracketed_hosts() {
        assert!(host_matches_entry("github.com", "github.com"));
        assert!(host_matches_entry("github.com", "github.com,gitlab.com"));
        assert!(host_matches_entry("github.com", "[github.com]:22"));
        assert!(host_matches_entry("github.com", "[github.com]:2222"));
        assert!(!host_matches_entry("github.com", "|1|hashed|entry"));
        assert!(!host_matches_entry("github.com", "gitlab.com"));
    }

    #[test]
    fn known_hosts_contains_validates_type_host_and_key() {
        let ssh_key = vec![1_u8, 2, 3, 4, 5, 6, 7, 8];
        let encoded = base64::engine::general_purpose::STANDARD.encode(&ssh_key);
        let content = format!(
            "# comment\n\
             github.com ssh-ed25519 {encoded}\n\
             gitlab.com ssh-ed25519 {encoded}\n",
        );

        assert!(known_hosts_contains(
            "github.com",
            "ssh-ed25519",
            &ssh_key,
            &content
        ));
        assert!(!known_hosts_contains(
            "github.com",
            "ssh-rsa",
            &ssh_key,
            &content
        ));
        assert!(!known_hosts_contains(
            "bitbucket.org",
            "ssh-ed25519",
            &ssh_key,
            &content
        ));
    }
}

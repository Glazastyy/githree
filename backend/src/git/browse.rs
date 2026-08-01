use std::collections::HashMap;
use std::path::Path;
use std::{cell::Cell, cell::RefCell};

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use chrono::{DateTime, Utc};
use git2::{
    Commit, DiffDelta, DiffHunk as GitDiffHunk, DiffLine as GitDiffLine, DiffOptions, ErrorCode,
    ObjectType, Oid, Repository,
};

use crate::error::AppError;
use crate::git::{
    BlobResponse, CommitDetail, CommitInfo, DiffHunk, DiffLine, DiffStats, FileDiff, LanguageStat,
    ReadmeResponse, TreeEntry, detect_language,
};

const MAX_RENDERABLE_TEXT_BYTES: usize = 512 * 1024;
const MAX_INLINE_BINARY_BYTES: usize = 5 * 1024 * 1024;
const MAX_DIFF_FILES: usize = 300;
const MAX_DIFF_LINES: usize = 20_000;

pub struct RawFile {
    pub content: Vec<u8>,
    pub mime: String,
    pub file_name: String,
}

pub fn list_tree(
    local_path: &Path,
    ref_name: &str,
    path: &str,
) -> Result<Vec<TreeEntry>, AppError> {
    let repo = Repository::open_bare(local_path)?;
    let commit = resolve_commit(&repo, ref_name)?;
    let root_tree = commit.tree()?;
    let selected_tree = if path.trim().is_empty() {
        root_tree
    } else {
        let object = root_tree
            .get_path(Path::new(path))
            .map_err(|_| AppError::NotFound(format!("path '{path}' not found")))?;
        object
            .to_object(&repo)?
            .peel_to_tree()
            .map_err(|_| AppError::NotFound(format!("'{path}' is not a directory")))?
    };

    let mut entries: Vec<TreeEntry> = Vec::new();
    for entry in &selected_tree {
        let kind = entry.kind().unwrap_or(ObjectType::Blob);
        if kind != ObjectType::Blob && kind != ObjectType::Tree {
            continue;
        }

        let name = entry.name().unwrap_or_default().to_string();
        let full_path = if path.is_empty() {
            name.clone()
        } else {
            format!("{path}/{name}")
        };

        let size = if kind == ObjectType::Blob {
            repo.find_blob(entry.id())
                .ok()
                .map(|blob| blob.size() as u64)
        } else {
            None
        };

        entries.push(TreeEntry {
            name,
            path: full_path,
            entry_type: if kind == ObjectType::Tree {
                "tree".to_string()
            } else {
                "blob".to_string()
            },
            oid: entry.id().to_string(),
            size,
            mode: entry.filemode() as u32,
            last_commit: None,
        });
    }

    entries.sort_by(
        |a, b| match (a.entry_type.as_str(), b.entry_type.as_str()) {
            ("tree", "blob") => std::cmp::Ordering::Less,
            ("blob", "tree") => std::cmp::Ordering::Greater,
            _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
        },
    );
    Ok(entries)
}

pub fn read_blob(local_path: &Path, ref_name: &str, path: &str) -> Result<BlobResponse, AppError> {
    let repo = Repository::open_bare(local_path)?;
    let commit = resolve_commit(&repo, ref_name)?;
    let tree = commit.tree()?;
    let entry = tree
        .get_path(Path::new(path))
        .map_err(|_| AppError::NotFound(format!("file '{path}' not found")))?;

    if entry.kind() != Some(ObjectType::Blob) {
        return Err(AppError::InvalidRequest(format!(
            "path '{path}' is not a file"
        )));
    }

    let blob = repo.find_blob(entry.id())?;
    let bytes = blob.content();
    let infer_mime = infer::get(bytes).map(|kind| kind.mime_type().to_string());
    let guessed_mime = mime_guess::from_path(path)
        .first_raw()
        .map(|value| value.to_string());
    let mime = infer_mime.or(guessed_mime);
    let is_binary = looks_binary(bytes);
    let language = detect_language(path);

    if is_binary {
        if bytes.len() > MAX_INLINE_BINARY_BYTES {
            return Ok(BlobResponse {
                content: String::new(),
                encoding: "base64".to_string(),
                size: bytes.len(),
                language,
                is_binary: true,
                mime,
                is_truncated: true,
                truncated_reason: Some(format!(
                    "Binary file is too large to preview in the browser ({} bytes limit).",
                    MAX_INLINE_BINARY_BYTES
                )),
            });
        }

        return Ok(BlobResponse {
            content: STANDARD.encode(bytes),
            encoding: "base64".to_string(),
            size: bytes.len(),
            language,
            is_binary: true,
            mime,
            is_truncated: false,
            truncated_reason: None,
        });
    }

    if bytes.len() > MAX_RENDERABLE_TEXT_BYTES {
        return Ok(BlobResponse {
            content: String::new(),
            encoding: "utf8".to_string(),
            size: bytes.len(),
            language,
            is_binary: false,
            mime,
            is_truncated: true,
            truncated_reason: Some(format!(
                "File is too large to display ({} bytes limit). Download the raw file.",
                MAX_RENDERABLE_TEXT_BYTES
            )),
        });
    }

    let content = String::from_utf8_lossy(bytes).to_string();
    let encoding = "utf8".to_string();

    Ok(BlobResponse {
        content,
        encoding,
        size: bytes.len(),
        language,
        is_binary: false,
        mime,
        is_truncated: false,
        truncated_reason: None,
    })
}

pub fn read_raw(local_path: &Path, ref_name: &str, path: &str) -> Result<RawFile, AppError> {
    let repo = Repository::open_bare(local_path)?;
    let commit = resolve_commit(&repo, ref_name)?;
    let tree = commit.tree()?;
    let entry = tree
        .get_path(Path::new(path))
        .map_err(|_| AppError::NotFound(format!("file '{path}' not found")))?;

    if entry.kind() != Some(ObjectType::Blob) {
        return Err(AppError::InvalidRequest(format!(
            "path '{path}' is not a file"
        )));
    }

    let blob = repo.find_blob(entry.id())?;
    let bytes = blob.content().to_vec();
    let mime = infer::get(&bytes)
        .map(|kind| kind.mime_type().to_string())
        .or_else(|| {
            mime_guess::from_path(path)
                .first_raw()
                .map(|value| value.to_string())
        })
        .unwrap_or_else(|| "application/octet-stream".to_string());
    let file_name = Path::new(path)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("file.bin")
        .to_string();

    Ok(RawFile {
        content: bytes,
        mime,
        file_name,
    })
}

pub fn read_readme(local_path: &Path, ref_name: &str) -> Result<ReadmeResponse, AppError> {
    const CANDIDATES: [&str; 4] = ["README.md", "README.rst", "README.txt", "readme.md"];

    let repo = Repository::open_bare(local_path)?;
    let commit = resolve_commit(&repo, ref_name)?;
    let tree = commit.tree()?;

    for candidate in CANDIDATES {
        if let Ok(entry) = tree.get_path(Path::new(candidate))
            && entry.kind() == Some(ObjectType::Blob)
        {
            let blob = repo.find_blob(entry.id())?;
            let content = String::from_utf8_lossy(blob.content()).to_string();
            return Ok(ReadmeResponse {
                content,
                filename: candidate.to_string(),
                path: candidate.to_string(),
            });
        }
    }

    Err(AppError::NotFound("README file not found".to_string()))
}

pub fn language_stats(local_path: &Path, ref_name: &str) -> Result<Vec<LanguageStat>, AppError> {
    let repo = Repository::open_bare(local_path)?;
    let commit = resolve_commit(&repo, ref_name)?;
    let root_tree = commit.tree()?;
    let mut totals: HashMap<String, u64> = HashMap::new();
    let mut total_bytes = 0_u64;

    collect_language_bytes(&repo, &root_tree, "", &mut totals, &mut total_bytes)?;

    let mut languages = totals
        .into_iter()
        .map(|(language, bytes)| LanguageStat {
            language,
            bytes,
            percentage: if total_bytes == 0 {
                0.0
            } else {
                (bytes as f64 * 100.0) / total_bytes as f64
            },
        })
        .collect::<Vec<_>>();

    languages.sort_by(|left, right| {
        right
            .bytes
            .cmp(&left.bytes)
            .then_with(|| left.language.cmp(&right.language))
    });
    Ok(languages)
}

pub fn commit_history(
    local_path: &Path,
    ref_name: &str,
    path: Option<&str>,
    skip: usize,
    limit: usize,
) -> Result<Vec<CommitInfo>, AppError> {
    let repo = Repository::open_bare(local_path)?;
    let commit = resolve_commit(&repo, ref_name)?;
    let mut revwalk = repo.revwalk()?;
    revwalk.push(commit.id())?;
    revwalk.set_sorting(git2::Sort::TIME)?;

    let mut commits = Vec::new();
    let mut seen = 0usize;
    let path_filter = path.unwrap_or("").trim().to_string();

    for oid_result in revwalk {
        let oid = oid_result?;
        let commit = repo.find_commit(oid)?;

        if !path_filter.is_empty() && !commit_touches_path(&repo, &commit, &path_filter)? {
            continue;
        }

        if seen < skip {
            seen += 1;
            continue;
        }

        commits.push(map_commit(&commit));
        if commits.len() >= limit {
            break;
        }
    }

    Ok(commits)
}

pub fn commit_count(
    local_path: &Path,
    ref_name: &str,
    path: Option<&str>,
) -> Result<usize, AppError> {
    let repo = Repository::open_bare(local_path)?;
    let commit = resolve_commit(&repo, ref_name)?;
    let mut revwalk = repo.revwalk()?;
    revwalk.push(commit.id())?;
    revwalk.set_sorting(git2::Sort::TIME)?;

    let path_filter = path.unwrap_or("").trim().to_string();
    let mut total = 0usize;

    for oid_result in revwalk {
        let oid = oid_result?;
        let commit = repo.find_commit(oid)?;
        if !path_filter.is_empty() && !commit_touches_path(&repo, &commit, &path_filter)? {
            continue;
        }
        total = total.saturating_add(1);
    }

    Ok(total)
}

pub fn commit_detail(local_path: &Path, hash: &str) -> Result<CommitDetail, AppError> {
    let repo = Repository::open_bare(local_path)?;
    let oid = Oid::from_str(hash).or_else(|_| repo.revparse_single(hash).map(|obj| obj.id()))?;
    let commit = repo.find_commit(oid)?;
    let commit_info = map_commit(&commit);

    let parent_commit = if commit.parent_count() > 0 {
        Some(commit.parent(0)?)
    } else {
        None
    };
    let parent_tree = if let Some(parent) = &parent_commit {
        Some(parent.tree()?)
    } else {
        None
    };
    let current_tree = commit.tree()?;

    let mut diff_options = DiffOptions::new();
    let mut diff = repo.diff_tree_to_tree(
        parent_tree.as_ref(),
        Some(&current_tree),
        Some(&mut diff_options),
    )?;
    // Enable rename detection so commit detail matches common git host behavior.
    diff.find_similar(None)?;
    let stats = diff.stats()?;

    let file_diffs: RefCell<Vec<FileDiff>> = RefCell::new(Vec::new());
    let current_file_index: Cell<Option<usize>> = Cell::new(None);
    let current_hunk_index: Cell<Option<usize>> = Cell::new(None);
    let displayed_line_count: Cell<usize> = Cell::new(0);
    let is_truncated: Cell<bool> = Cell::new(false);
    let truncated_reason: RefCell<Option<String>> = RefCell::new(None);
    let foreach_result = diff.foreach(
        &mut |delta, _| {
            let current_count = file_diffs.borrow().len();
            if current_count >= MAX_DIFF_FILES {
                is_truncated.set(true);
                if truncated_reason.borrow().is_none() {
                    *truncated_reason.borrow_mut() = Some(format!(
                        "Diff is too large to display completely. Showing at most {MAX_DIFF_FILES} files."
                    ));
                }
                return false;
            }

            let mut diffs = file_diffs.borrow_mut();
            diffs.push(FileDiff {
                old_path: delta
                    .old_file()
                    .path()
                    .map(|value| value.to_string_lossy().to_string()),
                new_path: delta
                    .new_file()
                    .path()
                    .map(|value| value.to_string_lossy().to_string()),
                status: map_delta_status(&delta),
                hunks: Vec::new(),
                is_binary: delta.flags().contains(git2::DiffFlags::BINARY),
            });
            current_file_index.set(Some(diffs.len().saturating_sub(1)));
            current_hunk_index.set(None);
            true
        },
        None,
        Some(&mut |_delta, hunk| {
            if let Some(file_idx) = current_file_index.get() {
                let mut diffs = file_diffs.borrow_mut();
                if let Some(file_diff) = diffs.get_mut(file_idx) {
                    file_diff.hunks.push(map_hunk(&hunk));
                    current_hunk_index.set(Some(file_diff.hunks.len().saturating_sub(1)));
                }
            }
            true
        }),
        Some(&mut |_delta, _hunk, line| {
            if displayed_line_count.get() >= MAX_DIFF_LINES {
                is_truncated.set(true);
                if truncated_reason.borrow().is_none() {
                    *truncated_reason.borrow_mut() = Some(format!(
                        "Diff is too large to display completely. Showing at most {MAX_DIFF_LINES} changed lines."
                    ));
                }
                return false;
            }

            if let (Some(file_idx), Some(hunk_idx)) =
                (current_file_index.get(), current_hunk_index.get())
            {
                let mut diffs = file_diffs.borrow_mut();
                if let Some(file_diff) = diffs.get_mut(file_idx)
                    && let Some(hunk) = file_diff.hunks.get_mut(hunk_idx)
                {
                    hunk.lines.push(map_line(&line));
                    displayed_line_count.set(displayed_line_count.get().saturating_add(1));
                }
            }
            true
        }),
    );
    if let Err(error) = foreach_result
        && error.code() != ErrorCode::User
    {
        return Err(error.into());
    }

    let file_diffs = file_diffs.into_inner();

    let parents = commit
        .parents()
        .map(|parent| parent.id().to_string())
        .collect::<Vec<_>>();
    Ok(CommitDetail {
        commit: commit_info,
        parents,
        stats: DiffStats {
            files_changed: stats.files_changed(),
            insertions: stats.insertions(),
            deletions: stats.deletions(),
        },
        displayed_file_count: file_diffs.len(),
        displayed_line_count: displayed_line_count.get(),
        diffs: file_diffs,
        is_truncated: is_truncated.get(),
        truncated_reason: truncated_reason.into_inner(),
    })
}

fn resolve_commit<'a>(repo: &'a Repository, ref_name: &str) -> Result<Commit<'a>, AppError> {
    let candidate_refs = [
        // Prefer remote-tracking refs so a recent fetch is reflected immediately.
        format!("refs/remotes/origin/{ref_name}"),
        format!("refs/heads/{ref_name}"),
        format!("refs/tags/{ref_name}"),
    ];

    for candidate in candidate_refs {
        if let Ok(object) = repo.revparse_single(&candidate)
            && let Ok(commit) = object.peel_to_commit()
        {
            return Ok(commit);
        }
    }

    // Fallback for explicit OIDs / revspec expressions (for example, `main~1`).
    if let Ok(object) = repo.revparse_single(ref_name)
        && let Ok(commit) = object.peel_to_commit()
    {
        return Ok(commit);
    }

    Err(AppError::NotFound(format!("ref '{ref_name}' not found")))
}

fn map_commit(commit: &Commit<'_>) -> CommitInfo {
    let hash = commit.id().to_string();
    let short_hash = hash.chars().take(8).collect::<String>();
    let message = commit.message().unwrap_or("").to_string();
    let message_short = commit
        .summary()
        .ok()
        .flatten()
        .map(|value| value.to_string())
        .unwrap_or_else(|| message.lines().next().unwrap_or("").to_string());
    let author = commit.author();
    let author_name = author.name().unwrap_or("Unknown").to_string();
    let author_email = author.email().unwrap_or("").to_string();
    let authored_at = timestamp_to_utc(author.when().seconds());

    CommitInfo {
        hash,
        short_hash,
        author_name,
        author_email,
        authored_at,
        message,
        message_short,
    }
}

fn map_delta_status(delta: &DiffDelta<'_>) -> String {
    delta_status_name(delta.status()).to_string()
}

fn map_hunk(hunk: &GitDiffHunk<'_>) -> DiffHunk {
    let header = String::from_utf8_lossy(hunk.header())
        .trim_end()
        .to_string();
    DiffHunk {
        header,
        lines: Vec::new(),
    }
}

fn map_line(line: &GitDiffLine<'_>) -> DiffLine {
    let old_lineno = line.old_lineno();
    let new_lineno = line.new_lineno();
    let content = String::from_utf8_lossy(line.content())
        .trim_end_matches('\n')
        .to_string();

    let line_type = line_origin_name(line.origin()).to_string();

    DiffLine {
        old_lineno,
        new_lineno,
        content,
        line_type,
    }
}

fn commit_touches_path(
    repo: &Repository,
    commit: &Commit<'_>,
    path: &str,
) -> Result<bool, AppError> {
    let tree = commit.tree()?;
    let parent_tree = if commit.parent_count() > 0 {
        Some(commit.parent(0)?.tree()?)
    } else {
        None
    };
    let mut options = DiffOptions::new();
    options.pathspec(path);
    let diff = repo.diff_tree_to_tree(parent_tree.as_ref(), Some(&tree), Some(&mut options))?;
    Ok(diff.deltas().len() > 0)
}

fn collect_language_bytes(
    repo: &Repository,
    tree: &git2::Tree<'_>,
    prefix: &str,
    totals: &mut HashMap<String, u64>,
    total_bytes: &mut u64,
) -> Result<(), AppError> {
    for entry in tree {
        let name = entry.name().unwrap_or_default();
        let full_path = if prefix.is_empty() {
            name.to_string()
        } else {
            format!("{prefix}/{name}")
        };

        match entry.kind() {
            Some(ObjectType::Tree) => {
                let nested = repo.find_tree(entry.id())?;
                collect_language_bytes(repo, &nested, &full_path, totals, total_bytes)?;
            }
            Some(ObjectType::Blob) => {
                let blob = repo.find_blob(entry.id())?;
                let bytes = blob.content();
                if looks_binary(bytes) {
                    continue;
                }

                let raw_language = detect_language(&full_path);
                let language = if raw_language == "text" {
                    "other".to_string()
                } else {
                    raw_language
                };
                let size = blob.size() as u64;
                if size == 0 {
                    continue;
                }

                *totals.entry(language).or_insert(0) += size;
                *total_bytes = total_bytes.saturating_add(size);
            }
            _ => {}
        }
    }

    Ok(())
}

fn looks_binary(data: &[u8]) -> bool {
    if data.is_empty() {
        return false;
    }

    if data.iter().take(8_192).any(|byte| *byte == 0) {
        return true;
    }

    std::str::from_utf8(data).is_err()
}

fn timestamp_to_utc(seconds: i64) -> DateTime<Utc> {
    if let Some(value) = DateTime::<Utc>::from_timestamp(seconds, 0) {
        return value;
    }
    Utc::now()
}

fn delta_status_name(status: git2::Delta) -> &'static str {
    match status {
        git2::Delta::Added => "added",
        git2::Delta::Deleted => "deleted",
        git2::Delta::Renamed => "renamed",
        _ => "modified",
    }
}

fn line_origin_name(origin: char) -> &'static str {
    match origin {
        '+' => "add",
        '-' => "delete",
        ' ' => "context",
        _ => "meta",
    }
}

#[cfg(test)]
mod tests {
    use chrono::Duration as ChronoDuration;

    use super::*;

    #[test]
    fn helper_mappers_cover_all_status_and_line_types() {
        assert_eq!(delta_status_name(git2::Delta::Added), "added");
        assert_eq!(delta_status_name(git2::Delta::Deleted), "deleted");
        assert_eq!(delta_status_name(git2::Delta::Renamed), "renamed");
        assert_eq!(delta_status_name(git2::Delta::Modified), "modified");

        assert_eq!(line_origin_name('+'), "add");
        assert_eq!(line_origin_name('-'), "delete");
        assert_eq!(line_origin_name(' '), "context");
        assert_eq!(line_origin_name('F'), "meta");
    }

    #[test]
    fn looks_binary_and_timestamp_helpers_cover_edge_cases() {
        assert!(!looks_binary(&[]));
        assert!(!looks_binary("hello".as_bytes()));
        assert!(looks_binary(&[0_u8, 1, 2]));
        assert!(looks_binary(&[0xFF_u8, 0xFE, 0xFD]));

        let normal = timestamp_to_utc(1_700_000_000);
        assert!(normal.timestamp() > 0);

        let fallback = timestamp_to_utc(i64::MAX);
        let now = Utc::now();
        let delta = now - fallback;
        assert!(delta < ChronoDuration::seconds(5));
        assert!(delta > ChronoDuration::seconds(-5));
    }
}

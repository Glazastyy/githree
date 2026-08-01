use std::path::Path;

use git2::Repository;

use crate::error::AppError;
use crate::git::RefsResponse;

pub fn list_refs(local_path: &Path) -> Result<RefsResponse, AppError> {
    let repo = Repository::open_bare(local_path)?;

    let mut branches: Vec<String> = repo
        .branches(Some(git2::BranchType::Local))?
        .filter_map(|entry| entry.ok())
        .filter_map(|(branch, _)| branch.name().ok().flatten().map(|value| value.to_string()))
        .collect();

    let mut remote_branches: Vec<String> = repo
        .branches(Some(git2::BranchType::Remote))?
        .filter_map(|entry| entry.ok())
        .filter_map(|(branch, _)| branch.name().ok().flatten().map(|value| value.to_string()))
        .filter_map(|value| {
            if value == "origin/HEAD" {
                return None;
            }
            value
                .strip_prefix("origin/")
                .map(|branch| branch.to_string())
        })
        .collect();
    branches.append(&mut remote_branches);

    branches.sort();
    branches.dedup();

    let mut tags = repo
        .tag_names(None)?
        .iter()
        .flatten()
        .flatten()
        .map(|tag| tag.to_string())
        .collect::<Vec<_>>();
    tags.sort();
    tags.dedup();

    let default_branch = repo
        .find_reference("refs/remotes/origin/HEAD")
        .ok()
        .and_then(|reference| {
            reference
                .symbolic_target()
                .ok()
                .flatten()
                .map(|value| value.to_string())
        })
        .and_then(|name| name.rsplit('/').next().map(|part| part.to_string()))
        .or_else(|| branches.first().cloned())
        .unwrap_or_else(|| "main".to_string());

    Ok(RefsResponse {
        branches,
        tags,
        default_branch,
    })
}

// SPDX-License-Identifier: GPL-2.0-only

//! Support for using git repository hooks.

use std::{
    borrow::Cow,
    io::Write,
    path::{Path, PathBuf},
};

use anyhow::{anyhow, Context, Result};
use bstr::BString;

use crate::wrap::Message;

/// Find path to hook script given a hook name.
///
/// Returns None if the hook script is not found or is not executable.
fn get_hook_path(repo: &gix::Repository, hook_name: &str) -> Result<Option<PathBuf>> {
    let config = repo.config_snapshot();
    let hooks_path =
        if let Some(core_hooks_path) = config.trusted_path("core.hookspath").transpose()? {
            if core_hooks_path.is_absolute() {
                core_hooks_path
            } else if repo.is_bare() {
                // The hooks path is relative to GIT_DIR in the case of a bare repo
                Cow::Owned(repo.common_dir().join(core_hooks_path))
            } else {
                // The hooks path is relative to the root of the working tree otherwise
                let work_dir = repo.workdir().expect("non-bare repo must have work dir");
                Cow::Owned(work_dir.join(core_hooks_path))
            }
        } else {
            // No core.hookspath, use default .git/hooks location
            Cow::Owned(repo.common_dir().join("hooks"))
        };
    let hook_path = hooks_path.join(hook_name);

    let hook_meta = match std::fs::metadata(&hook_path) {
        Ok(meta) => meta,
        Err(_) => return Ok(None), // ignore missing hook
    };

    if !is_executable(&hook_meta) {
        return Ok(None);
    }

    let hook_path = gix::path::realpath(hook_path)?;

    Ok(Some(hook_path))
}

/// Run the git `pre-commit` hook script.
///
/// The `use_editor` flag determines whether the hook should be allowed to invoke an
/// interactive editor.
///
/// Returns `Ok(true)` if the hook ran and completed successfully, `Err()` if the hook
/// ran but failed, and `Ok(false)` if the hook did not run due to the script not
/// existing, not being a file, or not being executable.
pub(crate) fn run_pre_commit_hook(repo: &gix::Repository, use_editor: bool) -> Result<bool> {
    let hook_name = "pre-commit";
    let hook_path = if let Some(hook_path) = get_hook_path(repo, hook_name)? {
        hook_path
    } else {
        return Ok(false);
    };

    let work_dir = repo.workdir().expect("not a bare repo");

    let mut hook_command = std::process::Command::from(
        gix::command::prepare(hook_path).stdout(std::process::Stdio::inherit()),
    );
    hook_command.current_dir(work_dir);
    if !use_editor {
        hook_command.env("GIT_EDITOR", ":");
    }

    let status = hook_command
        .status()
        .with_context(|| format!("`{hook_name}` hook"))?;

    if status.success() {
        Ok(true)
    } else {
        Err(anyhow!(
            "`{hook_name}` hook returned {}",
            status.code().unwrap_or(-1)
        ))
    }
}

/// Run the git `commit-msg` hook script.
///
/// The given commit message is written to a temporary file before invoking the
/// `commit-msg` script, and deleted after the script exits.
///
/// The `use_editor` flag determines whether the hook should be allowed to invoke an
/// interactive editor.
///
/// Returns successfully if the hook script does not exist, is not a file, or is not
/// executable.
pub(crate) fn run_commit_msg_hook<'repo>(
    repo: &gix::Repository,
    message: Message<'repo>,
    use_editor: bool,
) -> Result<Message<'repo>> {
    let hook_name = "commit-msg";
    let hook_path = if let Some(hook_path) = get_hook_path(repo, hook_name)? {
        hook_path
    } else {
        return Ok(message);
    };

    let work_dir = repo.workdir().expect("not a bare repo");
    let temp_msg = TemporaryMessage::new(work_dir, &message)?;

    let index_path = repo.index_path();

    // TODO: when git runs this hook, it only sets GIT_INDEX_FILE and sometimes
    // GIT_EDITOR. So author and committer vars are not clearly required.
    let mut hook_command = std::process::Command::from(
        gix::command::prepare(hook_path).stdout(std::process::Stdio::inherit()),
    );
    hook_command.current_dir(work_dir);
    hook_command.env("GIT_INDEX_FILE", &index_path);
    if !use_editor {
        hook_command.env("GIT_EDITOR", ":");
    }

    hook_command.arg(temp_msg.filename());

    let status = hook_command
        .status()
        .with_context(|| format!("`{hook_name}` hook"))?;

    if status.success() {
        let message_bytes = temp_msg.read()?;
        let encoding = message.encoding()?;
        let message = encoding
            .decode_without_bom_handling_and_without_replacement(&message_bytes)
            .ok_or_else(|| {
                anyhow!("message could not be decoded with `{}`", encoding.name())
                    .context("`{hook_name}` hook")
            })?;
        Ok(Message::from(message.to_string()))
    } else {
        Err(anyhow!(
            "`{hook_name}` hook returned {}",
            status.code().unwrap_or(-1)
        ))
    }
}

/// Temporary commit message file for commit-msg hook.
///
/// The temporary file is created relative to the work dir using the StGit process id to
/// avoid collisions with other StGit processes.
struct TemporaryMessage<'repo> {
    work_dir: &'repo Path,
    filename: PathBuf,
}

impl<'repo> TemporaryMessage<'repo> {
    /// Create new temporary file containing commit message.
    fn new(work_dir: &'repo Path, message: &Message<'repo>) -> Result<Self> {
        let pid = std::process::id();
        let filename = PathBuf::from(format!(".stgit-msg-temp-{pid}"));
        let msg_path = work_dir.join(&filename);
        let mut msg_file = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(msg_path)?;
        msg_file.write_all(message.raw_bytes())?;
        Ok(Self { work_dir, filename })
    }

    /// Get name of temporary message file.
    ///
    /// This is not a complete path. The temporary file is relative to the `work_dir`.
    fn filename(&self) -> &Path {
        self.filename.as_ref()
    }

    /// Read contents of temporary message file.
    fn read(&self) -> Result<BString> {
        Ok(std::fs::read(self.work_dir.join(&self.filename))?.into())
    }
}

impl Drop for TemporaryMessage<'_> {
    fn drop(&mut self) {
        let msg_path = self.work_dir.join(&self.filename);
        if msg_path.is_file() {
            if let Err(e) = std::fs::remove_file(&msg_path) {
                panic!("failed to remove temp message {msg_path:?}: {e}");
            }
        }
    }
}

#[cfg(unix)]
fn is_executable(meta: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    meta.mode() & 0o111 != 0
}

#[cfg(not(unix))]
fn is_executable(_meta: &std::fs::Metadata) -> bool {
    true
}

// SPDX-License-Identifier: GPL-2.0-only

//! `stg spill` implementation.

use anyhow::Result;
use clap::{Arg, ArgMatches};

use crate::{
    color::get_color_stdout,
    commit::{CommitExtended, RepositoryCommitExtended},
    index::TemporaryIndex,
    repo::RepositoryExtended,
    stack::{Error, Stack, StackStateAccess},
    stupid::Stupid,
};

pub(super) fn get_command() -> (&'static str, super::StGitCommand) {
    (
        "spill",
        super::StGitCommand {
            make,
            run,
            category: super::CommandCategory::PatchManipulation,
        },
    )
}

fn make() -> clap::Command<'static> {
    clap::Command::new("spill")
        .about("Spill changes from the topmost patch")
        .long_about(
            "Spill changes from the topmost patch. Changes are removed from the patch, \
             but remain in the index and worktree.\n\
             \n\
             Spilling a patch may be useful for reselecting the files/hunks to be \
             included in the patch.",
        )
        .arg(
            Arg::new("annotate")
                .long("annotate")
                .short('a')
                .help("Annotate the patch log entry with note")
                .takes_value(true)
                .value_name("note"),
        )
        .arg(
            Arg::new("reset")
                .long("reset")
                .short('r')
                .help("Also reset the index")
                .long_help(
                    "Also reset the index such that the patch's changes only remain \
                     in the worktree. Without this option, the patch's changes will \
                     be in both the index and worktree.",
                ),
        )
        .arg(
            Arg::new("pathspecs")
                .help("Only spill files matching path")
                .value_name("path")
                .multiple_values(true)
                .allow_invalid_utf8(true),
        )
}

fn run(matches: &ArgMatches) -> Result<()> {
    let repo = git2::Repository::open_from_env()?;
    let stack = Stack::from_branch(&repo, None)?;

    repo.check_repository_state()?;
    repo.check_conflicts()?;
    repo.check_index_clean()?;
    stack.check_head_top_mismatch()?;

    let patchname = stack
        .applied()
        .last()
        .ok_or(Error::NoAppliedPatches)?
        .clone();
    let patch_commit = stack.get_patch_commit(&patchname);
    let parent = patch_commit.parent(0)?;
    let mut index = repo.index()?;

    let tree_id = if let Some(pathspecs) = matches.values_of_os("pathspecs") {
        stack.repo.with_temp_index_file(|temp_index| {
            let stupid = repo.stupid();
            let stupid_temp = stupid.with_index_path(temp_index.path().unwrap());
            stupid_temp.read_tree(patch_commit.tree_id())?;
            stupid_temp.apply_pathlimited_treediff_to_index(
                patch_commit.tree_id(),
                parent.tree_id(),
                pathspecs,
            )?;
            stupid_temp.write_tree()
        })?
    } else {
        parent.tree_id()
    };

    let commit_id = repo.commit_ex(
        &patch_commit.author_strict()?,
        &patch_commit.committer_strict()?,
        &patch_commit.message_ex(),
        tree_id,
        patch_commit.parent_ids(),
    )?;

    let reflog_msg = if let Some(annotation) = matches.value_of("annotate") {
        format!("spill {patchname}\n\n{annotation}")
    } else {
        format!("spill {patchname}")
    };

    stack
        .setup_transaction()
        .use_index_and_worktree(false)
        .with_output_stream(get_color_stdout(matches))
        .transact(|trans| trans.update_patch(&patchname, commit_id))
        .execute(&reflog_msg)?;

    if matches.is_present("reset") {
        let tree = repo.find_tree(tree_id)?;
        index.read_tree(&tree)?;
        index.write()?;
    }

    Ok(())
}

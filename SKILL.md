---
name: agent-build
description: Delegate one approved bounded implementation task to a fresh visible Cursor CLI in a right-hand Cmux split, then independently review the repository changes and tests. Use only when the user explicitly asks Cursor to implement work or invokes `$agent-build`.
---

# Agent Build

Run one Cursor implementation while keeping requirements, review, and completion claims with the parent Codex.

## Prepare

- Require an approved repository-relative plan or a bounded implementation intent.
- Preserve unrelated work and follow every applicable ancestor, root, and nested repository instruction.
- Do not use this skill for review-only work or infer that the user wants Cursor.
- Run live launches with host access so the helper can reach Cmux and its private local state.
- Require the installed native lifecycle hooks in `~/.cursor/hooks.json`. Never add or alter global Cursor hooks during a delegated run; the helper fails before launch if either required hook is missing.

If hook readiness is not `ready`, preview the one-time merge:

```sh
ruby /Users/gaurav/.agents/skills/agent-build/scripts/agent_build.rb \
  --setup-hooks --dry-run
```

Show the user the exact target and merged JSON, explain that unrelated Cursor hooks are preserved, and obtain explicit approval for the global configuration write. Then run the same command without `--dry-run`. Never combine hook setup with external-service consent or a live launch.

From the delegated repository, inspect the exact launch first:

```sh
ruby /Users/gaurav/.agents/skills/agent-build/scripts/agent_build.rb \
  --intent "BOUNDED IMPLEMENTATION" \
  --dry-run
```

Use `--plan REPOSITORY_RELATIVE_PATH` instead of `--intent` for an approved plan. Verify the repository, executable and argv, sandbox and permission flags, inherited provider/model disclosure, ancestor/root/nested instruction paths, and unignored untracked paths.

## Obtain consent and launch

Before every live launch, show the exact `Disclosure:` line from the dry run. It names the repository and every applicable instruction file outside it:

> Cursor may send repository contents from REPOSITORY and applicable instructions to its configured external service and may consume paid usage. Applicable instruction files outside REPOSITORY: OUTSIDE_PATHS_OR_NONE. Its provider and model remain unresolved and inherited. `--force` plus Cursor's native sandbox is not a complete security boundary.

Do not reuse consent from an earlier run. After fresh explicit consent, launch:

```sh
ruby /Users/gaurav/.agents/skills/agent-build/scripts/agent_build.rb \
  --plan REPOSITORY_RELATIVE_PATH \
  --external-agent-consent
```

The helper opens one right-hand Cmux split and prints its run directory and exact surface. Cursor is interactive there: the user can watch, answer questions, interrupt, correct the active turn, and exit normally.

Keep the launcher as a long-running tool call. Two native global Cursor hooks activate only when `AGENT_BUILD_RUN_DIR` is present. They retain only the turn generation ID and lifecycle status, never the prompt, response, or transcript. The launcher waits silently for Cursor's completed-turn hook and returns while the TUI may remain open. The user does not need to exit Cursor for Codex to resume. If the tool yields a process handle, wait on that same process. Do not repeatedly inspect state, read the terminal, or ask the user to report completion.

An interrupted or aborted turn does not wake Codex; a corrected prompt returns the marker to running until that turn completes. After the launcher returns, do not submit another Cursor prompt because that invalidates the review boundary. The user may leave the final response visible and close Cursor normally after reading it.

Treat a completed-turn hook only as the review handoff. Treat process liveness only as evidence that Cursor may still be interactive. Treat process exit and exit code only as lifecycle evidence, never as proof that the implementation is correct.

## Review independently

After the launcher returns:

1. Read `run.json`, `state.json`, `pre.status`, and `pre.diff` in the printed run directory. Record the completed turn's generation ID; if the turn state is not `complete`, stop because the handoff was invalidated.
2. Compare the recorded starting HEAD and branch with the current repository; report any history or branch movement.
3. Compare the tracked snapshot and content-free untracked fingerprints with the current repository. If a pre-existing untracked file changed, state that exact line-level attribution is unavailable.
4. Inspect the changed files and their immediate callers or boundaries.
5. Rerun the smallest relevant checks independently.
6. Expand only when a material risk cannot otherwise be resolved.
7. Re-read `state.json`. If the turn is no longer `complete` with the same generation ID, discard the assessment because Cursor changed the review target.
8. Stop before applying fixes, committing, pushing, deploying, communicating externally, or taking another follow-up action.

Report:

```md
Cursor run:
- Terminal state: [the process may still be open after a completed turn]
- Exit outcome:
- History movement:
- Pre-existing untracked files changed:

My independent assessment:
- Actual change:
- Correctness and material risks:
- Test evidence:
- Missed or under-verified:

Verdict:
- Complete / needs follow-up / blocked

Recommended next step:
- Accept as complete / launch one fresh bounded Cursor follow-up / approve parent fixes
```

Never use a `Cursor reported` heading unless the user explicitly relays Cursor's response. A follow-up Cursor run requires a fresh bounded task and fresh external-service consent.

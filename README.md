# agent-build

A Codex skill that delegates one bounded implementation task to a fresh interactive Cursor CLI in a visible right-hand Cmux split, then has Codex review the actual repository changes independently.

## Requirements

- macOS
- Codex
- Cursor CLI, signed in and available as `agent`
- Cmux
- Git, Ruby, and zsh
- Permission for Codex to run the launcher with host access so it can use Cmux, Cursor, and private local state

Cursor inherits its configured provider and model. Each live launch requires a fresh disclosure and explicit consent because Cursor may send repository contents and applicable instructions to its external service and may consume paid usage.

## Install

Place this repository at:

```text
~/.agents/skills/agent-build
```

Codex discovers personal skills in `~/.agents/skills`. Restart Codex if the skill does not appear immediately.

The skill uses two native Cursor lifecycle hooks. Preview the one-time merge into `~/.cursor/hooks.json`:

```sh
ruby scripts/agent_build.rb --setup-hooks --dry-run
```

After reviewing the exact JSON and approving the global configuration change, install the hooks:

```sh
ruby scripts/agent_build.rb --setup-hooks
```

The setup preserves unrelated Cursor hook entries.

## Use

Ask Codex to run:

```text
$agent-build
```

Codex first shows a dry run with the exact Cursor command, repository, instructions, untracked paths, hook readiness, and external-service disclosure. After fresh consent, it opens Cursor in one right-hand Cmux split and waits locally for Cursor's completed-turn hook.

Cursor remains interactive: you can watch it, type, answer questions, interrupt it, and close it normally. Codex resumes when the completed-turn hook fires; Cursor may still be open so you can read its final response.

Codex then compares the recorded starting state with the repository, checks for history movement and changes to pre-existing untracked files, inspects the actual diff, and reruns focused checks. It stops before applying fixes, committing, pushing, or deploying.

The runner also accepts a bounded intent or repository-relative approved plan:

```sh
ruby scripts/agent_build.rb --help
```

## Check

```sh
ruby -c scripts/agent_build.rb
ruby test/agent_build_test.rb
```

MIT licensed.

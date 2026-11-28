# Agent rules (Tankard)

Read this before you edit, test, or push. [CLAUDE.md](CLAUDE.md) only points here.

## Push gate

A push is refused unless `Scripts/verify.sh` has stamped this exact HEAD on a clean tree. Run that script after you commit, and before you push or claim done. A Claude Code Stop hook (`.claude/settings.json`, `.githooks/claude-stop.sh`) also blocks "done" without a stamp.

Install the git hook in a worktree only (this does not change other worktrees or global git config):

    git config extensions.worktreeConfig true
    git config --worktree core.hooksPath .githooks

Emergency override (logs itself): `VERIFY_PUSH_OVERRIDE=<reason> git push ...`

## Review

Two review rounds, then stop and ask Derek. A must-fix finding needs evidence: a failing test, a repro command, or a cited code path.

## Tests

- Full local pass: `Scripts/verify.sh` (build, `Scripts/test.sh`, and a Swift 6.1 build when that toolchain is usable).
- Suite only: `Scripts/test.sh`.
- Any change to saving, persistence, or destructive brew actions needs fault-injection tests that a failed or interrupted write does not lose or invent data.

## Toolchain

Never run `xcode-select`. Honor `DEVELOPER_DIR` if it is set.

## Homebrew and defaults you must not touch

Never run Tankard against the real Homebrew on this Mac. Never launch a non-test Tankard.app pointed at the host's `brew`, and never change the host's Tankard defaults domain (`net.mindtricks.tankard`). Tests must use the test defaults suites that `Scripts/test.sh` cleans up.

## Language

US English in the UI, docs, comments, and commit messages.

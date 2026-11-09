# Ruby AI Software Factory

A Ruby orchestrator for taking structured development tasks through Codex implementation, verification, repair, and GitHub pull request review.

Task validation, subprocess execution, file-backed run logging, and Git worktree preparation are implemented. The CLI exposes validation and preparation. Agent execution, verification orchestration, retries, and PR publication are subsequent increments.

## Setup

Use Ruby 3.3 or later, below 4.0, and Bundler. The repository pins Ruby 3.3.0 for local development through `.ruby-version` and `.tool-versions`.

```sh
bundle install
bundle exec rspec
```

Validation uses Ruby standard libraries and needs no credentials, database, Codex installation, or GitHub CLI.

## Validate a task

```sh
cp examples/task.yml.sample examples/task.yml
# Edit examples/task.yml to set repository to your application's directory.
bin/factory validate examples/task.yml
```

Successful validation prints JSON with the absolute task path and normalized specification, including default limits. Invalid tasks produce an error on stderr. Exit codes are `0` for success, `1` for invalid or unreadable task files, and `2` for incorrect CLI usage.

Copy `examples/task.yml.sample` to `examples/task.yml`, set `repository` to your application's directory, and describe the change and acceptance criteria. Local files under `examples/` are ignored; `*.sample` files remain tracked for sharing.

## Task format

All fields in the example are required except `limits`. Omitting `limits` or individual limit fields supplies the defaults below. Unknown fields are rejected at every mapping level.

| Field | Contract |
| --- | --- |
| `version` | Integer `1`. |
| `id` | 1–64 lowercase letters, digits, or hyphens; starts with a letter or digit. |
| `repository` | Existing directory; relative paths resolve from the YAML file's directory. |
| `base_branch` | Nonblank string without a leading `-`. Git ref syntax and existence will be checked during worktree preparation. |
| `title`, `description` | Nonblank strings. |
| `acceptance_criteria` | Nonempty list of nonblank strings. |
| `verification` | Nonempty list of checks with unique names. |
| `verification[].name` | Nonblank string. |
| `verification[].command` | Nonempty argument array, such as `[bundle, exec, rspec]`. Shell command strings are rejected. |
| `verification[].timeout_seconds` | Integer from 1 to 86400. |
| `limits.max_repairs` | Integer from 0 to 10; default 2. Counts repairs after initial implementation. |
| `limits.agent_timeout_seconds` | Integer from 1 to 86400; default 1800. |

Strings cannot contain NUL bytes. YAML aliases, object deserialization, duplicate keys, and multiple documents are rejected. Validation checks the specification and directory existence; it does not check Git state, installed verification tools, or acceptance criteria satisfaction. No configured commands execute during validation.

Task files should come from trusted operators: future execution increments will run their configured commands. Worktrees will isolate changes but will not be a security boundary for host processes.

## Prepare an isolated worktree

Set `repository` in your task file to your application's Git repository root, with an existing local `base_branch`, then run:

```sh
bin/factory prepare examples/task.yml
```

This creates a unique `factory/<task-id>-<uuid>` branch and a worktree inside the run directory. JSON output includes the worktree path, resolved base SHA, branch, and `result.json` path. The run ends in `prepared`; it does not invoke Codex, run verification, commit, push, or open a PR.

Preparation uses the named local branch without fetching. Update that branch yourself before preparation if you need newer remote changes. Your original checkout's branch, HEAD, staged changes, and working files are preserved; uncommitted changes are not copied into the worktree. Git metadata is shared. Subdirectory paths, missing branches, and invalid branch names fail preparation with retained command logs. Git hooks and Git configuration still apply.

Each invocation creates a fresh run. Failed or interrupted preparation retains its planned workspace and artifacts when available, including any partial Git changes, for manual inspection. There is no automatic cleanup or resume yet. Exit status is `1` for preparation failures and `130` for interruption.

## Architecture and next increments

`TaskSpec` loads and validates immutable task data. `CLI` handles output and exit codes. `CommandRunner` executes subprocesses, and `RunStore` retains their inputs, output, and results. `GitWorkspace` prepares isolated checkouts and records `preparing`, `prepared`, `failed`, or `interrupted` outcomes.

### Subprocess execution and logs

The Ruby API can run individual commands without invoking an agent:

```ruby
require_relative "lib/factory"

task = Factory::TaskSpec.load("examples/task.yml")
store = Factory::RunStore.new(task: task)
runner = Factory::CommandRunner.new(store: store)
result = runner.call(["ruby", "--version"], chdir: task.to_h.fetch("repository"), timeout: 10)
puts result.fetch("state")
puts store.directory
```

Run artifacts default to `<repository-parent>/.factory/<repository-name>/<task-id>-<uuid>/`. `RunStore` also accepts `root:`; roots inside the target repository, including through symlinks, are rejected. Each private run directory contains the effective `task.yml`, an atomically replaced `result.json`, an append-only `events.jsonl`, and numbered command directories with `stdin.txt`, `stdout.log`, and `stderr.log`.

Commands execute directly from argument arrays, with no implicit shell. Output streams go directly to files to avoid retaining large output in memory. Results distinguish success, nonzero exit, spawn errors, signal termination, timeout, and interruption. Timeouts use a monotonic clock and terminate the process group with TERM followed by KILL after a short grace period. Remaining descendants in that group are terminated when their leader exits. Processes that deliberately create separate sessions can escape this group; this is process management, not a security sandbox.

Interruptions retain command results and re-raise `Interrupt`. Command failures return structured results so the future orchestrator can decide what to do. The run remains `pending` because task lifecycle transitions belong to the future `Runner`. Storage currently assumes a single writer; crash recovery, automatic resumption, and log rotation are deferred. Logs include command arguments, input, and unredacted output, so keep credentials out of task prompts and arguments and protect retained artifacts.

### Remaining increments

Build the remaining pieces in this order, with tests at each boundary:

1. `CodexAgent`: noninteractive implementation in the worktree with explicit sandbox settings.
2. `Verifier` and `Runner`: execute checks, bound repair attempts, and record explicit failure states.
3. `GitHubPublisher`: commit verified changes, push, and create a draft PR requiring human approval before merging.

The intended lifecycle is `pending → preparing → implementing → verifying → committing → publishing → awaiting_review`. Failed verification may enter `repairing` and return to `verifying` within the repair budget. Failures and interruptions retain artifacts for inspection. Local-only runs will stop after verification and commit.

Keep execution synchronous and single-agent initially. PostgreSQL, Sidekiq, resumability, and multiple agents remain future work.

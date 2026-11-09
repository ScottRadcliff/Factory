# Ruby AI Software Factory

A Ruby orchestrator for taking structured development tasks through Codex implementation, verification, repair, and GitHub pull request review.

Task validation, subprocess execution, file-backed run logging, Git worktree preparation, Codex implementation, independent verification, and bounded repairs are implemented. The CLI exposes `validate`, `prepare`, `implement`, and `run`. Commit and PR publication are the remaining milestone work.

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

All fields in the native example are required except `limits`. Omitting `limits` or individual limit fields supplies the defaults below. Verification cleanup fields are optional. Unknown fields are rejected at every mapping level.

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
| `verification[].cleanup` | Optional command argument array, run after the check even on failure, timeout, or interruption. |
| `verification[].cleanup_timeout_seconds` | Optional integer from 1 to 86400; default 60. Requires `cleanup`. |
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

## Implement a task with Codex

Install and authenticate Codex CLI on the machine running the factory. Check the executable and log in before starting:

```sh
codex --version
codex login
bin/factory implement examples/task.yml
```

This command creates a fresh worktree, sends the effective task specification and repository instructions to Codex, and leaves the resulting edits in that worktree for inspection. It does not reuse an earlier `prepare` run. The CLI prints the artifact directory to stderr before implementation starts and prints JSON results on success. Inspect the changes with `git -C <worktree-path> diff` and `git -C <worktree-path> status`.

The adapter uses [Codex noninteractive execution](https://learn.chatgpt.com/docs/non-interactive-mode) with `workspace-write`, `approval_policy="never"`, JSON events, and a captured final message. It inherits your configured model and authentication. The task's `limits.agent_timeout_seconds` bounds the process. The retained command stdin contains the full prompt; `agent-summary.txt` contains Codex's final summary.

The factory owns Git operations. It instructs Codex to work as one agent without committing, switching branches, pushing, or publishing, and checks the worktree's branch and HEAD afterward. These checks detect final Git state changes; they are not a security boundary or an audit of every command the agent ran. Existing Codex configuration, repository instructions, tools, and hooks still apply.

### Live status

`prepare` and `implement` print timestamped lifecycle updates to stderr. During implementation, supported Codex events show command activity, changed paths, and agent messages as they arrive. A heartbeat every 30 seconds confirms that the current command is still running, including when Codex emits no events. It indicates process activity, not proof that the task is making progress.

```text
[2026-11-09T10:42:01-05:00] Preparing worktree…
[2026-11-09T10:42:02-05:00] Worktree prepared
[2026-11-09T10:42:02-05:00] Implementing task with Codex…
[2026-11-09T10:42:08-05:00] Codex: running command: bundle exec rspec
[2026-11-09T10:42:19-05:00] Codex: changed app/models/user.rb
[2026-11-09T10:42:35-05:00] Implementation finished; verification pending
```

Updates are flushed immediately, including when redirected. Stdout remains a final JSON result, so you can save it while watching progress:

```sh
bin/factory implement examples/task.yml > /tmp/factory-result.json
```

Live messages are single lines truncated to 300 characters, with terminal control characters removed. Oversized event lines and malformed events are omitted from live display; complete raw output remains in command logs and is validated afterward. Unknown event types are ignored. Detailed command output is available in the retained logs rather than echoed to the terminal. Command text and agent messages can still contain sensitive information. A closed progress stream does not stop execution. Ruby API calls remain quiet by default; pass `progress: Factory::ProgressReporter.new` to `RunStore` to enable updates.

A successful process must also emit a completed turn and a nonblank summary. Missing executables, authentication failures, timeouts, failed turns, malformed event output, and changed branch/HEAD fail the run with retained logs. Unknown event types are tolerated. The `implement` command makes one agent call without repairs.

The `implement` command ends in `implemented`, with verification explicitly `pending`. This means agent execution completed, not that the task was fulfilled: read the summary for blockers and inspect the edits. Codex may run checks itself; use `run` for independent verification and repairs. Agent calls use your Codex account and may incur usage charges.

## Run implementation, verification, and repairs

```sh
bin/factory run examples/task.yml
```

This creates a fresh worktree, implements the task, and runs every configured verification command in YAML order from the worktree root. Each command has its own timeout and retained stdout/stderr logs. The full suite runs even when an earlier check fails. For native checks, ensure the target application's dependencies and test services are available before running. For Compose apps, see the Docker example below.

If checks fail, Codex receives their command metadata and the last 8 KiB of each failed stdout/stderr log, labeled as untrusted diagnostic data. Repairs run in the same worktree with distinct summaries and command logs. Every repair is followed by the full verification suite. `max_repairs: 2` permits one implementation and at most two repairs, for at most three verification cycles. Setting it to `0` disables repairs. Check timeouts and nonzero exits consume this budget; missing executables and other command-start failures stop immediately after the check suite. Agent failures stop immediately without infrastructure retries.

The factory checks branch and HEAD after each agent call and verification suite. Progress shows check outcomes and repair counts. `result.json` includes `verification_attempts` with ordered command results, `agent_attempts` with summaries for completed agent calls, and `repair_attempts`. Verification attempt `0` is the initial cycle. Interrupted suites retain completed checks with `complete: false`; command records retain additional details about the interrupted command.

Successful runs end in `verified` with `verification: passed`; failed runs record their stage (`verifying` or `repairing`) and error. Exit codes are `0` for verified runs, `1` for failures, and `130` for interruption. Artifacts and worktrees are retained in all cases. Each invocation starts a new run; resumption is not supported.

Passing configured checks does not prove all acceptance criteria are met. Verification commands execute trusted operator-supplied code directly on the host and may modify files. Human review is still required. This command does not commit, push, or create a PR yet.

### Docker Compose verification

For a Rails/Minitest application with `compose.yaml`, service `web`, and a relative `.:/app` bind mount, start with `examples/docker-task.yml.sample`. Copy it to a local task file and set the repository and task details. The sample runs dependency installation, test-database preparation, and `bin/rails test` inside a one-off container. It uses an explicit Compose file in the worktree and builds from that directory. Adapt the service, Compose filename, and test commands for other applications.

Verification `command` and `cleanup` arguments support the literal placeholder `{{run_id}}`, replaced with the current unique run ID without invoking a shell. The Docker sample uses `factory-{{run_id}}` as the project name in both commands. Relative source mounts resolve to the worktree. In the inspected application, project-scoped bundle and PostgreSQL volumes keep the factory's test environment separate from the normal development project. [Compose run](https://docs.docker.com/reference/cli/docker/compose/run/) starts one-off containers without publishing the service's normal ports.

The optional cleanup command runs after each check, including failed, timed-out, or interrupted checks, and has its own timeout and command logs. The sample uses [Compose down with `--volumes`](https://docs.docker.com/reference/cli/docker/compose/down/) for the same unique project, removing its containers and disposable test volumes after every attempt. Do not use this cleanup against your regular development project. Explicitly named/shared resources, external databases, external volumes, fixed host ports on dependencies, and absolute bind mounts require separate review; a project name alone does not isolate them.

Cleanup failures stop the run without asking Codex to repair them. `verification_attempts[].checks[].cleanup` retains the cleanup result. Cleanup is best effort: killing the factory process with SIGKILL, a second interruption during cleanup, or an unavailable Docker daemon can leave resources behind. Command logs include the expanded project name for manual cleanup. Build images and caches remain; the factory does not prune Docker resources globally.

Tests exercise cleanup and placeholder expansion without starting real containers. Compose configuration can be checked separately to confirm bind mounts and volume names before a live verification run.

## Architecture and next increments

`TaskSpec` loads and validates immutable task data. `CLI` handles output and exit codes. `CommandRunner` executes subprocesses, and `RunStore` retains their inputs, output, and results. `GitWorkspace` prepares isolated checkouts and checks their Git identity. `CodexAgent` builds implementation/repair prompts and validates agent output. `Verifier` executes configured checks; `Runner` coordinates preparation, implementation, verification, and bounded repairs, recording failure stages and interruption. Its Ruby API supports implementation only with `run`, or verification and repairs with `run(verify: true)`.

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

Interruptions retain command results and re-raise `Interrupt`. Command failures return structured results so the orchestrator can decide what to do. Using `CommandRunner` directly leaves the run `pending`; task lifecycle transitions belong to `Runner` and `GitWorkspace`. Storage currently assumes a single writer; crash recovery, automatic resumption, and log rotation are deferred. Logs include command arguments, input, and unredacted output, so keep credentials out of task prompts and arguments and protect retained artifacts.

### Remaining increments

Build the remaining pieces in this order, with tests at each boundary:

1. Commit verified changes, push, and create a draft PR through `GitHubPublisher`, requiring human approval before merging.

The intended lifecycle is `pending → preparing → implementing → verifying → committing → publishing → awaiting_review`. Failed verification may enter `repairing` and return to `verifying` within the repair budget. Failures and interruptions retain artifacts for inspection. Local-only runs will stop after verification and commit.

Keep execution synchronous and single-agent initially. PostgreSQL, Sidekiq, resumability, and multiple agents remain future work.

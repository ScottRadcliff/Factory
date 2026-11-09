# Ruby AI Software Factory

A Ruby orchestrator for taking structured development tasks through Codex implementation, verification, repair, and GitHub pull request review.

The first increment implements task validation only. Agent execution, worktrees, verification execution, retries, and PR publication are planned subsequent increments.

## Setup

Use Ruby 3.3 or later, below 4.0, and Bundler. The repository pins Ruby 3.3.0 for local development through `.ruby-version` and `.tool-versions`.

```sh
bundle install
bundle exec rspec
```

Validation uses Ruby standard libraries and needs no credentials, database, Codex installation, or GitHub CLI.

## Validate a task

```sh
bin/factory validate examples/task.yml
```

Successful validation prints JSON with the absolute task path and normalized specification, including default limits. Invalid tasks produce an error on stderr. Exit codes are `0` for success, `1` for invalid or unreadable task files, and `2` for incorrect CLI usage.

Copy `examples/task.yml`, set `repository` to your application's directory, and describe the change and acceptance criteria. The example points at this repository so it can be validated immediately.

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

## Architecture and next increments

`TaskSpec` loads and validates immutable task data. `CLI` handles output and exit codes. Tests cover the schema and actual CLI invocation.

Build the remaining pieces in this order, with tests at each boundary:

1. `CommandRunner` and `RunStore`: bounded subprocess execution, streamed logs, and atomic result snapshots outside target checkouts.
2. `GitWorkspace`: resolve a base commit and create a unique worktree and branch without changing the original checkout.
3. `CodexAgent`: noninteractive implementation in the worktree with explicit sandbox settings.
4. `Verifier` and `Runner`: execute checks, bound repair attempts, and record explicit failure states.
5. `GitHubPublisher`: commit verified changes, push, and create a draft PR requiring human approval before merging.

The intended lifecycle is `pending → preparing → implementing → verifying → committing → publishing → awaiting_review`. Failed verification may enter `repairing` and return to `verifying` within the repair budget. Failures and interruptions retain artifacts for inspection. Local-only runs will stop after verification and commit.

Keep execution synchronous and single-agent initially. PostgreSQL, Sidekiq, resumability, and multiple agents remain future work.

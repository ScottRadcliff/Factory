TASK ?= examples/task.yml
REMOTE ?= gh
REPO ?=
CLEAN_ENV = env -u GITHUB_TOKEN -u GH_TOKEN

.DEFAULT_GOAL := help
.PHONY: help login auth-check repo-check validate prepare implement run submit-local submit test

help:
	@echo "make login           Authenticate GitHub CLI through the browser"
	@echo "make auth-check      Check stored GitHub authentication"
	@echo "make repo-check REPO=owner/repo"
	@echo "                     Check access to a GitHub repository"
	@echo "make validate        Validate the task"
	@echo "make prepare         Create an isolated worktree"
	@echo "make implement       Implement without independent verification"
	@echo "make run             Implement, verify, and repair"
	@echo "make submit-local    Implement, verify, and commit locally"
	@echo "make submit          Implement, verify, commit, push, and open a draft PR"
	@echo "make test            Run the factory's RSpec suite"
	@echo "Overrides: TASK=path/to/task.yml REMOTE=origin (defaults: examples/task.yml, gh)"

login:
	$(CLEAN_ENV) gh auth login --hostname github.com --web

auth-check:
	$(CLEAN_ENV) gh auth status

repo-check:
	@test -n "$(REPO)" || { echo "Usage: make repo-check REPO=owner/repo" >&2; exit 2; }
	$(CLEAN_ENV) gh repo view "$(REPO)" --json url

validate:
	$(CLEAN_ENV) bin/factory validate "$(TASK)"

prepare:
	$(CLEAN_ENV) bin/factory prepare "$(TASK)"

implement:
	$(CLEAN_ENV) bin/factory implement "$(TASK)"

run:
	$(CLEAN_ENV) bin/factory run "$(TASK)"

submit-local:
	$(CLEAN_ENV) bin/factory submit --no-publish "$(TASK)"

submit:
	$(CLEAN_ENV) bin/factory submit --remote "$(REMOTE)" "$(TASK)"

test:
	bundle exec rspec

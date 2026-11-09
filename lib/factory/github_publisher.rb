require "json"
require "uri"

module Factory
  class PublicationError < StandardError; end

  class GitHubPublisher
    def initialize(task:, store:, command_runner: CommandRunner.new(store: store), executable: "gh")
      @task, @store, @commands, @executable = task.to_h, store, command_runner, executable
    end

    def preflight(workspace, remote: "origin")
      unless remote.is_a?(String) && remote.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/)
        raise PublicationError, "Remote must be a Git remote name"
      end
      url = output(["git", "remote", "get-url", "--push", remote], workspace).strip
      repository = output([@executable, "repo", "view", url, "--json", "url", "--jq", ".url"], workspace).strip
      uri = URI.parse(repository)
      unless uri.scheme == "https" && uri.host && uri.path.match?(%r{\A/[^/]+/[^/]+/?\z}) && !uri.userinfo && !uri.query && !uri.fragment
        raise PublicationError, "GitHub CLI returned an invalid repository URL"
      end
      output([@executable, "auth", "status", "--hostname", uri.host], workspace)
      output(["git", "ls-remote", "--exit-code", "--heads", url, "refs/heads/#{workspace.fetch('base_branch')}"], workspace)
      target = {"remote" => remote, "push_url" => url, "repository_url" => repository}
      @store.record_publication(target.merge("pushed" => false))
      target
    rescue URI::InvalidURIError => e
      raise PublicationError, "Invalid GitHub repository URL: #{e.message}"
    end

    def publish(workspace, target:)
      snapshot = @store.snapshot
      sha = snapshot.fetch("commit")
      unless snapshot["verification"] == "passed" && snapshot["state"] == "publishing"
        raise PublicationError, "Cannot publish an unverified run"
      end
      output(["git", "push", "--", target.fetch("push_url"), "#{sha}:refs/heads/#{workspace.fetch('branch')}"], workspace)
      # Save remote state before PR creation, which can fail independently.
      @store.record_publication("pushed" => true, "pushed_commit" => sha)
      existing = JSON.parse(output([@executable, "pr", "list", "--repo", target.fetch("repository_url"),
                                    "--head", workspace.fetch("branch"), "--base", workspace.fetch("base_branch"),
                                    "--state", "open", "--json", "url"], workspace))
      unless existing.is_a?(Array) && existing.length <= 1 && existing.all? { |pr| pr.is_a?(Hash) && pr["url"].is_a?(String) }
        raise PublicationError, "Unexpected PR lookup response; inspect the remote branch before retrying"
      end
      url = if existing.empty?
        body_path = File.join(@store.directory, "pr-body.md")
        File.write(body_path, body(snapshot), perm: 0o600)
        output([@executable, "pr", "create", "--draft", "--repo", target.fetch("repository_url"),
                "--base", workspace.fetch("base_branch"), "--head", workspace.fetch("branch"),
                "--title", @task.fetch("title"), "--body-file", body_path], workspace).strip
      else
        existing.first.fetch("url")
      end
      unless url.is_a?(String) && url.match?(%r{\A#{Regexp.escape(target.fetch('repository_url').delete_suffix('/'))}/pull/[0-9]+\z})
        raise PublicationError, "GitHub CLI returned an invalid pull request URL"
      end
      @store.record_publication("pull_request" => url)
      url
    rescue JSON::ParserError, KeyError, TypeError => e
      raise PublicationError, "Invalid publication response: #{e.message}"
    end

    private

    def output(argv, workspace)
      result = @commands.call(argv, chdir: workspace.fetch("path"), timeout: 120)
      unless result.fetch("success")
        raise PublicationError, "Publication command #{result.fetch('state')}: #{argv.first}; see #{result.fetch('stderr_path')}"
      end
      File.read(result.fetch("stdout_path"))
    end

    def body(snapshot)
      checks = snapshot.fetch("verification_attempts").last.fetch("checks")
      <<~BODY
        #{@task.fetch('description')}

        Acceptance criteria:
        #{@task.fetch('acceptance_criteria').map { |criterion| "- #{criterion}" }.join("\n")}

        Verification:
        #{checks.map { |check| "- #{check.fetch('name')}: passed" }.join("\n")}

        Repair attempts: #{snapshot.fetch('repair_attempts')}

        Human review and approval are required before merging. Passing checks do not establish that all acceptance criteria are met.
      BODY
    end
  end
end

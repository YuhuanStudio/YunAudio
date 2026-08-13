#!/usr/bin/ruby
# frozen_string_literal: true

# A structural check for the parts of the workflow where a typo can turn a
# safe CI job into hardware mutation or a supply-chain decision. This is not a
# replacement for GitHub's parser; it makes the local safety contract executable
# without adding a package-manager dependency to every runner image.
require "yaml"

path = File.expand_path("../.github/workflows/no-hardware-ci.yml", __dir__)
source = File.read(path, encoding: "UTF-8")
workflow = YAML.safe_load(source, permitted_classes: [], permitted_symbols: [], aliases: false)
abort("error: workflow is not a mapping") unless workflow.is_a?(Hash)

jobs = workflow["jobs"]
abort("error: workflow has no jobs") unless jobs.is_a?(Hash)
expected_jobs = %w[verify-matrix release-evidence sanitizers]
abort("error: expected jobs #{expected_jobs.join(', ')}") unless jobs.keys.sort == expected_jobs.sort

runner_variables = %w[
  YUNAUDIO_RUNNER_MACOS_26
  YUNAUDIO_RUNNER_MACOS_27
  YUNAUDIO_RUNNER_MACOS_BETA
  YUNAUDIO_RUNNER_RELEASE
  YUNAUDIO_RUNNER_SANITIZERS
]
runner_variables.each do |variable|
  abort("error: workflow does not expose #{variable}") unless source.include?(variable)
end
unless source.include?('["self-hosted","macOS","yunaudio-ci"')
  abort("error: default runner label sets must be explicitly self-hosted")
end

permissions = workflow["permissions"]
unless permissions == { "contents" => "read" }
  abort("error: the workflow token must have contents: read and nothing more")
end

if source.match?(/^\s*pull_request(?:_target)?:/)
  abort("error: untrusted pull-request code must never reach a self-hosted runner")
end

forbidden = Regexp.union(
  /YUNAUDIO_FLOWCHECK/,
  /--full/,
  /--install/,
  /\b(?:sudo|killall|launchctl)\b/,
  /coreaudiod/,
  /\byunaudio-cli\b/
)
required_stages = %w[inventory policy build test lint strings driver bundle release sanitizer]
observed_stages = []

jobs.each do |name, job|
  abort("error: #{name} is not a mapping") unless job.is_a?(Hash)
  timeout = job["timeout-minutes"]
  unless timeout.is_a?(Integer) && timeout.positive? && timeout <= 60
    abort("error: #{name} needs a positive timeout no longer than 60 minutes")
  end
  runner = job["runs-on"].to_s
  unless runner.include?("fromJSON")
    abort("error: #{name} must use a configurable JSON self-hosted runner label set")
  end

  steps = job["steps"]
  abort("error: #{name} has no steps") unless steps.is_a?(Array) && !steps.empty?
  checkout_seen = false
  steps.each do |step|
    abort("error: a step in #{name} is not a mapping") unless step.is_a?(Hash)
    abort("error: #{name} may not ignore a failed step") if step["continue-on-error"]

    if (uses = step["uses"])
      unless uses.match?(/\A[^@]+@[0-9a-f]{40}\z/)
        abort("error: #{name} action is not pinned to a full commit: #{uses}")
      end
      if uses.start_with?("actions/checkout@")
        checkout_seen = true
        inputs = step["with"] || {}
        unless inputs["clean"] == true && inputs["persist-credentials"] == false
          abort("error: #{name} checkout must clean and discard credentials")
        end
      end
    end

    command = step["run"]
    next unless command
    abort("error: forbidden hardware command in #{name}: #{command}") if command.match?(forbidden)
    if command.include?("${{ github.event")
      abort("error: untrusted event text is interpolated into a shell in #{name}")
    end
    match = command.match(%r{\A\./ci/no-hardware\.sh ([a-z]+)})
    abort("error: #{name} bypasses the no-hardware entry point: #{command}") unless match
    observed_stages << match[1]
  end
  abort("error: #{name} never checks out the requested revision") unless checkout_seen
end

missing = required_stages - observed_stages
abort("error: workflow never invokes stages: #{missing.join(', ')}") unless missing.empty?

puts "workflow policy: 3 bounded self-hosted jobs, read-only token, pinned actions"
puts "workflow policy: no pull-request trigger and no hardware-mutating command"

# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "pty"
require "rbconfig"
require "stringio"
require "tmpdir"
require_relative "../scripts/agent_build"

class AgentBuildTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/agent_build.rb", __dir__)
  WORKSPACE = "workspace:22222222-2222-4222-8222-222222222222"
  CALLER_SURFACE = "surface:33333333-3333-4333-8333-333333333333"
  NEW_SURFACE = "surface:11111111-1111-4111-8111-111111111111"

  def setup
    @temporary = Dir.mktmpdir("agent-build-test-")
    @repo = File.join(@temporary, "repo")
    @bin = File.join(@temporary, "bin")
    @state = File.join(@temporary, "state")
    @cmux_log = File.join(@temporary, "cmux.log")
    @cursor_log = File.join(@temporary, "cursor.log")
    @worker_log = File.join(@temporary, "worker.log")
    @background_pids = File.join(@temporary, "background.pids")
    @hooks = File.join(@temporary, "hooks.json")
    FileUtils.mkdir_p([@repo, @bin])
    git("init", "-q")
    File.write(File.join(@repo, "app.rb"), "puts :original\n")
    git("add", "app.rb")
    commit("initial")
    write_fake_cursor
    write_fake_cmux

    @saved_environment = ENV.to_h
    ENV["PATH"] = "#{@bin}#{File::PATH_SEPARATOR}#{@saved_environment.fetch('PATH', '')}"
    ENV["XDG_STATE_HOME"] = @state
    ENV["CMUX_WORKSPACE_ID"] = WORKSPACE
    ENV["CMUX_SURFACE_ID"] = CALLER_SURFACE
    ENV["AGENT_BUILD_TESTING"] = "1"
    ENV["AGENT_BUILD_CURSOR_HOOKS_PATH"] = @hooks
    ENV["AGENT_BUILD_TEST_STARTUP_TIMEOUT"] = "0.2"
    ENV["FAKE_CMUX_LOG"] = @cmux_log
    ENV["FAKE_CMUX_SCENARIO"] = "normal"
    ENV["FAKE_WORKER_LOG"] = @worker_log
    ENV["FAKE_BACKGROUND_PIDS"] = @background_pids
    ENV["FAKE_CURSOR_LOG"] = @cursor_log
    ENV["FAKE_CURSOR_MODE"] = "success"
    AgentBuild.write_json(@hooks, AgentBuild.expected_hook_config)
  end

  def teardown
    kill_recorded_processes
    ENV.replace(@saved_environment)
    FileUtils.remove_entry(@temporary) if File.exist?(@temporary)
  end

  def git(*arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", @repo, *arguments)
    raise "git failed: #{stderr}" unless status.success?

    stdout
  end

  def commit(message)
    git("-c", "user.name=Agent Build Test", "-c", "user.email=test@example.com", "commit", "-qm", message)
  end

  def write_executable(name, body)
    path = File.join(@bin, name)
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end

  def write_fake_cursor
    write_executable("agent", <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      require "open3"
      $stdout.sync = true
      File.open(ENV.fetch("FAKE_CURSOR_LOG"), "a") { |file| file.puts(JSON.generate("pid" => Process.pid, "argv" => ARGV)) }
      run_hook = lambda do |event, payload|
        hooks = JSON.parse(File.read(ENV.fetch("AGENT_BUILD_CURSOR_HOOKS_PATH")))
        hooks.fetch("hooks").fetch(event).each do |entry|
          _stdout, stderr, status = Open3.capture3("/bin/sh", "-c", entry.fetch("command"), stdin_data: JSON.generate(payload))
          abort("fake Cursor hook failed: #{stderr}") unless status.success?
        end
      end
      generation = "fake-generation-1"
      run_hook.call("beforeSubmitPrompt", "generation_id" => generation)
      complete = lambda do
        run_hook.call("stop", "generation_id" => generation, "status" => "completed", "loop_count" => 0)
      end
      mode = ENV.fetch("FAKE_CURSOR_MODE", "success")
      case mode
      when "success"
        complete.call
        exit 0
      when "fail"
        exit 7
      when "short"
        sleep 0.25
        complete.call
        exit 0
      when "sleep"
        %w[INT TERM HUP].each { |signal| trap(signal) { puts "cursor-interrupted-#{signal}"; exit 130 } }
        sleep 30
      when "turn_complete_open"
        %w[INT TERM HUP].each { |signal| trap(signal) { puts "cursor-interrupted-#{signal}"; exit 130 } }
        sleep 0.1
        complete.call
        sleep 30
      when "interactive"
        trap("INT") { puts "cursor-interrupted-INT"; exit 130 }
        puts "cursor-ready"
        while (line = $stdin.gets)
          value = line.strip
          puts "cursor-echo:#{value}"
          if value == "exit"
            complete.call
            exit 0
          end
        end
      else
        warn "unknown fake Cursor mode: #{mode}"
        exit 9
      end
    RUBY
  end

  def write_fake_cmux
    write_executable("cmux", <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      require "shellwords"
      File.open(ENV.fetch("FAKE_CMUX_LOG"), "a") { |file| file.puts(ARGV.shelljoin) }
      args = ARGV.dup
      args.shift if args.first == "--json"
      command = args.shift
      scenario = ENV.fetch("FAKE_CMUX_SCENARIO", "normal")
      case command
      when "ping"
        puts "PONG"
      when "new-split"
        if scenario == "split_failure"
          warn "fake split failure"
          exit 1
        end
        puts JSON.generate("result" => { "surface_ref" => "surface:11111111-1111-4111-8111-111111111111" })
      when "respawn-pane"
        worker = args.fetch(args.index("--command") + 1)
        if scenario == "submission_failure"
          warn "fake submission failure"
          exit 1
        end
        unless scenario == "no_start"
          environment = ENV.to_h.reject { |key, _value| key == "XDG_STATE_HOME" }
          pid = Process.spawn(environment, "/bin/sh", "-c", worker, out: ENV.fetch("FAKE_WORKER_LOG"), err: ENV.fetch("FAKE_WORKER_LOG"))
          File.open(ENV.fetch("FAKE_BACKGROUND_PIDS"), "a") { |file| file.puts(pid) }
        end
        puts "OK"
      when "close-surface"
        puts "OK"
      else
        warn "unknown fake cmux command: #{command}"
        exit 2
      end
    RUBY
  end

  def capture_main(*arguments)
    capture_main_from(@repo, *arguments)
  end

  def capture_main_from(directory, *arguments)
    code = nil
    output, error = capture_io { Dir.chdir(directory) { code = AgentBuild.main(arguments) } }
    [code, output, error]
  end

  def state_root
    File.join(@state, "agent-build")
  end

  def run_directories
    Dir.glob(File.join(state_root, "runs", "*")).select { |path| File.directory?(path) }.sort
  end

  def latest_run
    run_directories.last || raise("no run created")
  end

  def lock_directories
    Dir.glob(File.join(state_root, "locks", "*")).select { |path| File.directory?(path) }
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = yield
      return result if result
      raise "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.03
    end
  end

  def wait_for_state(run_dir, expected)
    wait_until { File.file?(File.join(run_dir, "state.json")) && AgentBuild.read_state(run_dir).fetch("state") == expected }
  end

  def recorded_cursor_pids
    return [] unless File.file?(@cursor_log)

    File.readlines(@cursor_log).map { |line| JSON.parse(line).fetch("pid") }
  end

  def kill_recorded_processes
    pids = recorded_cursor_pids
    if File.file?(@background_pids)
      pids.concat(File.readlines(@background_pids).map { |line| Integer(line.strip, 10) rescue nil }.compact)
    end
    pids.uniq.each do |pid|
      Process.kill("KILL", pid)
      Process.waitpid(pid, Process::WNOHANG)
    rescue Errno::ESRCH, Errno::ECHILD, Errno::EPERM
      nil
    end
  end

  def build_worker_run(command:)
    run_dir = AgentBuild.create_run
    AgentBuild.initialize_state(run_dir)
    token = "token-#{SecureRandom.hex(5)}"
    AgentBuild.acquire_reservation(@repo, run_dir, token)
    AgentBuild.write_json(
      File.join(run_dir, "run.json"),
      "repo" => @repo,
      "run_dir" => run_dir,
      "token" => token,
      "head" => AgentBuild.head_snapshot(@repo),
      "untracked" => [],
      "cursor" => { "executable" => command.first, "argv" => command },
      "cmux" => { "workspace" => WORKSPACE, "surface" => NEW_SURFACE }
    )
    run_dir
  end

  def pty_worker(run_dir)
    env = ENV.to_h
    reader, writer, pid = PTY.spawn(env, RbConfig.ruby, SCRIPT, "--worker", run_dir)
    [reader, writer, pid]
  end

  def read_until(io, pattern, timeout: 5)
    output = +""
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until output.include?(pattern)
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise "timed out waiting for #{pattern.inspect}; got #{output.inspect}" unless remaining.positive?
      next unless IO.select([io], nil, nil, remaining)

      output << io.readpartial(1024)
    end
    output
  rescue Errno::EIO
    raise "PTY closed before #{pattern.inspect}; got #{output.inspect}"
  end

  def test_missing_consent_blocks_before_local_state_or_cmux
    code, _output, error = capture_main("--intent", "Implement one change")

    assert_equal 1, code
    assert_includes error, "requires fresh explicit consent"
    refute File.exist?(state_root)
    refute File.exist?(@cmux_log)
  end

  def test_live_launch_requires_installed_native_hooks_before_creating_state
    File.delete(@hooks)

    code, _output, error = capture_main("--intent", "Implement one change", "--external-agent-consent")

    assert_equal 1, code
    assert_includes error, "Cursor hooks are not ready"
    assert_includes error, "--setup-hooks --dry-run"
    refute File.exist?(state_root)
    refute File.exist?(@cmux_log)
  end

  def test_dry_run_reports_missing_hooks_before_consent
    File.delete(@hooks)

    code, output, error = capture_main("--intent", "Implement one change", "--dry-run")

    assert_equal 0, code
    assert_empty error
    assert_includes output, "Hook readiness: not ready"
    assert_includes output, "run --setup-hooks --dry-run before requesting consent"
    refute File.exist?(@hooks)
  end

  def test_hook_setup_previews_and_idempotently_preserves_unrelated_entries
    unrelated = { "command" => "unrelated-hook" }
    existing = { "version" => 1, "hooks" => { "stop" => [unrelated], "afterAgentResponse" => [unrelated] } }
    AgentBuild.write_json(@hooks, existing)
    before = File.read(@hooks)

    code, output, error = capture_main("--setup-hooks", "--dry-run")
    assert_equal 0, code
    assert_empty error
    assert_includes output, "hook setup preview; no files changed"
    assert_equal before, File.read(@hooks)

    code, output, error = capture_main("--setup-hooks")
    assert_equal 0, code
    assert_empty error
    assert_includes output, "unrelated hook entries were preserved"
    merged = JSON.parse(File.read(@hooks))
    assert_equal [unrelated], merged.fetch("hooks").fetch("afterAgentResponse")
    assert_includes merged.fetch("hooks").fetch("stop"), unrelated
    AgentBuild.expected_hook_config.fetch("hooks").each do |event, expected|
      assert_equal 1, merged.fetch("hooks").fetch(event).count(expected.first)
    end
    assert_equal 0o600, File.stat(@hooks).mode & 0o777

    code, output, error = capture_main("--setup-hooks")
    assert_equal 0, code
    assert_empty error
    assert_includes output, "already ready; no file changed"
    assert_equal merged, JSON.parse(File.read(@hooks))
  end

  def test_hook_setup_fails_closed_on_malformed_existing_configuration
    File.write(@hooks, "not json\n")

    code, _output, error = capture_main("--setup-hooks", "--dry-run")

    assert_equal 1, code
    assert_includes error, "Malformed Cursor hook configuration"
    assert_equal "not json\n", File.read(@hooks)
  end

  def test_global_hook_config_is_minimal_and_noops_outside_agent_build
    config = AgentBuild.expected_hook_config

    assert_equal %w[beforeSubmitPrompt stop], config.fetch("hooks").keys.sort
    config.fetch("hooks").each_value do |entries|
      stdout, stderr, status = Open3.capture3("/bin/sh", "-c", entries.fetch(0).fetch("command"), unsetenv_others: true)
      assert status.success?
      assert_equal "{}\n", stdout
      assert_empty stderr
    end
  end

  def test_dry_run_is_cursor_only_and_retains_no_untracked_content
    File.write(File.join(@repo, "draft.txt"), "private-content\n")
    code, output, error = capture_main("--intent", "Implement one change", "--dry-run")

    assert_equal 0, code
    assert_empty error
    assert_includes output, "Agent: Cursor CLI"
    assert_includes output, "Executable: #{File.join(@bin, 'agent')}"
    assert_includes output, '"--force","--sandbox","enabled","--trust","--workspace"'
    refute_includes output, '"--plugin-dir"'
    assert_includes output, "Completion signal: native Cursor beforeSubmitPrompt/stop hooks"
    assert_includes output, "Hook readiness: ready"
    assert_includes output, "generation ID and lifecycle status only"
    assert_includes output, "Provider/model: unresolved and inherited from Cursor"
    assert_includes output, "may consume paid usage"
    assert_includes output, "draft.txt"
    refute_includes output, "private-content"
    refute File.exist?(state_root)
    refute File.exist?(@cmux_log)
  end

  def test_cursor_argv_is_fresh_interactive_and_has_no_forbidden_flags
    argv = AgentBuild.cursor_command("/bin/agent", @repo, "prompt")

    assert_equal ["/bin/agent", "--force", "--sandbox", "enabled", "--trust", "--workspace", @repo, "prompt"], argv
    %w[--model --resume --continue --worktree --print --provider --chat-id].each { |flag| refute_includes argv, flag }
  end

  def test_prompt_is_compact_and_lists_nested_instructions_without_diff_content
    ancestor = File.join(@temporary, "AGENTS.md")
    File.write(ancestor, "ancestor instructions\n")
    File.write(File.join(@repo, "AGENTS.md"), "root instructions\n")
    FileUtils.mkdir_p(File.join(@repo, "lib"))
    File.write(File.join(@repo, "lib", "CLAUDE.md"), "nested instructions\n")
    File.write(File.join(@repo, "app.rb"), "SECRET_DIFF_CONTENT\n")
    instructions = AgentBuild.instruction_paths(@repo)
    prompt = AgentBuild.worker_prompt(task: "Work", repo: @repo, status: AgentBuild.git(@repo, "status", "--short", "--"), instructions: instructions)
    disclosure = AgentBuild.disclosure(@repo, instructions)

    assert_includes instructions, ancestor
    assert_equal ["AGENTS.md", "lib/CLAUDE.md"], instructions.reject { |path| path.start_with?(File::SEPARATOR) }
    assert_includes prompt, ancestor
    assert_includes prompt, "lib/CLAUDE.md"
    assert_includes prompt, "Do not commit, push, deploy, mutate Git history"
    assert_includes prompt, "stop and ask one precise question"
    refute_includes prompt, "SECRET_DIFF_CONTENT"
    refute_includes prompt, "root instructions"
    assert_includes disclosure, "Applicable instruction files outside #{@repo}: #{ancestor}"
    refute_includes disclosure, File.join(@repo, "AGENTS.md")
  end

  def test_repository_relative_plan_resolves_from_repo_when_invoked_in_subdirectory
    FileUtils.mkdir_p([File.join(@repo, "docs"), File.join(@repo, "lib")])
    File.write(File.join(@repo, "docs", "plan.md"), "approved plan\n")

    code, output, error = capture_main_from(File.join(@repo, "lib"), "--plan", "docs/plan.md", "--dry-run")

    assert_equal 0, code
    assert_empty error
    assert_includes output, "Plan: docs/plan.md"
    assert_includes output, "Read and implement the complete approved plan at `docs/plan.md`."
  end

  def test_snapshot_records_exact_tracked_state_head_and_content_free_fingerprints
    original_head = git("rev-parse", "HEAD").strip
    original_ref = git("symbolic-ref", "HEAD").strip
    File.write(File.join(@repo, "app.rb"), "puts :staged\n")
    git("add", "app.rb")
    File.open(File.join(@repo, "app.rb"), "a") { |file| file.write("puts :unstaged\n") }
    File.write(File.join(@repo, "draft.txt"), "private draft\n")
    head = AgentBuild.head_snapshot(@repo)
    status, diff = AgentBuild.tracked_snapshot(@repo, head)
    fingerprints = AgentBuild.untracked_paths(@repo).map { |path| AgentBuild.fingerprint_path(@repo, path) }

    assert_equal original_head, head.fetch("oid")
    assert_equal original_ref, head.fetch("ref")
    assert_equal git("status", "--short", "--untracked-files=no", "--"), status
    assert_equal git("diff", "--binary", "--no-ext-diff", original_head, "--"), diff
    assert_equal ["draft.txt"], fingerprints.map { |item| item.fetch("path") }
    assert_equal Digest::SHA256.file(File.join(@repo, "draft.txt")).hexdigest, fingerprints.first.fetch("sha256")
    refute_includes JSON.generate(fingerprints), "private draft"
  end

  def test_unborn_head_and_history_movement_are_detected
    unborn = File.join(@temporary, "unborn")
    FileUtils.mkdir_p(unborn)
    Open3.capture3("git", "-C", unborn, "init", "-q")
    assert_equal "unborn", AgentBuild.head_snapshot(unborn).fetch("oid")

    metadata = { "repo" => @repo, "head" => AgentBuild.head_snapshot(@repo) }
    original_ref = metadata.fetch("head").fetch("ref")
    git("checkout", "-qb", "changed-branch")
    File.write(File.join(@repo, "next.txt"), "next\n")
    git("add", "next.txt")
    commit("history movement")
    movement = AgentBuild.history_movement(metadata)
    assert_includes movement, "#{original_ref} -> refs/heads/changed-branch"
    refute_equal "none", movement
  end

  def test_private_state_and_evidence_permissions
    code, _output, error = capture_main("--intent", "Work", "--external-agent-consent")
    run_dir = latest_run

    assert_equal 0, code
    assert_empty error
    assert_equal 0o700, File.stat(state_root).mode & 0o777
    assert_equal 0o700, File.stat(run_dir).mode & 0o777
    %w[run.json state.json pre.status pre.diff].each do |name|
      assert_equal 0o600, File.stat(File.join(run_dir, name)).mode & 0o777
    end
    assert_equal 0o600, File.stat(@hooks).mode & 0o777
  end

  def test_malformed_reservation_fails_closed
    run_dir = AgentBuild.create_run
    AgentBuild.initialize_state(run_dir)
    path = AgentBuild.reservation_path(@repo)
    Dir.mkdir(path, 0o700)
    File.write(File.join(path, "reservation.json"), "not json\n")

    assert_raises(AgentBuild::ReservationError) { AgentBuild.acquire_reservation(@repo, run_dir, "token") }
    assert File.directory?(path)
  end

  def test_spawn_right_and_startup_cancellation_are_one_atomic_transition
    cancelled_run = AgentBuild.create_run
    AgentBuild.initialize_state(cancelled_run)
    state, cancelled = AgentBuild.fail_unclaimed(cancelled_run, "cancelled")
    _state, claimed = AgentBuild.claim_spawn_right(cancelled_run)
    assert cancelled
    assert_equal "failed", state.fetch("state")
    refute claimed

    claimed_run = AgentBuild.create_run
    AgentBuild.initialize_state(claimed_run)
    state, claimed = AgentBuild.claim_spawn_right(claimed_run)
    _state, cancelled = AgentBuild.fail_unclaimed(claimed_run, "too late")
    assert claimed
    assert_equal "claimed", state.fetch("state")
    refute cancelled
  end

  def test_startup_timeout_cancels_before_cursor_can_spawn
    ENV["FAKE_CMUX_SCENARIO"] = "no_start"
    code, output, error = capture_main("--intent", "Work", "--external-agent-consent")

    assert_equal 1, code
    assert_empty error
    assert_includes output, "Terminal state: failed"
    assert_empty lock_directories
    refute File.exist?(@cursor_log)
  end

  def test_split_failure_releases_the_unstarted_reservation
    ENV["FAKE_CMUX_SCENARIO"] = "split_failure"
    code, _output, error = capture_main("--intent", "Work", "--external-agent-consent")

    assert_equal 1, code
    assert_includes error, "Cmux could not create the right-hand split"
    assert_equal "failed", AgentBuild.read_state(latest_run).fetch("state")
    assert_empty lock_directories
    refute File.exist?(@cursor_log)
  end

  def test_submission_failure_atomically_cancels_and_closes_the_split
    ENV["FAKE_CMUX_SCENARIO"] = "submission_failure"
    code, _output, error = capture_main("--intent", "Work", "--external-agent-consent")

    assert_equal 1, code
    assert_includes error, "Cmux could not submit the Cursor worker"
    assert_equal "failed", AgentBuild.read_state(latest_run).fetch("state")
    assert_includes File.read(@cmux_log), "close-surface"
    assert_empty lock_directories
    refute File.exist?(@cursor_log)
  end

  def test_launcher_wakes_on_completed_turn_without_waiting_for_cursor_exit
    ENV["FAKE_CURSOR_MODE"] = "turn_complete_open"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    code, output, error = capture_main("--intent", "Work", "--external-agent-consent")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    state = AgentBuild.read_state(latest_run)
    cursor_pid = recorded_cursor_pids.fetch(0)

    assert_equal 0, code
    assert_empty error
    assert_operator elapsed, :>=, 0.1
    assert_operator elapsed, :<, 5
    assert_operator output.index("Cursor launch submitted."), :<, output.index("Cursor turn completed")
    assert_equal "open", state.fetch("state")
    assert_equal "complete", AgentBuild.read_state(latest_run).dig("turn", "state")
    assert AgentBuild.process_alive?(cursor_pid)
    refute_empty lock_directories
    assert_includes output, "not exited; Cursor remains interactive"
    assert_includes output, "not proof that the implementation is correct"

    Process.kill("TERM", cursor_pid)
    wait_until { AgentBuild.read_state(latest_run).fetch("state") == "interrupted" }
    wait_until { lock_directories.empty? }
  end

  def test_dead_claimed_or_open_worker_wakes_parent_and_retains_reservation
    %w[claimed open].each do |worker_state|
      run_dir = AgentBuild.create_run
      AgentBuild.initialize_state(run_dir)
      token = "dead-worker-#{worker_state}"
      reservation = AgentBuild.acquire_reservation(@repo, run_dir, token)
      AgentBuild.update_state(run_dir) do |state|
        state["state"] = worker_state
        state["worker_pid"] = 999_999_999
        true
      end

      state = AgentBuild.wait_for_completion(run_dir, reservation, token, nil, nil, nil)

      assert_equal "recovery_required", state.fetch("state"), worker_state
      assert_equal false, state.fetch("outcome").fetch("cursor_termination_confirmed"), worker_state
      assert File.directory?(reservation), worker_state
      AgentBuild.update_state(run_dir) { |current| current["state"] = "failed"; true }
      assert AgentBuild.remove_owned_reservation(reservation, token), worker_state
    end
  end

  def test_hook_tracks_completed_aborted_and_reprompted_turns_without_transcript_content
    run_dir = AgentBuild.create_run
    AgentBuild.initialize_state(run_dir)
    original = ENV["AGENT_BUILD_RUN_DIR"]
    ENV["AGENT_BUILD_RUN_DIR"] = run_dir

    AgentBuild.cursor_hook_main(
      "beforeSubmitPrompt",
      input: StringIO.new(JSON.generate("generation_id" => "one", "prompt" => "private prompt")),
      output: StringIO.new
    )
    assert_equal "running", AgentBuild.read_state(run_dir).dig("turn", "state")

    AgentBuild.cursor_hook_main(
      "stop",
      input: StringIO.new(JSON.generate("generation_id" => "one", "status" => "aborted", "loop_count" => 0,
                                          "transcript_path" => "/private/transcript")),
      output: StringIO.new
    )
    assert_equal "aborted", AgentBuild.read_state(run_dir).dig("turn", "state")

    AgentBuild.cursor_hook_main(
      "beforeSubmitPrompt",
      input: StringIO.new(JSON.generate("generation_id" => "two", "prompt" => "another private prompt")),
      output: StringIO.new
    )
    AgentBuild.cursor_hook_main(
      "stop",
      input: StringIO.new(JSON.generate("generation_id" => "two", "status" => "completed", "loop_count" => 0,
                                          "transcript_path" => "/private/transcript")),
      output: StringIO.new
    )
    turn = AgentBuild.read_state(run_dir).fetch("turn")
    assert_equal "complete", turn.fetch("state")
    assert_equal "two", turn.fetch("generation_id")
    refute_includes JSON.generate(turn), "private prompt"
    refute_includes JSON.generate(turn), "transcript"
  ensure
    ENV["AGENT_BUILD_RUN_DIR"] = original
  end

  def test_nonzero_cursor_exit_is_lifecycle_evidence_not_wrapper_failure
    ENV["FAKE_CURSOR_MODE"] = "fail"
    code, output, error = capture_main("--intent", "Work", "--external-agent-consent")
    state = AgentBuild.read_state(latest_run)

    assert_equal 1, code
    assert_empty error
    assert_equal "exited", state.fetch("state")
    assert_equal 7, state.fetch("outcome").fetch("exit_code")
    assert_includes output, "Exit outcome: exit 7"
    assert_empty lock_directories
  end

  def test_interactive_cursor_reads_and_echoes_input_in_foreground_pty
    ENV["FAKE_CURSOR_MODE"] = "interactive"
    command = AgentBuild.cursor_command(File.join(@bin, "agent"), @repo, "prompt")
    run_dir = build_worker_run(command: command)
    reader, writer, pid = pty_worker(run_dir)

    read_until(reader, "cursor-ready")
    writer.write("hello\n")
    read_until(reader, "cursor-echo:hello")
    writer.write("exit\n")
    Process.waitpid(pid)

    assert_equal "exited", AgentBuild.read_state(run_dir).fetch("state")
    assert_empty lock_directories
  ensure
    reader&.close rescue nil
    writer&.close rescue nil
  end

  def test_ctrl_c_interrupts_interactive_cursor_and_releases_reservation
    ENV["FAKE_CURSOR_MODE"] = "interactive"
    command = AgentBuild.cursor_command(File.join(@bin, "agent"), @repo, "prompt")
    run_dir = build_worker_run(command: command)
    reader, writer, pid = pty_worker(run_dir)

    read_until(reader, "cursor-ready")
    writer.write("\u0003")
    Process.waitpid(pid)

    assert_equal "interrupted", AgentBuild.read_state(run_dir).fetch("state")
    assert_empty lock_directories
  ensure
    reader&.close rescue nil
    writer&.close rescue nil
  end

  def test_term_and_hup_are_forwarded_without_releasing_early
    %w[TERM HUP].each do |signal|
      ENV["FAKE_CURSOR_MODE"] = "sleep"
      command = AgentBuild.cursor_command(File.join(@bin, "agent"), @repo, "prompt")
      run_dir = build_worker_run(command: command)
      reader, writer, pid = pty_worker(run_dir)
      wait_for_state(run_dir, "open")
      Process.kill(signal, pid)
      Process.waitpid(pid)
      assert_equal "interrupted", AgentBuild.read_state(run_dir).fetch("state"), signal
      assert_empty lock_directories
      reader.close rescue nil
      writer.close rescue nil
    end
  end

  def test_bookkeeping_failure_after_spawn_terminates_child_before_release
    ENV["FAKE_CURSOR_MODE"] = "sleep"
    ENV["AGENT_BUILD_TEST_FAIL_AFTER_SPAWN"] = "1"
    code, output, _error = capture_main("--intent", "Work", "--external-agent-consent")
    state = AgentBuild.read_state(latest_run)
    cursor_pid = state.fetch("cursor_pid")

    assert_equal 1, code
    assert_includes output, "Terminal state: failed"
    assert_equal true, state.fetch("outcome").fetch("cursor_termination_confirmed")
    refute AgentBuild.process_alive?(cursor_pid)
    assert_empty lock_directories
  end

  def test_unconfirmed_child_survival_retains_reservation_and_blocks_next_run
    ENV["FAKE_CURSOR_MODE"] = "sleep"
    ENV["AGENT_BUILD_TEST_FAIL_AFTER_SPAWN"] = "1"
    ENV["AGENT_BUILD_TEST_CLEANUP_FAIL"] = "1"
    code, output, _error = capture_main("--intent", "Work", "--external-agent-consent")
    state = AgentBuild.read_state(latest_run)
    cursor_pid = state.fetch("cursor_pid")

    assert_equal 1, code
    assert_equal "recovery_required", state.fetch("state")
    assert_includes output, "Terminal state: recovery_required"
    assert AgentBuild.process_alive?(cursor_pid)
    refute_empty lock_directories

    second_code, _output, error = capture_main("--intent", "Another", "--external-agent-consent")
    assert_equal 1, second_code
    assert_includes error, "owns this repository"
    assert AgentBuild.process_alive?(cursor_pid)
  end

  def test_run_metadata_records_head_evidence_command_and_exact_cmux_target
    code, _output, error = capture_main("--intent", "Work", "--external-agent-consent")
    run_dir = latest_run
    metadata = AgentBuild.read_json(File.join(run_dir, "run.json"), "run metadata")

    assert_equal 0, code
    assert_empty error
    assert_equal git("rev-parse", "HEAD").strip, metadata.fetch("head").fetch("oid")
    assert_equal File.join(@bin, "agent"), metadata.fetch("cursor").fetch("executable")
    assert_equal WORKSPACE, metadata.fetch("cmux").fetch("workspace")
    assert_equal CALLER_SURFACE, metadata.fetch("cmux").fetch("caller_surface")
    assert_equal NEW_SURFACE, metadata.fetch("cmux").fetch("surface")
    assert File.file?(File.join(run_dir, "pre.status"))
    assert File.file?(File.join(run_dir, "pre.diff"))
  end

  def test_changed_preexisting_untracked_file_is_reported_without_line_attribution
    File.write(File.join(@repo, "draft.txt"), "before\n")
    ENV["FAKE_CURSOR_MODE"] = "short"
    changer = Thread.new do
      wait_until { File.file?(@cursor_log) }
      File.write(File.join(@repo, "draft.txt"), "after\n")
    end
    code, output, error = capture_main("--intent", "Work", "--external-agent-consent")
    changer.join

    assert_equal 0, code
    assert_empty error
    assert_includes output, "Pre-existing untracked files changed: draft.txt"
    assert_includes output, "Exact line-level attribution is unavailable"
  end
end

# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
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
    @ghostty_log = File.join(@temporary, "ghostty.log")
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
    write_fake_osascript

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
    ENV["FAKE_GHOSTTY_LOG"] = @ghostty_log
    ENV["FAKE_GHOSTTY_SCENARIO"] = "normal"
    ENV["FAKE_AGENT_BUILD_SCRIPT"] = SCRIPT
    ENV["FAKE_WORKER_LOG"] = @worker_log
    ENV["FAKE_BACKGROUND_PIDS"] = @background_pids
    ENV["FAKE_CURSOR_LOG"] = @cursor_log
    ENV["FAKE_CURSOR_MODE"] = "success"
    ENV.delete("TERM_PROGRAM")
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
      case ENV.fetch("FAKE_CURSOR_MODE", "success")
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
        %w[INT TERM HUP].each { |signal| trap(signal) { exit 130 } }
        sleep 30
      when "turn_complete_open"
        %w[INT TERM HUP].each { |signal| trap(signal) { exit 130 } }
        sleep 0.1
        complete.call
        sleep 30
      else
        warn "unknown fake Cursor mode"
        exit 9
      end
    RUBY
  end

  def write_fake_cmux
    write_executable("cmux", <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      require "open3"
      require "rbconfig"
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
      when "send"
        puts "OK"
      when "send-key"
        if scenario == "followup_no_start"
          puts "OK"
          exit 0
        end
        run_dir = Dir.glob(File.join(ENV.fetch("XDG_STATE_HOME"), "agent-build", "runs", "*")).max
        environment = ENV.to_h.merge("AGENT_BUILD_RUN_DIR" => run_dir)
        %w[beforeSubmitPrompt stop].each do |event|
          payload = event == "beforeSubmitPrompt" ? { "generation_id" => "fake-generation-2" } : { "generation_id" => "fake-generation-2", "status" => "completed", "loop_count" => 0 }
          _stdout, stderr, status = Open3.capture3(
            environment, RbConfig.ruby, ENV.fetch("FAKE_AGENT_BUILD_SCRIPT"), "--cursor-hook", event,
            stdin_data: JSON.generate(payload)
          )
          abort("fake continuation hook failed: #{stderr}") unless status.success?
        end
        puts "OK"
      else
        warn "unknown fake cmux command: #{command}"
        exit 2
      end
    RUBY
  end

  def write_fake_osascript
    write_executable("osascript", <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      require "rbconfig"
      script = $stdin.read
      File.open(ENV.fetch("FAKE_GHOSTTY_LOG"), "a") { |file| file.puts(JSON.generate("argv" => ARGV, "script" => script)) }
      if ARGV == ["-e", 'id of application "Ghostty"']
        if ENV.fetch("FAKE_GHOSTTY_SCENARIO", "normal") == "unavailable"
          warn "Ghostty is not installed"
          exit 1
        end
        puts "com.mitchellh.ghostty"
        exit 0
      end
      environment = ENV.to_h.reject { |key, _value| key == "XDG_STATE_HOME" }
      run_dir = Dir.glob(File.join(ENV.fetch("XDG_STATE_HOME"), "agent-build", "runs", "*")).max
      command = ["env", "XDG_STATE_HOME=#{ENV.fetch('XDG_STATE_HOME')}", RbConfig.ruby,
                 ENV.fetch("FAKE_AGENT_BUILD_SCRIPT"), "--worker", run_dir]
      pid = Process.spawn(environment, *command, out: ENV.fetch("FAKE_WORKER_LOG"), err: ENV.fetch("FAKE_WORKER_LOG"))
      File.open(ENV.fetch("FAKE_BACKGROUND_PIDS"), "a") { |file| file.puts(pid) }
      puts "tab:44444444-4444-4444-8444-444444444444"
      puts "terminal:55555555-5555-4555-8555-555555555555"
    RUBY
  end

  def use_ghostty
    ENV.delete("CMUX_WORKSPACE_ID")
    ENV.delete("CMUX_SURFACE_ID")
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

  def test_live_launch_fails_closed_without_consent_or_hooks
    code, _output, error = capture_main("--intent", "Implement one change")
    assert_equal 1, code
    assert_includes error, "requires fresh explicit consent"
    refute File.exist?(state_root)

    File.delete(@hooks)
    code, _output, error = capture_main("--intent", "Implement one change", "--external-agent-consent")
    assert_equal 1, code
    assert_includes error, "Cursor hooks are not ready"
    refute File.exist?(state_root)
    refute File.exist?(@cmux_log)
  end

  def test_hook_setup_previews_and_preserves_unrelated_entries
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
    merged = JSON.parse(File.read(@hooks))
    assert_equal [unrelated], merged.fetch("hooks").fetch("afterAgentResponse")
    assert_includes merged.fetch("hooks").fetch("stop"), unrelated
    AgentBuild.expected_hook_config.fetch("hooks").each do |event, expected|
      assert_equal 1, merged.fetch("hooks").fetch(event).count(expected.first)
    end

    code, output, error = capture_main("--setup-hooks")
    assert_equal 0, code
    assert_empty error
    assert_includes output, "already ready; no file changed"
    assert_equal merged, JSON.parse(File.read(@hooks))
  end

  def test_hook_setup_fails_closed_on_malformed_configuration
    File.write(@hooks, "not json\n")

    code, _output, error = capture_main("--setup-hooks", "--dry-run")

    assert_equal 1, code
    assert_includes error, "Malformed Cursor hook configuration"
    assert_equal "not json\n", File.read(@hooks)
  end

  def test_hooks_noop_outside_agent_build
    AgentBuild.expected_hook_config.fetch("hooks").each_value do |entries|
      stdout, stderr, status = Open3.capture3("/bin/sh", "-c", entries.fetch(0).fetch("command"), unsetenv_others: true)
      assert status.success?
      assert_equal "{}\n", stdout
      assert_empty stderr
    end
  end

  def test_dry_run_has_no_side_effects
    File.write(File.join(@repo, "draft.txt"), "private-content\n")
    File.delete(@hooks)

    code, output, error = capture_main("--intent", "Implement one change", "--dry-run")
    assert_equal 0, code
    assert_empty error
    assert_includes output, "Hook readiness: not ready"
    assert_includes output, '"--force","--sandbox","enabled","--trust","--workspace"'
    assert_includes output, "Current viewer: Cmux right split"
    assert_includes output, "draft.txt"
    refute_includes output, "private-content"
    refute File.exist?(state_root)
    refute File.exist?(@cmux_log)

    AgentBuild.write_json(@hooks, AgentBuild.expected_hook_config)
    use_ghostty
    ENV["FAKE_GHOSTTY_SCENARIO"] = "unavailable"
    code, output, error = capture_main("--intent", "Implement one change", "--dry-run")
    assert_equal 0, code
    assert_empty error
    assert_includes output, "Current viewer: Ghostty tab"
    refute File.exist?(@ghostty_log)

    ENV["TERM_PROGRAM"] = "ghostty"
    code, output, error = capture_main("--intent", "Implement one change", "--dry-run")
    assert_equal 0, code
    assert_empty error
    assert_includes output, "Current viewer: Ghostty right split"
    refute File.exist?(@ghostty_log)
  end

  def test_live_cmux_launch_wakes_on_completed_turn
    ENV["FAKE_CURSOR_MODE"] = "turn_complete_open"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    code, output, error = capture_main("--intent", "Work", "--external-agent-consent")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    run_dir = latest_run
    metadata = AgentBuild.read_json(File.join(run_dir, "run.json"), "run metadata")
    state = AgentBuild.read_state(run_dir)
    cursor_pid = recorded_cursor_pids.fetch(0)

    assert_equal 0, code
    assert_empty error
    assert_operator elapsed, :<, 5
    assert_operator output.index("Cursor launch submitted."), :<, output.index("Cursor turn completed")
    assert_equal "open", state.fetch("state")
    assert_equal "complete", state.dig("turn", "state")
    assert_equal "cmux", metadata.fetch("viewer").fetch("type")
    assert_equal NEW_SURFACE, metadata.fetch("viewer").fetch("surface")
    assert File.file?(File.join(run_dir, "pre.status"))
    assert File.file?(File.join(run_dir, "pre.diff"))
    assert_equal 0o700, File.stat(run_dir).mode & 0o777
    assert AgentBuild.process_alive?(cursor_pid)
    refute_empty lock_directories

    Process.kill("TERM", cursor_pid)
    wait_until { AgentBuild.read_state(run_dir).fetch("state") == "interrupted" }
    wait_until { lock_directories.empty? }
  end

  def test_live_ghostty_launch_opens_a_tab
    use_ghostty

    code, output, error = capture_main("--intent", "Work", "--external-agent-consent")
    metadata = AgentBuild.read_json(File.join(latest_run, "run.json"), "run metadata")

    assert_equal 0, code, "stdout:\n#{output}\nstderr:\n#{error}"
    assert_empty error
    assert_equal "ghostty", metadata.fetch("viewer").fetch("type")
    assert_equal "tab", metadata.fetch("viewer").fetch("placement")
    assert_equal "tab:44444444-4444-4444-8444-444444444444", metadata.fetch("viewer").fetch("tab")
    assert_equal "terminal:55555555-5555-4555-8555-555555555555", metadata.fetch("viewer").fetch("terminal")
    assert_includes File.read(@ghostty_log), "new tab in front window"
    refute_includes File.read(@ghostty_log), "split currentTerm direction right"
    refute File.exist?(@cmux_log)
  end

  def test_live_ghostty_launch_from_ghostty_opens_a_right_split
    use_ghostty
    ENV["TERM_PROGRAM"] = "ghostty"

    code, output, error = capture_main("--intent", "Work", "--external-agent-consent")
    metadata = AgentBuild.read_json(File.join(latest_run, "run.json"), "run metadata")

    assert_equal 0, code, "stdout:\n#{output}\nstderr:\n#{error}"
    assert_empty error
    assert_equal "split", metadata.fetch("viewer").fetch("placement")
    assert_includes output, "Viewer: Ghostty right split"
    ghostty_log = File.read(@ghostty_log)
    assert_includes ghostty_log, "split currentTerm direction right"
    refute_includes ghostty_log, "new tab in front window"
    refute File.exist?(@cmux_log)
  end

  def test_missing_ghostty_fails_before_creating_state
    use_ghostty
    ENV["FAKE_GHOSTTY_SCENARIO"] = "unavailable"

    code, _output, error = capture_main("--intent", "Work", "--external-agent-consent")

    assert_equal 1, code
    assert_includes error, "Ghostty is unavailable"
    refute File.exist?(state_root)
    refute File.exist?(@cursor_log)
  end

  def test_continuation_reuses_the_open_session
    ENV["FAKE_CURSOR_MODE"] = "turn_complete_open"
    first_code, _first_output, first_error = capture_main("--intent", "Initial", "--external-agent-consent")
    run_dir = latest_run
    File.write(File.join(@repo, "app.rb"), "puts :reviewed_baseline\n")
    cursor_count = File.readlines(@cursor_log).length

    dry_code, dry_output, dry_error = capture_main(
      "--intent", "Fix one reviewed defect", "--continue-run", run_dir, "--dry-run"
    )
    assert_equal 0, first_code
    assert_empty first_error
    assert_equal 0, dry_code
    assert_empty dry_error
    assert_includes dry_output, "Mode: continuation dry run"
    refute File.exist?(File.join(run_dir, "continuations"))

    code, output, error = capture_main(
      "--intent", "Fix one reviewed defect", "--continue-run", run_dir, "--external-agent-consent"
    )
    evidence = Dir.glob(File.join(run_dir, "continuations", "*")).fetch(0)
    metadata = AgentBuild.read_json(File.join(evidence, "run.json"), "continuation metadata")

    assert_equal 0, code, "stdout:\n#{output}\nstderr:\n#{error}"
    assert_empty error
    assert_equal "fake-generation-2", AgentBuild.read_state(run_dir).dig("turn", "generation_id")
    assert_equal "fake-generation-1", metadata.fetch("previous_generation_id")
    assert_includes File.read(File.join(evidence, "pre.diff")), "reviewed_baseline"
    assert_equal cursor_count, File.readlines(@cursor_log).length
    cmux_log = File.read(@cmux_log)
    assert_includes cmux_log, "send --workspace #{WORKSPACE} --surface #{NEW_SURFACE}"
    assert_includes cmux_log, "send-key --workspace #{WORKSPACE} --surface #{NEW_SURFACE} enter"
    refute_includes AgentBuild.continuation_prompt("Fix one\nreviewed defect"), "\n"
  end

  def test_continuation_times_out_if_follow_up_does_not_start
    ENV["FAKE_CURSOR_MODE"] = "turn_complete_open"
    first_code, _first_output, first_error = capture_main("--intent", "Initial", "--external-agent-consent")
    run_dir = latest_run
    ENV["FAKE_CMUX_SCENARIO"] = "followup_no_start"

    code, _output, error = capture_main(
      "--intent", "Fix one reviewed defect", "--continue-run", run_dir, "--external-agent-consent"
    )
    turn = AgentBuild.read_state(run_dir).fetch("turn")

    assert_equal 0, first_code
    assert_empty first_error
    assert_equal 1, code
    assert_includes error, "did not start before the timeout"
    assert_equal "complete", turn.fetch("state")
    assert_equal "fake-generation-1", turn.fetch("generation_id")
  end

  def test_failed_cmux_launch_releases_the_reservation
    {
      "split_failure" => "Cmux could not create the right-hand split",
      "submission_failure" => "Cmux could not submit the Cursor worker",
      "no_start" => nil
    }.each do |scenario, message|
      ENV["FAKE_CMUX_SCENARIO"] = scenario
      FileUtils.rm_f([@cmux_log, @cursor_log])
      code, output, error = capture_main("--intent", "Work", "--external-agent-consent")

      assert_equal 1, code, scenario
      assert_includes error, message, scenario if message
      assert_includes output, "Terminal state: failed", scenario if scenario == "no_start"
      assert_includes File.read(@cmux_log), "close-surface", scenario if scenario == "submission_failure"
      assert_empty lock_directories, scenario
      refute File.exist?(@cursor_log), scenario
    end
  end

  def test_dead_worker_retains_the_reservation
    run_dir = AgentBuild.create_run
    AgentBuild.initialize_state(run_dir)
    token = "dead-worker"
    reservation = AgentBuild.acquire_reservation(@repo, run_dir, token)
    AgentBuild.update_state(run_dir) do |state|
      state["state"] = "open"
      state["worker_pid"] = 999_999_999
      true
    end

    state = AgentBuild.wait_for_completion(run_dir, reservation, token, nil)

    assert_equal "recovery_required", state.fetch("state")
    assert File.directory?(reservation)
  end

  def test_hooks_track_turns_without_transcripts
    run_dir = AgentBuild.create_run
    AgentBuild.initialize_state(run_dir)
    original = ENV["AGENT_BUILD_RUN_DIR"]
    ENV["AGENT_BUILD_RUN_DIR"] = run_dir

    AgentBuild.cursor_hook_main(
      "beforeSubmitPrompt",
      input: StringIO.new(JSON.generate("generation_id" => "one", "prompt" => "private prompt")),
      output: StringIO.new
    )
    AgentBuild.cursor_hook_main(
      "stop",
      input: StringIO.new(JSON.generate("generation_id" => "one", "status" => "aborted", "loop_count" => 0,
                                        "transcript_path" => "/private/transcript")),
      output: StringIO.new
    )
    AgentBuild.cursor_hook_main(
      "beforeSubmitPrompt",
      input: StringIO.new(JSON.generate("generation_id" => "two")),
      output: StringIO.new
    )
    AgentBuild.cursor_hook_main(
      "stop",
      input: StringIO.new(JSON.generate("generation_id" => "two", "status" => "completed", "loop_count" => 0)),
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

  def test_nonzero_cursor_exit_is_not_success
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

  def test_bookkeeping_failure_terminates_the_child
    ENV["FAKE_CURSOR_MODE"] = "sleep"
    ENV["AGENT_BUILD_TEST_FAIL_AFTER_SPAWN"] = "1"
    code, output, _error = capture_main("--intent", "Work", "--external-agent-consent")
    state = AgentBuild.read_state(latest_run)

    assert_equal 1, code
    assert_includes output, "Terminal state: failed"
    assert_equal true, state.fetch("outcome").fetch("cursor_termination_confirmed")
    refute AgentBuild.process_alive?(state.fetch("cursor_pid"))
    assert_empty lock_directories
  end

  def test_unconfirmed_child_blocks_the_next_run
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
  end

  def test_prompt_lists_instructions_and_plans_resolve_from_the_repo
    ancestor = File.join(@temporary, "AGENTS.md")
    File.write(ancestor, "ancestor instructions\n")
    File.write(File.join(@repo, "AGENTS.md"), "root instructions\n")
    FileUtils.mkdir_p(File.join(@repo, "lib"))
    File.write(File.join(@repo, "lib", "CLAUDE.md"), "nested instructions\n")
    File.write(File.join(@repo, "app.rb"), "SECRET_DIFF_CONTENT\n")
    FileUtils.mkdir_p(File.join(@repo, "docs"))
    File.write(File.join(@repo, "docs", "plan.md"), "approved plan\n")
    instructions = AgentBuild.instruction_paths(@repo)
    prompt = AgentBuild.worker_prompt(task: "Work", repo: @repo, status: " M app.rb\n", instructions: instructions)

    assert_includes prompt, ancestor
    assert_includes prompt, "lib/CLAUDE.md"
    refute_includes prompt, "SECRET_DIFF_CONTENT"
    refute_includes prompt, "root instructions"

    code, output, error = capture_main_from(File.join(@repo, "lib"), "--plan", "docs/plan.md", "--dry-run")
    assert_equal 0, code
    assert_empty error
    assert_includes output, "Plan: docs/plan.md"
  end

  def test_untracked_change_is_reported_without_attribution
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

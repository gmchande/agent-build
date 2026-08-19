# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "rbconfig"
require "securerandom"
require "shellwords"
require "time"

module AgentBuild
  class Error < StandardError; end
  class ReservationError < Error; end
  STATES = %w[launching claimed open exited interrupted failed recovery_required].freeze
  TERMINAL_STATES = %w[exited interrupted failed].freeze
  WAKE_STATES = (TERMINAL_STATES + ["recovery_required"]).freeze
  TURN_STATES = %w[waiting running aborted complete failed].freeze
  TURN_WAKE_STATES = %w[complete failed].freeze
  INSTRUCTION_NAMES = %w[AGENTS.md CLAUDE.md].freeze
  STARTUP_TIMEOUT = 5.0
  FOLLOWUP_START_TIMEOUT = 15.0
  POLL_INTERVAL = 0.2
  module_function

  def capture(argv, chdir: nil, stdin_data: "")
    if chdir
      Open3.capture3(*argv, chdir: chdir, stdin_data: stdin_data)
    else
      Open3.capture3(*argv, stdin_data: stdin_data)
    end
  rescue Errno::ENOENT => error
    raise Error, "Command not found: #{argv.first} (#{error.message})"
  end

  def capture!(argv, chdir: nil, label: nil, stdin_data: "")
    stdout, stderr, status = capture(argv, chdir: chdir, stdin_data: stdin_data)
    return stdout if status.success?
    detail = stderr.to_s.strip
    detail = stdout.to_s.strip if detail.empty?
    message = label || "Command failed: #{argv.shelljoin}"
    raise Error, detail.empty? ? message : "#{message}: #{detail}"
  end

  def executable_on_path(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
      next if directory.empty?
      candidate = File.expand_path(name, directory)
      return candidate if File.file?(candidate) && File.executable?(candidate)
    end
    nil
  end

  def resolve_executable(name)
    path = executable_on_path(name)
    raise Error, "Required executable not found on PATH: #{name}" unless path
    File.expand_path(path)
  end

  def git(repo, *arguments)
    capture!([resolve_executable("git"), "-C", repo, *arguments], label: "Git command failed")
  end

  def repository_root
    root = capture!(
      [resolve_executable("git"), "rev-parse", "--show-toplevel"],
      chdir: Dir.pwd,
      label: "Run agent-build from inside a Git repository"
    ).strip
    File.realpath(root)
  rescue Errno::ENOENT
    raise Error, "Git repository root no longer exists"
  end

  def head_snapshot(repo)
    git_path = resolve_executable("git")
    stdout, _stderr, status = capture([git_path, "-C", repo, "rev-parse", "--verify", "--quiet", "HEAD^{commit}"])
    oid = status.success? ? stdout.strip : "unborn"
    stdout, _stderr, status = capture([git_path, "-C", repo, "symbolic-ref", "--quiet", "HEAD"])
    { "oid" => oid, "ref" => status.success? ? stdout.strip : nil }
  end

  def tracked_snapshot(repo, head)
    base = if head.fetch("oid") == "unborn"
             git(repo, "hash-object", "-t", "tree", "/dev/null").strip
           else
             head.fetch("oid")
           end
    status = git(repo, "status", "--short", "--untracked-files=no", "--")
    diff = git(repo, "diff", "--binary", "--no-ext-diff", base, "--")
    [status, diff]
  end

  def untracked_paths(repo)
    git(repo, "ls-files", "--others", "--exclude-standard", "-z", "--").split("\0").reject(&:empty?).sort
  end

  def fingerprint_path(repo, relative_path)
    path = File.join(repo, relative_path)
    before = File.lstat(path)
    digest = if before.symlink?
               Digest::SHA256.hexdigest(File.readlink(path))
             elsif before.file?
               Digest::SHA256.file(path).hexdigest
             else
               raise Error, "Unsupported untracked path type: #{relative_path}"
             end
    after = File.lstat(path)
    unless [before.size, before.mtime, before.ino] == [after.size, after.mtime, after.ino]
      raise Error, "Untracked file changed while being fingerprinted: #{relative_path}"
    end
    { "path" => relative_path, "size" => before.size, "sha256" => digest }
  rescue Errno::ENOENT
    raise Error, "Untracked file disappeared while being fingerprinted: #{relative_path}"
  end

  def fingerprint_changes(metadata)
    repo = metadata.fetch("repo")
    metadata.fetch("untracked").each_with_object([]) do |before, changed|
      path = before.fetch("path")
      current = fingerprint_path(repo, path)
      changed << path unless current == before
    rescue Error, SystemCallError
      changed << path
    end
  end

  def instruction_paths(repo)
    ancestors = []
    directory = File.dirname(repo)
    loop do
      INSTRUCTION_NAMES.each do |name|
        path = File.join(directory, name)
        ancestors << path if File.file?(path)
      end
      parent = File.dirname(directory)
      break if parent == directory
      directory = parent
    end
    repository_paths = git(repo, "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--").split("\0")
    repository_paths.select! { |path| INSTRUCTION_NAMES.include?(File.basename(path)) }
    [*ancestors.reverse, *repository_paths.sort].uniq
  end

  def plan_task(repo, raw_path)
    candidate = File.expand_path(raw_path, repo)
    raise Error, "Plan file not found: #{raw_path}" unless File.file?(candidate)
    real_path = File.realpath(candidate)
    unless real_path.start_with?("#{repo}#{File::SEPARATOR}")
      raise Error, "Plan must be a file inside the delegated repository: #{raw_path}"
    end
    relative = Pathname.new(real_path).relative_path_from(Pathname.new(repo)).to_s
    ["Read and implement the complete approved plan at `#{relative}`.", relative]
  end

  def task_text(repo, options)
    return [options.fetch(:intent).strip, nil] if options[:intent]
    plan_task(repo, options.fetch(:plan))
  end

  def worker_prompt(task:, repo:, status:, instructions:)
    status_text = status.strip.empty? ? "(clean)" : status.rstrip
    instruction_text = instructions.empty? ? "(none found)" : instructions.join("\n")
    <<~PROMPT
      Implement one approved bounded task in #{repo}.
      Task:
      #{task}
      Pre-existing git status:
      ```text
      #{status_text}
      ```
      Applicable repository instruction files:
      ```text
      #{instruction_text}
      ```
      Read every listed instruction file applicable to a file before editing it. Preserve existing work and avoid unrelated changes. Implement the smallest complete change. Avoid modifying pre-existing untracked files unless the task genuinely requires it.
      Run the smallest relevant existing checks and inspect the final diff. Do not commit, push, deploy, mutate Git history, communicate externally, or make unrelated external writes. If ambiguity would materially change behavior, architecture, dependencies, persistence, or data shape, stop and ask one precise question.
      In your final response, summarize changed files, checks and results, deviations, and remaining risks. Then stop; the parent Codex will review independently.
    PROMPT
  end

  def one_line(text)
    text.to_s.gsub(/[[:space:]]+/, " ").strip
  end

  def continuation_prompt(task)
    one_line(<<~PROMPT)
      Implement this approved follow-up in the current repository and Cursor session:
      #{task}
      Preserve all other work. Run the smallest relevant checks and inspect the final diff. Do not commit, push, deploy, mutate Git history, communicate externally, or make unrelated external writes. If ambiguity would materially change behavior, architecture, dependencies, persistence, or data shape, stop and ask one precise question.
      In your final response, summarize changed files, checks and results, deviations, and remaining risks. Then stop; the parent Codex will review independently.
    PROMPT
  end

  def cursor_command(executable, repo, prompt)
    [executable, "--force", "--sandbox", "enabled", "--trust", "--workspace", repo, prompt]
  end

  def disclosure(repo, instructions)
    outside = instructions.each_with_object([]) do |path, paths|
      absolute = Pathname.new(path).absolute? ? File.expand_path(path) : File.expand_path(path, repo)
      paths << absolute unless absolute.start_with?("#{repo}#{File::SEPARATOR}")
    end
    outside_text = outside.empty? ? "(none)" : outside.join(", ")
    "Cursor may send repository contents from #{repo} and applicable instructions to its configured external service and may consume paid usage. Applicable instruction files outside #{repo}: #{outside_text}. Its provider and model remain unresolved and inherited. --force plus Cursor's native sandbox is not a complete security boundary."
  end

  def state_root_path
    base = ENV.fetch("XDG_STATE_HOME", "").strip
    base = File.join(Dir.home, ".local", "state") if base.empty?
    File.join(base, "agent-build")
  end

  def state_root
    private_directory(state_root_path)
  end

  def cursor_hooks_path
    ENV.fetch("AGENT_BUILD_CURSOR_HOOKS_PATH", File.join(Dir.home, ".cursor", "hooks.json"))
  end

  def hook_command(event)
    script = Shellwords.escape(File.expand_path(__FILE__))
    %(if [ -n "${AGENT_BUILD_RUN_DIR:-}" ]; then /usr/bin/env ruby #{script} --cursor-hook #{event} || echo '{}'; else echo '{}'; fi)
  end

  def expected_hook_config
    {
      "version" => 1,
      "hooks" => {
        "beforeSubmitPrompt" => [{ "command" => hook_command("beforeSubmitPrompt") }],
        "stop" => [{ "command" => hook_command("stop") }]
      }
    }
  end

  def validate_hook_document(config)
    hooks = config["hooks"]
    valid = config["version"] == 1 && hooks.is_a?(Hash) && hooks.all? do |event, entries|
      event.is_a?(String) && entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) }
    end
    raise Error, "Cursor hook configuration is unreadable or malformed: #{cursor_hooks_path}" unless valid
    config
  end

  def read_cursor_hooks
    validate_hook_document(read_json(cursor_hooks_path, "Cursor hook configuration"))
  end

  def missing_hook_events(config)
    expected_hook_config.fetch("hooks").each_with_object([]) do |(event, expected), missing|
      missing << event unless config.fetch("hooks").fetch(event, []).include?(expected.first)
    end
  end

  def hook_readiness
    return [false, "not ready: #{cursor_hooks_path} does not exist"] unless File.file?(cursor_hooks_path)
    config = read_cursor_hooks
    missing = missing_hook_events(config)
    return [false, "not ready: missing #{missing.join(', ')}"] unless missing.empty?
    mode = File.stat(cursor_hooks_path).mode & 0o777
    return [false, format("not ready: mode %04o must be 0600", mode)] unless mode == 0o600
    [true, "ready"]
  rescue Error, SystemCallError => error
    [false, "not ready: #{error.message}"]
  end

  def validate_cursor_hooks!
    ready, status = hook_readiness
    unless ready
      raise Error, "Cursor hooks are #{status}. Preview setup with: ruby #{File.expand_path(__FILE__)} --setup-hooks --dry-run"
    end
    true
  end

  def write_cursor_hooks(config)
    path = cursor_hooks_path
    directory = File.dirname(path)
    unless File.exist?(directory)
      FileUtils.mkdir_p(directory, mode: 0o700)
      File.chmod(0o700, directory)
    end
    raise Error, "Cursor hook directory is not a directory: #{directory}" unless File.directory?(directory)
    raise Error, "Refusing to replace symlinked Cursor hook configuration: #{path}" if File.symlink?(path)
    temporary = "#{path}.tmp-#{Process.pid}-#{SecureRandom.hex(5)}"
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.pretty_generate(config) + "\n")
      file.flush
      file.fsync
    end
    File.rename(temporary, path)
    File.chmod(0o600, path)
  ensure
    File.delete(temporary) if temporary && File.exist?(temporary)
  end

  def setup_hooks(dry_run:)
    ready, readiness = hook_readiness
    config = File.exist?(cursor_hooks_path) ? read_cursor_hooks : { "version" => 1, "hooks" => {} }
    expected_hook_config.fetch("hooks").each do |event, expected|
      config.fetch("hooks")[event] ||= []
      config.fetch("hooks").fetch(event) << expected.first unless config.fetch("hooks").fetch(event).include?(expected.first)
    end
    puts "Mode: #{dry_run ? 'hook setup preview; no files changed' : 'hook setup'}"
    puts "Target: #{cursor_hooks_path}"
    puts "Current readiness: #{readiness}"
    puts "Merged configuration:"
    puts JSON.pretty_generate(config)
    return 0 if dry_run
    if ready
      puts "Cursor hooks already ready; no file changed."
    else
      write_cursor_hooks(config)
      puts "Cursor hooks installed; unrelated hook entries were preserved."
    end
    0
  end

  def private_directory(path)
    FileUtils.mkdir_p(path, mode: 0o700)
    File.chmod(0o700, path)
    path
  end

  def write_private(path, content)
    private_directory(File.dirname(path))
    temporary = "#{path}.tmp-#{Process.pid}-#{SecureRandom.hex(5)}"
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(content)
      file.flush
      file.fsync
    end
    File.rename(temporary, path)
    File.chmod(0o600, path)
  ensure
    File.delete(temporary) if temporary && File.exist?(temporary)
  end

  def write_json(path, object)
    write_private(path, JSON.pretty_generate(object) + "\n")
  end

  def parse_json(content, label)
    value = JSON.parse(content)
    raise Error, "#{label} must contain a JSON object" unless value.is_a?(Hash)
    value
  rescue JSON::ParserError => error
    raise Error, "Malformed #{label}: #{error.message}"
  end

  def read_json(path, label)
    parse_json(File.read(path), label)
  rescue Errno::ENOENT, Errno::EACCES => error
    raise Error, "Cannot read #{label}: #{error.message}"
  end

  def create_run
    loop do
      path = File.join(private_directory(File.join(state_root, "runs")), "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(6)}")
      begin
        Dir.mkdir(path, 0o700)
        return File.realpath(path)
      rescue Errno::EEXIST
        next
      end
    end
  end

  def create_continuation(run_dir)
    root = private_directory(File.join(run_dir, "continuations"))
    loop do
      path = File.join(root, "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}")
      begin
        Dir.mkdir(path, 0o700)
        return path
      rescue Errno::EEXIST
        next
      end
    end
  end

  def validate_run_dir(path)
    real = File.realpath(path)
    root = File.realpath(private_directory(File.join(state_root, "runs")))
    raise Error, "Run directory is outside agent-build state" unless real.start_with?("#{root}#{File::SEPARATOR}")
    real
  rescue Errno::ENOENT, Errno::EACCES => error
    raise Error, "Invalid run directory: #{error.message}"
  end

  def initialize_state(run_dir)
    write_json(
      File.join(run_dir, "state.json"),
      "state" => "launching",
      "worker_pid" => nil,
      "cursor_pid" => nil,
      "outcome" => nil,
      "turn" => { "state" => "waiting", "generation_id" => nil },
      "updated_at" => Time.now.utc.iso8601
    )
  end

  def validate_state(value)
    state = value["state"]
    raise Error, "Run state is unreadable or malformed" unless STATES.include?(state)
    turn = value["turn"]
    unless turn.is_a?(Hash) && TURN_STATES.include?(turn["state"])
      raise Error, "Run state is unreadable or malformed"
    end
    value
  end

  def read_state(run_dir)
    File.open(File.join(run_dir, "state.json"), File::RDONLY) do |file|
      file.flock(File::LOCK_SH)
      validate_state(parse_json(file.read, "run state"))
    ensure
      file.flock(File::LOCK_UN) rescue nil
    end
  rescue Errno::ENOENT, Errno::EACCES => error
    raise Error, "Cannot read run state: #{error.message}"
  end

  def cursor_hook_main(event, input: $stdin, output: $stdout)
    raise Error, "Unknown Cursor hook event: #{event}" unless %w[beforeSubmitPrompt stop].include?(event)
    run_dir = validate_run_dir(ENV.fetch("AGENT_BUILD_RUN_DIR"))
    payload = parse_json(input.read, "Cursor hook input")
    generation = payload["generation_id"].to_s
    generation = nil if generation.empty?
    update_state(run_dir) do |state|
      turn = state.fetch("turn")
      if event == "beforeSubmitPrompt"
        turn["state"] = "running"
        turn["generation_id"] = generation
        true
      else
        next false if generation && turn["generation_id"] && generation != turn["generation_id"]
        status = payload["status"].to_s
        loop_count = Integer(payload.fetch("loop_count", 0).to_s, 10)
        turn["generation_id"] ||= generation
        turn["state"] = case status
                        when "completed"
                          loop_count.zero? ? "complete" : "running"
                        when "aborted"
                          "aborted"
                        else
                          "failed"
                        end
        true
      end
    end
    output.puts JSON.generate({})
    0
  rescue KeyError, ArgumentError => error
    raise Error, "Invalid Cursor hook input: #{error.message}"
  end

  def update_state(run_dir)
    File.open(File.join(run_dir, "state.json"), File::RDWR) do |file|
      file.flock(File::LOCK_EX)
      state = validate_state(parse_json(file.read, "run state"))
      changed = yield(state)
      if changed
        state["updated_at"] = Time.now.utc.iso8601
        file.rewind
        file.truncate(0)
        file.write(JSON.pretty_generate(state) + "\n")
        file.flush
        file.fsync
      end
      [state, changed]
    ensure
      file.flock(File::LOCK_UN) rescue nil
    end
  rescue Errno::ENOENT, Errno::EACCES => error
    raise Error, "Cannot update run state: #{error.message}"
  end

  def arm_continuation(run_dir, previous_turn)
    update_state(run_dir) do |state|
      turn = state.fetch("turn")
      unless state.fetch("state") == "open" && turn == previous_turn && turn.fetch("state") == "complete"
        raise Error, "Cursor session changed before the follow-up could be submitted"
      end
      state["turn"] = { "state" => "waiting", "generation_id" => nil }
      true
    end
  end

  def restore_turn(run_dir, previous_turn)
    update_state(run_dir) do |state|
      turn = state.fetch("turn")
      next false unless state.fetch("state") == "open" && turn == { "state" => "waiting", "generation_id" => nil }

      state["turn"] = previous_turn
      true
    end
  end

  def reservation_path(repo)
    File.join(private_directory(File.join(state_root, "locks")), Digest::SHA256.hexdigest(repo))
  end

  def read_reservation(path)
    raise ReservationError, "Repository reservation is unreadable or malformed: #{path}" unless Dir.children(path) == ["reservation.json"]
    data = read_json(File.join(path, "reservation.json"), "repository reservation")
    %w[repo run_dir token].each do |key|
      raise ReservationError, "Repository reservation is unreadable or malformed: #{path}" unless data[key].is_a?(String) && !data[key].empty?
    end
    data
  rescue SystemCallError, Error
    raise ReservationError, "Repository reservation is unreadable or malformed: #{path}"
  end

  def remove_owned_reservation(path, token)
    data = read_reservation(path)
    return false unless data.fetch("token") == token
    moved = "#{path}.released-#{Process.pid}-#{SecureRandom.hex(4)}"
    File.rename(path, moved)
    File.delete(File.join(moved, "reservation.json"))
    Dir.rmdir(moved)
    true
  rescue Errno::ENOENT
    false
  rescue SystemCallError, ReservationError
    false
  end

  def acquire_reservation(repo, run_dir, token)
    path = reservation_path(repo)
    loop do
      begin
        Dir.mkdir(path, 0o700)
        write_json(File.join(path, "reservation.json"), "repo" => repo, "run_dir" => run_dir, "token" => token)
        return path
      rescue Errno::EEXIST
        existing = read_reservation(path)
        raise ReservationError, "Repository reservation is unreadable or malformed: #{path}" unless existing.fetch("repo") == repo
        state = read_state(validate_run_dir(existing.fetch("run_dir"))).fetch("state")
        unless TERMINAL_STATES.include?(state)
          raise ReservationError, "Another agent-build run owns this repository: #{existing.fetch('run_dir')}"
        end
        unless remove_owned_reservation(path, existing.fetch("token"))
          raise ReservationError, "Could not safely reclaim terminal repository reservation: #{path}"
        end
      rescue SystemCallError => error
        Dir.rmdir(path) if File.directory?(path) && Dir.empty?(path)
        raise ReservationError, "Could not create repository reservation: #{error.message}"
      end
    end
  rescue Error => error
    raise ReservationError, error.message
  end

  def reservation_owned?(path, metadata)
    reservation = read_reservation(path)
    reservation.fetch("repo") == metadata.fetch("repo") &&
      reservation.fetch("run_dir") == metadata.fetch("run_dir") &&
      reservation.fetch("token") == metadata.fetch("token")
  end

  def cmux_context?
    !ENV.fetch("CMUX_WORKSPACE_ID", "").strip.empty? &&
      !ENV.fetch("CMUX_SURFACE_ID", "").strip.empty?
  end

  def ghostty_context?
    ENV.fetch("TERM_PROGRAM", "").strip.casecmp("ghostty").zero?
  end

  def current_viewer_name
    if cmux_context?
      "Cmux right split"
    elsif ghostty_context?
      "Ghostty right split"
    else
      "Ghostty tab"
    end
  end

  def cmux_command_path
    bundled = ENV.fetch("CMUX_BUNDLED_CLI_PATH", "").strip
    return File.expand_path(bundled) if !bundled.empty? && File.executable?(bundled)

    path = executable_on_path("cmux")
    return File.expand_path(path) if path

    app_path = "/Applications/cmux.app/Contents/Resources/bin/cmux"
    File.expand_path(app_path) if File.executable?(app_path)
  end

  def preflight_cmux
    cmux = cmux_command_path
    raise Error, "Cmux context detected, but the Cmux CLI is unavailable" unless cmux
    workspace = ENV.fetch("CMUX_WORKSPACE_ID", "").strip
    surface = ENV.fetch("CMUX_SURFACE_ID", "").strip
    raise Error, "Cmux ping did not return PONG" unless capture!([cmux, "ping"], label: "Cmux is unavailable").strip == "PONG"
    { "type" => "cmux", "executable" => cmux, "workspace" => workspace, "caller_surface" => surface }
  end

  def preflight_ghostty
    osascript = resolve_executable("osascript")
    zsh = resolve_executable("zsh")
    _stdout, stderr, status = capture([osascript, "-e", 'id of application "Ghostty"'])
    raise Error, "Ghostty is unavailable#{stderr.strip.empty? ? '' : ": #{stderr.strip}"}" unless status.success?
    { "type" => "ghostty", "executable" => osascript, "shell" => zsh }
  end

  def preflight_viewer
    cmux_context? ? preflight_cmux : preflight_ghostty
  end

  def viewer_metadata(viewer)
    case viewer.fetch("type")
    when "cmux"
      viewer.slice("type", "workspace", "caller_surface", "surface")
    when "ghostty"
      viewer.slice("type", "tab", "terminal", "placement")
    else
      raise Error, "Unknown viewer type: #{viewer.fetch('type')}"
    end
  end

  def viewer_label(viewer)
    case viewer.fetch("type")
    when "cmux"
      "Cmux right split #{viewer.fetch('surface')}"
    when "ghostty"
      target = viewer["terminal"].to_s.strip
      target = viewer["tab"].to_s.strip if target.empty?
      if viewer["placement"] == "split"
        target.empty? ? "Ghostty right split" : "Ghostty right split #{target}"
      else
        target.empty? ? "Ghostty tab" : "Ghostty tab #{target}"
      end
    else
      raise Error, "Unknown viewer type: #{viewer.fetch('type')}"
    end
  end

  def create_cmux_surface(viewer)
    cmux = viewer.fetch("executable")
    workspace = viewer.fetch("workspace")
    caller_surface = viewer.fetch("caller_surface")
    output = capture!(
      [cmux, "--json", "new-split", "right", "--workspace", workspace, "--surface", caller_surface, "--focus", "false"],
      label: "Cmux could not create the right-hand split"
    )
    response = parse_json(output, "Cmux split response")
    response = response["result"] if response["result"].is_a?(Hash)
    surface = response["surface_ref"] || response["surface_id"]
    raise Error, "Cmux created a split but returned no exact surface" unless surface
    surface.to_s.strip
  end

  def worker_command(run_dir)
    state_base = File.dirname(File.dirname(File.dirname(run_dir)))
    ["env", "XDG_STATE_HOME=#{state_base}", RbConfig.ruby, File.expand_path(__FILE__), "--worker", run_dir].shelljoin
  end

  def submit_cmux_worker(viewer, run_dir)
    _stdout, stderr, status = capture(
      [viewer.fetch("executable"), "respawn-pane", "--workspace", viewer.fetch("workspace"), "--surface",
       viewer.fetch("surface"), "--command", worker_command(run_dir)]
    )
    [status.success?, stderr.to_s.strip]
  end

  def applescript_string(value)
    escaped = value.to_s.gsub("\\") { "\\\\" }.gsub('"') { '\\"' }
    "\"#{escaped}\""
  end

  def open_ghostty_viewer(viewer, repo, run_dir)
    split = ghostty_context?
    launch_command = "#{viewer.fetch('shell').shellescape} -lc #{worker_command(run_dir).shellescape}"
    create_surface = if split
                       <<~APPLESCRIPT
                         set currentTerm to focused terminal of selected tab of front window
                         set newTerm to split currentTerm direction right with configuration cfg
                         focus newTerm
                         set newTabID to id of selected tab of front window
                         set newTermID to id of newTerm
                       APPLESCRIPT
                     else
                       <<~APPLESCRIPT
                         if (count of windows) > 0 then
                           set newTab to new tab in front window with configuration cfg
                           select tab newTab
                           set newTabID to id of newTab
                           set newTermID to id of focused terminal of newTab
                         else
                           set newWin to new window with configuration cfg
                           set newTabID to id of selected tab of newWin
                           set newTermID to id of focused terminal of selected tab of newWin
                         end if
                         activate
                       APPLESCRIPT
                     end
    script = <<~APPLESCRIPT
      tell application "Ghostty"
        set cfg to new surface configuration
        set initial working directory of cfg to #{applescript_string(repo)}
        set command of cfg to #{applescript_string(launch_command)}
        set wait after command of cfg to true
        #{create_surface.chomp}
        return (newTabID as text) & linefeed & (newTermID as text)
      end tell
    APPLESCRIPT
    stdout, stderr, status = capture([viewer.fetch("executable")], stdin_data: script)
    tab, terminal = stdout.to_s.split(/\r?\n/).map(&:strip).reject(&:empty?)
    launched = viewer.merge("tab" => tab.to_s, "placement" => split ? "split" : "tab")
    launched["terminal"] = terminal unless terminal.to_s.empty?
    [launched, status.success?, stderr.to_s.strip]
  end

  def launch_viewer(viewer, repo, run_dir)
    case viewer.fetch("type")
    when "cmux"
      launched = viewer.merge("surface" => create_cmux_surface(viewer))
      submitted, detail = submit_cmux_worker(launched, run_dir)
      [launched, submitted, detail]
    when "ghostty"
      open_ghostty_viewer(viewer, repo, run_dir)
    else
      raise Error, "Unknown viewer type: #{viewer.fetch('type')}"
    end
  end

  def continuation_viewer(metadata)
    stored = metadata.fetch("viewer")
    case stored.fetch("type")
    when "cmux"
      executable = cmux_command_path
      raise Error, "Cmux CLI is unavailable for the existing session" unless executable
      raise Error, "Cmux ping did not return PONG" unless capture!([executable, "ping"], label: "Cmux is unavailable").strip == "PONG"
      stored.merge("executable" => executable)
    when "ghostty"
      executable = resolve_executable("osascript")
      _stdout, stderr, status = capture([executable, "-e", 'id of application "Ghostty"'])
      raise Error, "Ghostty is unavailable#{stderr.strip.empty? ? '' : ": #{stderr.strip}"}" unless status.success?
      stored.merge("executable" => executable)
    else
      raise Error, "Unknown viewer type: #{stored['type'].inspect}"
    end
  end

  def submit_cmux_followup(viewer, prompt)
    target = ["--workspace", viewer.fetch("workspace"), "--surface", viewer.fetch("surface")]
    _stdout, stderr, status = capture([viewer.fetch("executable"), "send", *target, one_line(prompt)])
    return [false, stderr.to_s.strip] unless status.success?

    _stdout, stderr, status = capture([viewer.fetch("executable"), "send-key", *target, "enter"])
    [status.success?, stderr.to_s.strip]
  end

  def ghostty_followup_target(viewer)
    terminal = viewer["terminal"].to_s.strip
    terminal.empty? ? viewer.fetch("tab") : terminal
  end

  def submit_ghostty_followup(viewer, prompt)
    script = <<~APPLESCRIPT
      on run argv
        set targetID to item 1 of argv
        set promptText to item 2 of argv
        tell application "Ghostty"
          repeat with currentWindow in windows
            repeat with currentTab in tabs of currentWindow
              repeat with currentTerminal in terminals of currentTab
                if (id of currentTerminal as text) is targetID then
                  input text promptText to currentTerminal
                  send key "enter" to currentTerminal
                  return id of currentTerminal
                end if
              end repeat
              if (id of currentTab as text) is targetID then
                set targetTerminal to focused terminal of currentTab
                input text promptText to targetTerminal
                send key "enter" to targetTerminal
                return id of targetTerminal
              end if
            end repeat
          end repeat
          error "Recorded Ghostty surface is no longer open"
        end tell
      end run
    APPLESCRIPT
    _stdout, stderr, status = capture(
      [viewer.fetch("executable"), "-", ghostty_followup_target(viewer), one_line(prompt)],
      stdin_data: script
    )
    [status.success?, stderr.to_s.strip]
  end

  def submit_followup(viewer, prompt)
    case viewer.fetch("type")
    when "cmux"
      submit_cmux_followup(viewer, prompt)
    when "ghostty"
      submit_ghostty_followup(viewer, prompt)
    else
      raise Error, "Unknown viewer type: #{viewer.fetch('type')}"
    end
  end

  def close_viewer(viewer)
    return unless viewer
    if viewer.fetch("type") == "cmux"
      _stdout, stderr, status = capture(
        [viewer.fetch("executable"), "close-surface", "--workspace", viewer.fetch("workspace"), "--surface",
         viewer.fetch("surface")]
      )
      return stderr.to_s.strip unless status.success?
    elsif viewer.fetch("type") == "ghostty"
      warn "Close the empty or stalled #{viewer_label(viewer)} manually."
    end
    nil
  end

  def startup_timeout
    return STARTUP_TIMEOUT unless ENV["AGENT_BUILD_TESTING"] == "1"
    value = ENV.fetch("AGENT_BUILD_TEST_STARTUP_TIMEOUT", "0.2").to_f
    value.positive? ? value : STARTUP_TIMEOUT
  end

  def followup_start_timeout
    return startup_timeout if ENV["AGENT_BUILD_TESTING"] == "1"
    FOLLOWUP_START_TIMEOUT
  end

  def claim_spawn_right(run_dir)
    update_state(run_dir) do |state|
      next false unless state.fetch("state") == "launching"
      state["state"] = "claimed"
      state["worker_pid"] = Process.pid
      true
    end
  end

  def fail_unclaimed(run_dir, message)
    update_state(run_dir) do |state|
      next false unless state.fetch("state") == "launching"
      state["state"] = "failed"
      state["outcome"] = { "error" => message, "at" => Time.now.utc.iso8601 }
      true
    end
  end

  def recover_dead_worker(run_dir)
    update_state(run_dir) do |state|
      next false unless %w[claimed open].include?(state.fetch("state"))
      worker_pid = state["worker_pid"]
      next false if worker_pid.is_a?(Integer) && worker_pid.positive? && process_alive?(worker_pid)
      state["state"] = "recovery_required"
      state["outcome"] = {
        "error" => "Cursor worker disappeared before recording a terminal state",
        "cursor_termination_confirmed" => false,
        "at" => Time.now.utc.iso8601
      }
      true
    end
  end

  def report_launch(run_dir, viewer)
    puts "Cursor launch submitted."
    puts "Run: #{run_dir}"
    puts "Viewer: #{viewer_label(viewer)}"
    puts "Cursor is interactive there. You do not need to exit it for parent review."
    puts "Waiting locally for Cursor's native stop hook; this does not consume Cursor/model tokens."
    $stdout.flush
  end

  def report_continuation(session_run_dir, evidence_dir, viewer)
    puts "Cursor follow-up submitted to #{viewer_label(viewer)}."
    puts "Session: #{session_run_dir}"
    puts "Evidence: #{evidence_dir}"
    puts "Waiting locally for Cursor's next completed-turn hook; this does not consume Cursor/model tokens."
    $stdout.flush
  end

  def wait_for_completion(run_dir, reservation, token, viewer, previous_generation_id: nil)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
               (previous_generation_id ? followup_start_timeout : startup_timeout)
    loop do
      state = read_state(run_dir)
      if %w[claimed open].include?(state.fetch("state"))
        recovered, changed = recover_dead_worker(run_dir)
        return recovered if changed
      end
      turn = state.fetch("turn")
      return state if WAKE_STATES.include?(state.fetch("state")) || TURN_WAKE_STATES.include?(turn.fetch("state"))
      timed_out = Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      if state.fetch("state") == "launching" && timed_out
        failed, changed = fail_unclaimed(run_dir, "Cursor worker did not claim the launch before the startup deadline")
        if changed
          close_viewer(viewer)
          remove_owned_reservation(reservation, token)
          return failed
        end
      end
      if previous_generation_id && timed_out
        generation = turn.fetch("generation_id").to_s
        started = turn.fetch("state") == "running" || (!generation.empty? && generation != previous_generation_id)
        raise Error, "Cursor follow-up did not start before the timeout" unless started
      end
      sleep POLL_INTERVAL
    end
  end

  def history_movement(metadata)
    before = metadata.fetch("head")
    after = head_snapshot(metadata.fetch("repo"))
    return "none" if before == after
    "HEAD #{before.fetch('oid')} -> #{after.fetch('oid')}; ref #{before['ref'] || '(detached)'} -> #{after['ref'] || '(detached)'}"
  rescue Error, SystemCallError => error
    "unavailable: #{error.message}"
  end

  def outcome_text(state)
    outcome = state["outcome"] || {}
    parts = []
    parts << "exit #{outcome['exit_code']}" unless outcome["exit_code"].nil?
    parts << "signal #{outcome['signal']}" unless outcome["signal"].nil?
    parts << outcome["error"] if outcome["error"]
    parts.empty? ? "not recorded" : parts.join(", ")
  end

  def report_completion(run_dir, state)
    metadata = read_json(File.join(run_dir, "run.json"), "run metadata")
    changed = fingerprint_changes(metadata)
    turn = state.fetch("turn")
    if state.fetch("state") == "recovery_required"
      puts "Cursor lifecycle became untracked; the repository reservation was retained for recovery."
    elsif turn.fetch("state") == "complete"
      puts "Cursor turn completed; parent review may begin. The Cursor TUI may remain open."
    elsif turn.fetch("state") == "failed"
      puts "Cursor turn ended without a completed response; parent review may inspect the partial changes."
    else
      puts "Cursor process finished before a completed-turn handoff; parent review may inspect the partial changes."
    end
    puts "Terminal state: #{state.fetch('state')}"
    puts "Turn state: #{turn.fetch('state')}"
    puts "Exit outcome: #{state.fetch('state') == 'open' ? 'not exited; Cursor remains interactive' : outcome_text(state)}"
    puts "History movement: #{history_movement(metadata)}"
    puts "Pre-existing untracked files changed: #{changed.empty? ? '(none)' : changed.join(', ')}"
    puts "Exact line-level attribution is unavailable for any changed pre-existing untracked file." unless changed.empty?
    puts "A process exit or zero exit code is not proof that the implementation is correct."
  end

  def dry_run(options, repo)
    executable = resolve_executable("agent")
    task, plan = task_text(repo, options)
    status = git(repo, "status", "--short", "--")
    instructions = instruction_paths(repo)
    prompt = worker_prompt(task: task, repo: repo, status: status, instructions: instructions)
    argv = cursor_command(executable, repo, prompt)
    puts "Mode: dry run; no state, fingerprints, reservation, pane, or external request created"
    puts "Repository: #{repo}"
    puts "Agent: Cursor CLI"
    puts "Executable: #{executable}"
    puts "Argv: #{JSON.generate(argv)}"
    puts "Permission flags: --force --sandbox enabled --trust"
    ready, readiness = hook_readiness
    puts "Completion signal: native Cursor beforeSubmitPrompt/stop hooks from #{cursor_hooks_path}"
    puts "Hook readiness: #{readiness}#{ready ? '' : "; run --setup-hooks --dry-run before requesting consent"}"
    puts "Hook data retained: generation ID and lifecycle status only; no prompt, response, or transcript"
    puts "Provider/model: unresolved and inherited from Cursor"
    puts "Viewer selection: right-hand split inside Cmux; Ghostty right split when already in Ghostty; Ghostty tab otherwise"
    puts "Current viewer: #{current_viewer_name}"
    puts "Plan: #{plan}" if plan
    puts "Instruction files: #{instructions.empty? ? '(none found)' : instructions.join(', ')}"
    puts "Unignored untracked paths (contents not retained):"
    untracked = untracked_paths(repo)
    untracked.empty? ? puts("  (none)") : untracked.each { |path| puts "  #{path}" }
    puts "Disclosure: #{disclosure(repo, instructions)}"
    0
  end

  def continuation_session(raw_run_dir, repo)
    run_dir = validate_run_dir(raw_run_dir)
    metadata = read_json(File.join(run_dir, "run.json"), "run metadata")
    raise Error, "Cursor session belongs to a different repository" unless File.realpath(metadata.fetch("repo")) == repo

    state = read_state(run_dir)
    turn = state.fetch("turn")
    unless state.fetch("state") == "open" && turn.fetch("state") == "complete" && !turn.fetch("generation_id").to_s.empty?
      raise Error, "Cursor session is not open at a completed turn"
    end
    %w[worker_pid cursor_pid].each do |key|
      pid = state[key]
      raise Error, "Cursor session process is no longer alive" unless pid.is_a?(Integer) && pid.positive? && process_alive?(pid)
    end
    reservation = reservation_path(repo)
    raise Error, "Cursor session no longer owns the repository reservation" unless reservation_owned?(reservation, metadata)

    [run_dir, metadata, state]
  end

  def dry_run_continuation(options, repo)
    run_dir, metadata, state = continuation_session(options.fetch(:continue_run), repo)
    task, plan = task_text(repo, options)
    instructions = instruction_paths(repo)
    prompt = continuation_prompt(task)
    puts "Mode: continuation dry run; no state, fingerprints, viewer input, or external request created"
    puts "Repository: #{repo}"
    puts "Session: #{run_dir}"
    puts "Completed generation: #{state.dig('turn', 'generation_id')}"
    puts "Existing viewer: #{viewer_label(metadata.fetch('viewer'))}"
    puts "Prompt: #{JSON.generate(prompt)}"
    puts "Provider/model: unresolved and inherited from the existing Cursor session"
    puts "Plan: #{plan}" if plan
    puts "Instruction files: #{instructions.empty? ? '(none found)' : instructions.join(', ')}"
    puts "Unignored untracked paths (contents not retained):"
    untracked = untracked_paths(repo)
    untracked.empty? ? puts("  (none)") : untracked.each { |path| puts "  #{path}" }
    puts "Disclosure: #{disclosure(repo, instructions)}"
    0
  end

  def run_continuation(options, repo)
    validate_cursor_hooks!
    run_dir, session_metadata, session_state = continuation_session(options.fetch(:continue_run), repo)
    viewer = continuation_viewer(session_metadata)
    task, plan = task_text(repo, options)
    prompt = continuation_prompt(task)
    head = head_snapshot(repo)
    tracked_status, tracked_diff = tracked_snapshot(repo, head)
    instructions = instruction_paths(repo)
    untracked = untracked_paths(repo).map { |path| fingerprint_path(repo, path) }
    evidence_dir = create_continuation(run_dir)
    previous_turn = session_state.fetch("turn").dup
    metadata = {
      "version" => 4,
      "kind" => "continuation",
      "repo" => repo,
      "run_dir" => evidence_dir,
      "session_run_dir" => run_dir,
      "created_at" => Time.now.utc.iso8601,
      "head" => head,
      "untracked" => untracked,
      "instruction_paths" => instructions,
      "plan" => plan,
      "prompt" => prompt,
      "viewer" => session_metadata.fetch("viewer"),
      "previous_generation_id" => previous_turn.fetch("generation_id"),
      "external_service_consent" => true
    }
    write_private(File.join(evidence_dir, "pre.status"), tracked_status)
    write_private(File.join(evidence_dir, "pre.diff"), tracked_diff)
    write_json(File.join(evidence_dir, "run.json"), metadata)

    arm_continuation(run_dir, previous_turn)
    submitted, detail = submit_followup(viewer, prompt)
    unless submitted
      restore_turn(run_dir, previous_turn)
      raise Error, "Could not submit the Cursor follow-up#{detail.empty? ? '' : ": #{detail}"}"
    end

    report_continuation(run_dir, evidence_dir, viewer)
    reservation = reservation_path(repo)
    begin
      state = wait_for_completion(
        run_dir, reservation, session_metadata.fetch("token"), viewer,
        previous_generation_id: previous_turn.fetch("generation_id")
      )
    rescue Error
      restore_turn(run_dir, previous_turn)
      raise
    end
    turn = state.fetch("turn")
    if turn.fetch("state") == "complete" && turn.fetch("generation_id") == previous_turn.fetch("generation_id")
      raise Error, "Cursor follow-up did not produce a new generation"
    end
    report_completion(evidence_dir, state)
    turn.fetch("state") == "complete" ? 0 : 1
  end

  def run_live(options, repo)
    executable = resolve_executable("agent")
    validate_cursor_hooks!
    viewer = preflight_viewer
    task, plan = task_text(repo, options)
    run_dir = create_run
    initialize_state(run_dir)
    token = SecureRandom.hex(24)
    reservation = acquire_reservation(repo, run_dir, token)
    launched_viewer = nil
    submitted = false
    begin
      head = head_snapshot(repo)
      tracked_status, tracked_diff = tracked_snapshot(repo, head)
      status = git(repo, "status", "--short", "--")
      instructions = instruction_paths(repo)
      untracked = untracked_paths(repo).map { |path| fingerprint_path(repo, path) }
      prompt = worker_prompt(task: task, repo: repo, status: status, instructions: instructions)
      argv = cursor_command(executable, repo, prompt)
      metadata = {
        "version" => 3,
        "repo" => repo,
        "run_dir" => run_dir,
        "created_at" => Time.now.utc.iso8601,
        "head" => head,
        "untracked" => untracked,
        "instruction_paths" => instructions,
        "plan" => plan,
        "cursor" => { "executable" => executable, "argv" => argv, "hooks" => cursor_hooks_path },
        "viewer" => viewer_metadata(viewer),
        "token" => token,
        "external_service_consent" => true
      }
      write_private(File.join(run_dir, "pre.status"), tracked_status)
      write_private(File.join(run_dir, "pre.diff"), tracked_diff)
      write_json(File.join(run_dir, "run.json"), metadata)
      launched_viewer, submitted, detail = launch_viewer(viewer, repo, run_dir)
      metadata["viewer"] = viewer_metadata(launched_viewer)
      write_json(File.join(run_dir, "run.json"), metadata)
      unless submitted
        viewer_name = launched_viewer.fetch("type") == "cmux" ? "Cmux" : "Ghostty"
        _state, cancelled = fail_unclaimed(run_dir, "#{viewer_name} reported that Cursor command submission failed#{detail.empty? ? '' : ": #{detail}"}")
        if cancelled
          close_viewer(launched_viewer)
          remove_owned_reservation(reservation, token)
          raise Error, "#{viewer_name} could not submit the Cursor worker#{detail.empty? ? '' : ": #{detail}"}"
        end
      end
      report_launch(run_dir, launched_viewer)
      state = wait_for_completion(run_dir, reservation, token, launched_viewer)
      report_completion(run_dir, state)
      state.dig("turn", "state") == "complete" ? 0 : 1
    rescue StandardError
      if reservation
        begin
          _state, cancelled = fail_unclaimed(run_dir, "Cursor launch failed before the worker claimed spawn ownership")
          if cancelled
            close_viewer(launched_viewer)
            remove_owned_reservation(reservation, token)
          end
        rescue Error, SystemCallError
          nil
        end
      end
      raise
    end
  end

  def record_worker_failure(run_dir, message, cursor_pid, cleanup_confirmed)
    update_state(run_dir) do |state|
      state["state"] = cleanup_confirmed ? "failed" : "recovery_required"
      state["cursor_pid"] = cursor_pid
      state["outcome"] = {
        "error" => message,
        "cursor_termination_confirmed" => cleanup_confirmed,
        "at" => Time.now.utc.iso8601
      }
      true
    end
    true
  rescue Error, SystemCallError
    false
  end

  def terminate_and_reap(pid)
    return false if ENV["AGENT_BUILD_TEST_CLEANUP_FAIL"] == "1"
    Process.kill("TERM", pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
    loop do
      return true if Process.waitpid(pid, Process::WNOHANG)
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end
    Process.kill("KILL", pid)
    Process.waitpid(pid)
    true
  rescue Errno::ESRCH, Errno::ECHILD
    !process_alive?(pid)
  rescue SystemCallError
    false
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def worker_main(raw_run_dir)
    run_dir = validate_run_dir(raw_run_dir)
    metadata = read_json(File.join(run_dir, "run.json"), "run metadata")
    reservation = reservation_path(metadata.fetch("repo"))
    unless reservation_owned?(reservation, metadata)
      raise ReservationError, "Cursor worker does not own the repository reservation"
    end
    state, claimed = claim_spawn_right(run_dir)
    return 1 unless claimed && state.fetch("state") == "claimed"
    cursor_pid = nil
    cursor_reaped = false
    received_signal = nil
    Signal.trap("INT") { nil }
    %w[TERM HUP].each do |signal|
      Signal.trap(signal) do
        received_signal ||= signal
        Process.kill(signal, cursor_pid) if cursor_pid
      rescue Errno::ESRCH
        nil
      end
    end
    begin
      command = metadata.fetch("cursor").fetch("argv")
      cursor_pid = Process.spawn({ "AGENT_BUILD_RUN_DIR" => run_dir }, *command, chdir: metadata.fetch("repo"))
      raise Error, "Injected bookkeeping failure after Cursor spawn" if ENV["AGENT_BUILD_TEST_FAIL_AFTER_SPAWN"] == "1"
      update_state(run_dir) do |current|
        raise Error, "Run lost claimed state before Cursor opened" unless current.fetch("state") == "claimed"
        current["state"] = "open"
        current["cursor_pid"] = cursor_pid
        true
      end
      Process.kill(received_signal, cursor_pid) if received_signal
      _pid, process_status = Process.wait2(cursor_pid)
      cursor_reaped = true
      interrupted = received_signal || process_status.signaled? || process_status.exitstatus == 130
      terminal = interrupted ? "interrupted" : "exited"
      update_state(run_dir) do |current|
        raise Error, "Run lost open state before Cursor exit" unless current.fetch("state") == "open"
        current["state"] = terminal
        current["outcome"] = {
          "exit_code" => process_status.exited? ? process_status.exitstatus : nil,
          "signal" => process_status.signaled? ? process_status.termsig : received_signal,
          "at" => Time.now.utc.iso8601
        }
        true
      end
      warn "Cursor exited, but its repository reservation could not be released" unless remove_owned_reservation(reservation, metadata.fetch("token"))
      terminal == "exited" && process_status.success? ? 0 : 1
    rescue StandardError => error
      cleanup_confirmed = !cursor_pid || cursor_reaped || terminate_and_reap(cursor_pid)
      recorded = record_worker_failure(run_dir, error.message, cursor_pid, cleanup_confirmed)
      if cleanup_confirmed && recorded
        warn "Cursor cleanup succeeded, but its repository reservation could not be released" unless remove_owned_reservation(reservation, metadata.fetch("token"))
      else
        warn "Cursor termination could not be confirmed; the repository reservation was retained"
      end
      warn error.message
      1
    end
  rescue StandardError => error
    warn error.message
    1
  end

  def parse_options(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: agent_build.rb (--intent TEXT | --plan PATH) [--continue-run RUN_DIR] [--dry-run | --external-agent-consent]"
      opts.on("--intent TEXT", "Bounded implementation intent") { |value| options[:intent] = value }
      opts.on("--plan PATH", "Repository-relative approved plan") { |value| options[:plan] = value }
      opts.on("--continue-run RUN_DIR", "Continue the completed turn in an open Cursor session") { |value| options[:continue_run] = value }
      opts.on("--dry-run", "Print exact launch details without creating state or contacting Cursor") { options[:dry_run] = true }
      opts.on("--external-agent-consent", "Confirm fresh informed consent for this live Cursor launch") { options[:consent] = true }
    end
    parser.parse!(argv)
    raise Error, "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    raise Error, "Choose exactly one of --intent or --plan" unless [options[:intent], options[:plan]].compact.length == 1
    raise Error, "Intent must not be empty" if options[:intent] && options[:intent].strip.empty?
    raise Error, "Choose either --dry-run or --external-agent-consent, not both" if options[:dry_run] && options[:consent]
    options
  rescue OptionParser::ParseError => error
    raise Error, error.message
  end

  def main(argv = ARGV)
    $stdout.sync = true
    return worker_main(argv.fetch(1)) if argv.length == 2 && argv.first == "--worker"
    return cursor_hook_main(argv.fetch(1)) if argv.length == 2 && argv.first == "--cursor-hook"
    return setup_hooks(dry_run: false) if argv == ["--setup-hooks"]
    return setup_hooks(dry_run: true) if argv == ["--setup-hooks", "--dry-run"]
    options = parse_options(argv.dup)
    repo = repository_root
    if options[:dry_run]
      return dry_run_continuation(options, repo) if options[:continue_run]
      return dry_run(options, repo)
    end
    unless options[:consent]
      raise Error, "Live Cursor request requires fresh explicit consent. #{disclosure(repo, instruction_paths(repo))}"
    end
    return run_continuation(options, repo) if options[:continue_run]
    run_live(options, repo)
  rescue Error, ReservationError => error
    warn error.message
    1
  end
end

exit AgentBuild.main if $PROGRAM_NAME == __FILE__

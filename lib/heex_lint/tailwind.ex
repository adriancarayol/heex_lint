defmodule HeexLint.Tailwind do
  @moduledoc """
  Asks the project's own Tailwind v4 which classes generate CSS.

  Two ways, tried in order for each stylesheet:

    * **Node**: when `node` is installed and a `node_modules` is in reach of the
      stylesheet or of a stylesheet it imports, a long-lived Node process looks for
      the project's `tailwindcss` from there. It loads the design system with its
      imports and plugins and answers with spelling and variant suggestions. One that
      exits before its first answer leaves the question to the standalone CLI.
    * **Standalone CLI**: otherwise, the `tailwind` binary Phoenix installs
      in `_build/` (or `:tailwind_bin`) builds the theme with the
      candidates as `@source inline(...)`, and a class is known when its
      selector is in the output. No suggestions this way, and each question is
      a build, so `expect/3` lets a first question carry the likely next ones.

  When neither works, `unknown/2` returns nil and rules fall back to the
  class grammar. Answers are cached for the run, per stylesheet.

  Neither process can outlive the linter or take longer than a deadline: through
  Node, 60 seconds for a stylesheet's first answer and 30 for later ones, and through
  the standalone binary 60 for each question. `HEEX_LINT_TAILWIND_TIMEOUT`, a number of
  milliseconds, replaces these. A
  process past its deadline is killed and that stylesheet uses the grammar for
  the rest of the run, with a warning. Two such failures in a row turn the
  oracle off. Node only starts once a question needs it.
  """

  use GenServer

  alias HeexLint.Grammar.Classes
  alias HeexLint.Theme

  # Only there to catch a dead Tailwind. A loaded machine can take seconds over a
  # warm answer, and a timeout costs the rest of the run its project classes.
  @first_timeout 60_000
  @timeout 30_000

  # The most Process.send_after and a receive take.
  @max_timeout 4_294_967_295

  # How long a caller waits for any question to be answered: a question's deadline can
  # end in a retry through the binary. The margin is for an oracle that cannot answer
  # at all.
  @calls_ahead 3
  @call_margin 5_000

  # Far past any real class, as in the Node worker: a class past either limit is
  # not judged.
  @max_candidate_length 10_000
  @max_variants 64

  # Far past the text classes of a real project. A question has one deadline, and
  # the words of a data file must not be what runs it out. Past this they ask as they
  # come up.
  @max_expected 2_000

  @no_tailwind "neither the tailwindcss package nor a tailwind binary was found"

  @font_size ~r/(?:^|[;{\s])font-size\s*:/

  # The standalone binary reads no stdin, so nothing tells it the linter died: a
  # build started like this is killed, and its directory removed, when stdin closes,
  # whatever ended the VM. The removal comes first: once the build is gone, the wrapper
  # stops this watcher. The
  # wrapper leads its process group, which takes along whatever the build started.
  @guarded_build ~S"""
  exec 3<&0
  "$@" </dev/null 3<&- &
  build=$!
  { while read -r _ <&3; do :; done; rm -rf "$HEEX_LINT_BUILD_DIR"; kill -KILL "$build"; kill -KILL -$$; } >/dev/null 2>&1 &
  watcher=$!
  wait "$build"
  status=$?
  kill -KILL "$watcher" 2>/dev/null
  exit "$status"
  """

  @type unknown :: %{token: String.t(), suggestion: String.t() | nil, base_known: boolean()}

  ## Client

  @doc """
  Starts an oracle for one run. It ends with the calling process, which a crash
  of the oracle does not take down: questions then answer nil.
  """
  def start(project),
    do: GenServer.start(__MODULE__, {Map.take(project, [:root, :settings]), self()})

  @doc "Stops an oracle."
  def stop(nil), do: :ok

  def stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  @doc """
  The tokens the project's Tailwind (for the project's current theme entry)
  does not know, with suggestions, or nil when no Tailwind can be asked.
  """
  @spec unknown(HeexLint.Project.t(), [String.t()]) :: [unknown()] | nil
  def unknown(_project, []), do: []

  def unknown(project, tokens) do
    cond do
      project.entry == nil ->
        nil

      project.oracle == nil ->
        nil

      true ->
        ask(project.oracle, {:unknown, project.entry, Enum.uniq(tokens)})
    end
  end

  @doc """
  Those of `tokens` the project's Tailwind generates. None when it cannot be
  asked, so that a caller keeps treating them as unknown.
  """
  @spec known(HeexLint.Project.t(), [String.t()]) :: MapSet.t(String.t())
  def known(project, tokens) do
    case unknown(project, tokens) do
      nil -> MapSet.new()
      unknown -> MapSet.difference(MapSet.new(tokens), MapSet.new(unknown, & &1.token))
    end
  end

  @doc """
  Whether the Tailwind that builds `entry` generates a font size for `token`, a
  `text-*` class, or nil when it cannot be asked.
  """
  @spec font_size?(pid(), String.t(), String.t()) :: boolean() | nil
  def font_size?(pid, entry, token), do: ask(pid, {:font_size, entry, [token]})

  @doc """
  Says `tokens` may come up in `font_size?/3`. With the standalone binary, where each
  question is a build, the next such question about `entry` that has to reach it asks
  about them too. Through Node a question costs little and these are not asked about,
  where each unknown class would cost a search of every class Tailwind knows. This
  starts nothing, and without such a question nothing ever does.
  """
  @spec expect(pid(), String.t(), [String.t()]) :: :ok
  def expect(_pid, _entry, []), do: :ok
  def expect(pid, entry, tokens), do: GenServer.cast(pid, {:expect, entry, tokens})

  @doc """
  Whether a question about the project's current theme can come back with a suggestion.
  Only Node's answers have them, so through the standalone binary a question asked for
  one is a build that can say nothing. This starts nothing.
  """
  @spec suggests?(HeexLint.Project.t()) :: boolean()
  def suggests?(%{entry: nil}), do: false
  def suggests?(project), do: match?({:node, _}, status(project.oracle, project.entry))

  @doc "The strategy the oracle uses for `entry`, and why, for diagnostics."
  def status(nil, _entry), do: {:none, "not started"}

  def status(pid, entry) do
    GenServer.call(pid, {:status, entry}, call_timeout())
  catch
    :exit, _ -> {:none, "the oracle stopped"}
  end

  @doc "The warnings an oracle collected, such as a theme that could not be built."
  def warnings(nil), do: []

  def warnings(pid) do
    GenServer.call(pid, :warnings, call_timeout())
  catch
    :exit, _ ->
      [
        "The Tailwind oracle stopped during the run; the Tailwind build was unavailable, so rules used the class grammar for some files."
      ]
  end

  # Every deadline ends in an answer, so a caller waits as long as questions are being
  # answered, however many are ahead of it. A whole wait with none answered is an
  # oracle that cannot answer, which costs the caller's file its project classes and
  # not the run.
  defp ask(pid, request) do
    started = System.monotonic_time(:millisecond)

    try do
      await(pid, :gen_server.send_request(pid, request), nil, started)
    catch
      :exit, {:timeout, _call} -> gave_up(pid, {:timeout, waited(started)})
      :exit, reason -> gave_up(pid, reason)
    end
  end

  # Nothing is known of the count before the first wait, so a question that gets no
  # answer waits twice.
  defp await(pid, pending, seen, started) do
    case :gen_server.wait_response(pending, call_timeout()) do
      {:reply, answer} ->
        answer

      {:error, {reason, _server}} ->
        gave_up(pid, reason)

      :timeout ->
        case answered_count(pid) do
          count when seen == nil or count != seen ->
            await(pid, pending, count, started)

          _ ->
            :gen_server.receive_response(pending, 0)
            gave_up(pid, {:timeout, waited(started)})
        end
    end
  end

  defp waited(started), do: System.monotonic_time(:millisecond) - started

  defp answered_count(pid), do: GenServer.call(pid, :answered, @call_margin)

  defp gave_up(pid, reason) do
    GenServer.cast(
      pid,
      {:warn,
       "The Tailwind oracle did not answer (#{exit_reason(reason)}); the Tailwind build was unavailable, so rules checked a file with the class grammar and may report project classes as unknown."}
    )

    nil
  end

  defp exit_reason({:timeout, waited}), do: "timed out after #{round(waited / 1000)} s"
  defp exit_reason({reason, _call}), do: inspect(reason)
  defp exit_reason(reason), do: inspect(reason)

  defp call_timeout, do: min(timeout_for(true) * @calls_ahead + @call_margin, @max_timeout)

  @doc false
  # How long a question may take, in milliseconds. A stylesheet's first answer pays
  # for loading Tailwind. Anything but a positive number replaces neither.
  def timeout_for(cold?) do
    case parse_timeout(System.get_env("HEEX_LINT_TAILWIND_TIMEOUT")) do
      nil -> if(cold?, do: @first_timeout, else: @timeout)
      milliseconds -> milliseconds
    end
  end

  defp parse_timeout(nil), do: nil

  defp parse_timeout(text) do
    case text |> String.trim() |> HeexLint.Grammar.Validators.parse_float() do
      {number, ""} when number > 0 -> number |> ceil() |> min(@max_timeout)
      _ -> nil
    end
  end

  defp seconds(milliseconds) when rem(milliseconds, 1000) == 0, do: div(milliseconds, 1000)
  defp seconds(milliseconds), do: milliseconds / 1000

  ## Server

  @impl true
  def init({project, owner}) do
    Process.monitor(owner)
    # A question too big for the pipe is still being written when a process exits, and
    # the port going down with that write would take this process along.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       project: project,
       strategies: %{},
       reasons: %{},
       port: nil,
       buffer: "",
       # The one question being worked on, and those waiting their turn.
       job: nil,
       waiting: [],
       answered: 0,
       expected: %{},
       warm: MapSet.new(),
       failures: 0,
       off: false,
       next: 1,
       cache: %{},
       warnings: []
     }}
  end

  @impl true
  def handle_call({:status, entry}, _from, state) do
    {strategy, state} = strategy(state, entry)
    {:reply, {strategy, state.reasons[entry]}, state}
  end

  def handle_call(:warnings, _from, state), do: {:reply, Enum.reverse(state.warnings), state}
  def handle_call(:answered, _from, state), do: {:reply, state.answered, state}

  def handle_call({kind, entry, tokens}, from, state) when kind in [:unknown, :font_size] do
    request = %{from: from, kind: kind, entry: entry, tokens: tokens}
    {:noreply, pump(%{state | waiting: state.waiting ++ [request]})}
  end

  @impl true
  def handle_cast({:warn, message}, state), do: {:noreply, warn(state, message)}

  def handle_cast({:expect, entry, tokens}, state) do
    expected = Map.update(state.expected, entry, tokens, &(&1 ++ tokens))
    {:noreply, %{state | expected: expected}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {lines, rest} = split_lines(state.buffer <> data)
    {:noreply, Enum.reduce(lines, %{state | buffer: rest}, &node_answer/2)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:noreply, node_exited(state, "exited with status #{status}")}

  def handle_info({:EXIT, port, reason}, %{port: port} = state) when reason != :normal,
    do: {:noreply, node_exited(state, "stopped reading its questions (#{inspect(reason)})")}

  # Trapping exits is for the port above, and hides nothing else.
  def handle_info({:EXIT, from, reason}, state) when is_pid(from) and reason != :normal,
    do: {:stop, reason, state}

  def handle_info({port, {:data, data}}, %{job: %{port: port} = job} = state) do
    {:noreply, %{state | job: %{job | output: keep_output(job.output, data)}}}
  end

  def handle_info({port, {:exit_status, status}}, %{job: %{port: port}} = state) do
    {:noreply, build_finished(state, status)}
  end

  def handle_info({:deadline, ref}, %{job: %{ref: ref} = job} = state) do
    state = stop_process_of(state, job)
    what = "did not answer about #{job.entry} within #{seconds(job.timeout)} s"
    {:noreply, transport_failed(state, job, what)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

  # From a process already stopped, or a deadline already met.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    kill(state.port)

    if state.job do
      kill(state.job[:port])
      clean_build(state.job)
    end

    :ok
  end

  ## Questions

  # One question at a time, since a deadline has to know which it is for. Everyone
  # waiting on a stylesheet shares the next question about it, so a project's files
  # cost one build between them, not one each.
  defp pump(%{job: nil, waiting: [first | _]} = state) do
    {requests, others} = Enum.split_with(state.waiting, &(&1.entry == first.entry))
    {strategy, state} = strategy(%{state | waiting: others}, first.entry)
    asked = uncached(state, first.entry, Enum.flat_map(requests, & &1.tokens))
    {expected, state} = take_expected(state, strategy, first.entry, requests, asked)
    job = %{entry: first.entry, requests: requests, missing: asked ++ expected}

    cond do
      strategy == :none or asked == [] -> state |> reply_all(job) |> pump()
      strategy == :node -> ask_node(state, job)
      strategy == :standalone -> start_build(state, job)
    end
  end

  defp pump(state), do: state

  defp uncached(state, entry, tokens) do
    tokens |> Enum.uniq() |> Enum.reject(&Map.has_key?(state.cache, {entry, &1}))
  end

  # Only a font size question that has to run a build takes them along. The rest of
  # the run then finds them answered.
  defp take_expected(state, :standalone, entry, requests, [_ | _] = asked) do
    if Enum.any?(requests, &(&1.kind == :font_size)) do
      {expected, others} = Map.pop(state.expected, entry, [])
      taken = state |> uncached(entry, expected) |> Kernel.--(asked) |> Enum.take(@max_expected)
      {taken, %{state | expected: others}}
    else
      {[], state}
    end
  end

  defp take_expected(state, _strategy, _entry, _requests, _asked), do: {[], state}

  defp reply_all(state, job) do
    Enum.each(job.requests, &GenServer.reply(&1.from, answer(state, &1)))
    %{state | job: nil, answered: state.answered + 1}
  end

  defp answer(state, %{kind: kind, entry: entry, tokens: tokens}) do
    cond do
      state.strategies[entry] == :none ->
        nil

      kind == :font_size ->
        Map.get(state.cache, {entry, hd(tokens)}) == :font_size

      true ->
        for token <- tokens,
            result = Map.get(state.cache, {entry, token}),
            is_map(result),
            do: result
    end
  end

  # The deadline runs from here, and `ref` tells a late one from the current one.
  defp arm(job, timeout) do
    ref = make_ref()

    Map.merge(job, %{
      ref: ref,
      timeout: timeout,
      timer: Process.send_after(self(), {:deadline, ref}, timeout)
    })
  end

  defp disarm(job), do: Process.cancel_timer(job.timer)

  defp answered(state, job, results, font_sizes) do
    disarm(job)

    state
    |> cache(job.entry, job.missing, results, font_sizes)
    |> Map.merge(%{failures: 0, warm: MapSet.put(state.warm, job.entry)})
    |> reply_all(job)
    |> pump()
  end

  defp cache(state, entry, missing, results, font_sizes) do
    by_token = Map.new(results, &{&1.token, &1})
    font_sizes = MapSet.new(font_sizes)

    cache =
      Enum.reduce(missing, state.cache, fn token, cache ->
        verdict =
          cond do
            Map.has_key?(by_token, token) -> Map.fetch!(by_token, token)
            MapSet.member?(font_sizes, token) -> :font_size
            true -> :known
          end

        Map.put(cache, {entry, token}, verdict)
      end)

    %{state | cache: cache}
  end

  defp put_strategy(state, entry, strategy),
    do: %{state | strategies: Map.put(state.strategies, entry, strategy)}

  # The way to ask about `entry`, decided once per stylesheet.
  defp strategy(state, entry) do
    case Map.fetch(state.strategies, entry) do
      {:ok, strategy} ->
        {strategy, state}

      :error when state.off ->
        {:none, put_strategy(state, entry, :none)}

      :error ->
        state =
          cond do
            node_available?() and node_modules_in_reach?(entry, state.project.root) ->
              put_strategy(state, entry, :node)

            standalone_binary(state.project) ->
              put_strategy(state, entry, :standalone)

            true ->
              no_tailwind(state, entry)
          end

        {state.strategies[entry], state}
    end
  end

  defp no_tailwind(state, entry) do
    state
    |> put_strategy(entry, :none)
    |> Map.update!(:reasons, &Map.put(&1, entry, @no_tailwind))
  end

  # What was being asked did this, so that stylesheet stops being asked: a restart
  # would get no other answer. Another stylesheet may start a new process, but two
  # failures with no good answer between them turn the oracle off.
  defp transport_failed(state, job, what) do
    if job, do: disarm(job)

    state = %{state | failures: state.failures + 1, warm: MapSet.new()}
    state = if job, do: put_strategy(%{state | job: nil}, job.entry, :none), else: state

    state =
      if state.failures >= 2 do
        strategies = Map.new(state.strategies, fn {entry, _strategy} -> {entry, :none} end)

        warn(
          %{state | off: true, strategies: strategies},
          "The Tailwind process failed twice (it #{what}); the Tailwind build is unavailable, so rules use the class grammar for the rest of this run."
        )
      else
        warn(
          state,
          "The Tailwind process #{what} and was stopped; the Tailwind build is unavailable for that stylesheet, so rules use the class grammar there for the rest of this run and may report project classes as unknown."
        )
      end

    state = if job, do: reply_all(state, job), else: state
    pump(state)
  end

  ## Processes

  defp open_port(nil, _args, _opts), do: nil

  defp open_port(executable, args, opts) do
    Port.open(
      {:spawn_executable, executable},
      [:binary, :exit_status, :use_stdio, {:args, args} | opts]
    )
  rescue
    # No such file, not executable, or no file descriptors left.
    _ -> nil
  end

  # Port.close only closes the pipes, and a process that does not read them never
  # finds out. A port program leads its own process group, so this reaches what it
  # started too. When even this cannot run, closing still ends both of ours: the
  # worker and the guarded build each watch stdin.
  defp kill(nil), do: :ok

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> kill_os_process(os_pid)
      _ -> :ok
    end

    close(port)
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp kill_os_process(os_pid) do
    case :os.type() do
      {:win32, _} ->
        System.cmd("taskkill", ["/F", "/T", "/PID", to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        script = "kill -KILL -#{os_pid} 2>/dev/null; kill -KILL #{os_pid} 2>/dev/null; :"
        System.cmd("sh", ["-c", script], stderr_to_stdout: true)
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp stop_process_of(state, %{port: _} = job) do
    kill(job.port)
    clean_build(job)
    state
  end

  defp stop_process_of(state, _node_job) do
    kill(state.port)
    %{state | port: nil, buffer: ""}
  end

  ## Node

  defp ask_node(state, job) do
    case state.port || start_node(state) do
      nil ->
        build_failed_in_node(state, job, "node could not be started")

      port ->
        id = state.next
        request = JSON.encode!(%{id: id, css: job.entry, candidates: job.missing})
        timeout = timeout_for(not MapSet.member?(state.warm, job.entry))
        # A send, as nothing a worker does with its stdin can suspend this process
        # and with it the deadline.
        send(port, {self(), {:command, request <> "\n"}})

        job = job |> Map.merge(%{id: id, new_process: state.port == nil}) |> arm(timeout)
        %{state | port: port, next: id + 1, job: job}
    end
  end

  defp start_node(state) do
    open_port(System.find_executable("node"), [oracle_script()], cd: state.project.root)
  end

  defp oracle_script, do: Application.app_dir(:heex_lint, "priv/tailwind_oracle.mjs")

  defp node_available? do
    System.find_executable("node") != nil and File.regular?(oracle_script())
  end

  defp node_job(%{job: %{id: _} = job}), do: job
  defp node_job(_state), do: nil

  defp node_exited(state, what) do
    job = node_job(state)
    state = %{state | port: nil, buffer: ""}

    case job do
      # A process that never answered says nothing against the theme, and may be a
      # `node` that cannot run at all, such as a version manager's shim with no version
      # set. So this is no failure: the binary answers, as for a theme Node cannot load.
      %{new_process: true} ->
        disarm(job)
        build_failed_in_node(state, job, "node #{what}")

      _ ->
        transport_failed(state, job, what)
    end
  end

  # Whether Node might find Tailwind for `entry`, which only it can say: it follows a
  # package's `style` condition where the theme read does not, so an import can lead
  # it to a stylesheet that imports Tailwind and that this side never reads. What this
  # side can say is that nothing is there to find, which spares the usual Phoenix
  # project a Node process: the two only part ways at a package, so before they do,
  # a stylesheet they both read has a node_modules in reach. Node also looks from the
  # directory it runs in, which is the root.
  defp node_modules_in_reach?(entry, root) do
    node_modules_above?(root) or reaches_node_modules?([entry], MapSet.new())
  end

  defp node_modules_above?(dir) do
    File.dir?(Path.join(dir, "node_modules")) or
      (Path.dirname(dir) != dir and node_modules_above?(Path.dirname(dir)))
  end

  # What a stylesheet imports is read once, so a cycle ends.
  defp reaches_node_modules?([], _seen), do: false

  defp reaches_node_modules?([file | rest], seen) do
    cond do
      MapSet.member?(seen, file) -> reaches_node_modules?(rest, seen)
      node_modules_above?(Path.dirname(file)) -> true
      true -> reaches_node_modules?(rest ++ imports_of(file), MapSet.put(seen, file))
    end
  end

  defp imports_of(file) do
    case File.read(file) do
      {:ok, css} ->
        css
        |> Theme.parse_imports()
        |> Enum.map(&Theme.resolve_stylesheet(Path.dirname(file), &1))
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp node_answer(line, %{job: %{id: id} = job} = state) do
    case JSON.decode(line) do
      {:ok, %{"id" => ^id, "ok" => true} = answer} ->
        results =
          Enum.map(answer["unknown"], fn item ->
            %{
              token: item["token"],
              suggestion: item["suggestion"],
              base_known: item["baseKnown"] == true
            }
          end)

        answered(state, job, results, answer["fontSizes"])

      {:ok, %{"id" => ^id} = answer} ->
        disarm(job)
        reason = to_string(answer["reason"])

        cond do
          answer["final"] == true ->
            state |> Map.put(:job, nil) |> no_build(job, reason)

          # No failure: a node_modules with no Tailwind in it says nothing about the theme.
          answer["absent"] == true and standalone_binary(state.project) == nil ->
            state |> Map.put(:job, nil) |> no_tailwind(job.entry) |> reply_all(job) |> pump()

          true ->
            build_failed_in_node(state, job, reason)
        end

      _ ->
        state
    end
  end

  defp node_answer(_line, state), do: state

  # Fall back to the standalone CLI, then to the grammar.
  defp build_failed_in_node(state, job, reason) do
    job = Map.drop(job, [:id, :new_process, :ref, :timer, :timeout])
    state = %{state | job: nil}

    case standalone_binary(state.project) do
      nil ->
        no_build(state, job, reason)

      _bin ->
        state
        |> Map.update!(:reasons, &Map.put(&1, job.entry, reason))
        |> put_strategy(job.entry, :standalone)
        |> start_build(job)
    end
  end

  defp no_build(state, job, reason) do
    state
    |> Map.update!(:reasons, &Map.put(&1, job.entry, reason))
    |> put_strategy(job.entry, :none)
    |> warn(
      "The Tailwind theme at #{job.entry} could not be built (#{reason}); the Tailwind build is unavailable there, so rules use the class grammar."
    )
    |> reply_all(job)
    |> pump()
  end

  ## Standalone CLI

  defp standalone_binary(project) do
    configured = project.settings[:tailwind_bin]

    cond do
      configured && File.regular?(Path.expand(configured, project.root)) ->
        Path.expand(configured, project.root)

      found =
          ["_build/tailwind-*", "apps/*/_build/tailwind-*"]
          |> Enum.flat_map(&Path.wildcard(Path.join(project.root, &1)))
          |> Enum.find(&File.regular?/1) ->
        found

      true ->
        System.find_executable("tailwindcss")
    end
  end

  # One deadline for the whole question, however many builds it takes. A chunk is
  # classes and whether to build what their variants stand on as well.
  defp start_build(state, job) do
    checked = Enum.filter(job.missing, &checkable?/1)

    job
    |> Map.merge(%{
      bin: standalone_binary(state.project),
      chunks: if(checked == [], do: [], else: [{checked, true}]),
      unknown: [],
      font_sizes: [],
      theme_builds: false
    })
    |> arm(timeout_for(true))
    |> then(&next_build(state, &1))
  end

  defp checkable?(token) do
    {variants, _base} = Classes.split_variants(token)
    String.length(token) <= @max_candidate_length and length(variants) <= @max_variants
  end

  defp next_build(state, %{chunks: []} = job),
    do: answered(state, job, job.unknown, job.font_sizes)

  defp next_build(state, %{chunks: [chunk | _]} = job) do
    run_build(state, job, chunk)
  rescue
    error -> build_error(state, job, Exception.message(error))
  end

  defp run_build(state, job, {tokens, with_bases}) do
    dir = Path.join(System.tmp_dir!(), build_dir_name())
    # Not mkdir_p: a directory already there is not this build's to read.
    File.mkdir!(dir)

    bases =
      for token <- tokens,
          with_bases,
          {variants, base} = Classes.split_variants(token),
          bare <- bare_candidates(variants, base),
          do: bare

    probes = Enum.flat_map(tokens, &font_size_probes/1)

    candidates =
      Enum.uniq(tokens ++ bases ++ probes)
      |> Enum.reject(&String.contains?(&1, ["\"", "\\", "{", "}"]))

    input = Path.join(dir, "input.css")
    args = ["--input", input, "--output", Path.join(dir, "output.css")]

    # A rule each, since Tailwind splits a list with its bracket-aware split: in one
    # list, the open bracket of `text-[foo` would keep all that follows in one candidate.
    File.write!(input, [
      ~s(@import "#{job.entry}";\n),
      Enum.map(candidates, &~s[@source inline("#{&1}");\n])
    ])

    env = [{~c"HEEX_LINT_BUILD_DIR", String.to_charlist(dir)}]

    case open_build(job.bin, args, cd: Path.dirname(job.entry), env: env) do
      nil ->
        File.rm_rf(dir)
        build_error(state, job, "it could not be started")

      port ->
        %{state | job: Map.merge(job, %{port: port, dir: dir, output: ""})}
    end
  end

  defp open_build(bin, args, opts) do
    opts = [:stderr_to_stdout | opts]

    case System.find_executable("sh") do
      nil -> open_port(bin, args, opts)
      sh -> open_port(sh, ["-c", @guarded_build, "heex_lint_tailwind", bin | args], opts)
    end
  end

  defp keep_output(output, _data) when byte_size(output) > 4096, do: output
  defp keep_output(output, data), do: output <> data

  # Integers from System.unique_integer repeat between VMs, and two linters can share
  # a temp directory.
  defp build_dir_name,
    do: "heex_lint_#{System.pid()}_#{Base.encode16(:rand.bytes(8), case: :lower)}"

  defp clean_build(%{dir: dir}), do: File.rm_rf(dir)
  defp clean_build(_job), do: :ok

  defp build_finished(%{job: job} = state, 0) do
    [{tokens, _bases} | chunks] = job.chunks
    output = File.read(Path.join(job.dir, "output.css"))
    clean_build(job)

    case output do
      {:ok, css} ->
        {unknown, font_sizes} = read_build(css, tokens)

        next_build(state, %{
          job
          | chunks: chunks,
            unknown: job.unknown ++ unknown,
            font_sizes: job.font_sizes ++ font_sizes,
            theme_builds: true
        })

      {:error, reason} ->
        build_error(state, job, "it wrote no output (#{reason})")
    end
  end

  # A plugin that throws on a class takes the whole build down with it, where the
  # Node worker's answer costs that class alone. So when the theme builds without any
  # classes, they are halved until the class at fault is by itself, and it goes
  # unjudged.
  defp build_finished(%{job: job} = state, _status) do
    clean_build(job)
    [chunk | chunks] = job.chunks

    case after_failure(chunk) do
      :theme ->
        build_error(state, job, String.slice(job.output, 0, 300))

      parts ->
        parts = if job.theme_builds, do: parts, else: [{[], false} | parts]
        next_build(state, %{job | chunks: parts ++ chunks})
    end
  end

  defp after_failure({[], _bases}), do: :theme

  defp after_failure({[token], true}) do
    {variants, base} = Classes.split_variants(token)
    if bare_candidates(variants, base) == [], do: [], else: [{[token], false}]
  end

  defp after_failure({[_token], false}), do: []

  defp after_failure({tokens, bases}) do
    {left, right} = Enum.split(tokens, div(length(tokens), 2))
    [{left, bases}, {right, bases}]
  end

  defp read_build(css, tokens) do
    known? = &selector?(css, &1)

    unknown =
      for token <- tokens, not known?.(token) do
        {variants, base} = Classes.split_variants(token)
        bare = bare_candidates(variants, base)
        %{token: token, suggestion: nil, base_known: Enum.any?(bare, known?)}
      end

    font_sizes =
      Enum.filter(tokens, fn token ->
        token |> font_size_probes() |> Enum.any?(&sets_font_size?(css, &1))
      end)

    {unknown, font_sizes}
  end

  # What generates a font size is what Tailwind's answer for the class would say, and
  # the output cannot tell that from a rule the theme's own CSS has for the class, as
  # in `.text-primary { font-size: 1rem }` or `.card .text-primary { ... }`. A plugin
  # may also generate one with a selector just like those, as `.card .text-body`. So
  # the build is asked for the class under a variant that changes nothing, a name only
  # Tailwind can have written a rule for. Only `text-*` classes are ever asked about.
  # It goes after a prefix, and the build says which name that is.
  defp font_size_probes(token) do
    if String.starts_with?(Classes.normalize(token), "text-") do
      case Classes.split_variants(token) do
        {[], _base} ->
          ["[&]:" <> token]

        {[first | _], _base} ->
          ["[&]:" <> token, first <> ":[&]:" <> String.replace_prefix(token, first <> ":", "")]
      end
    else
      []
    end
  end

  defp build_error(state, job, message) do
    disarm(job)

    state
    |> Map.put(:job, nil)
    |> put_strategy(job.entry, :none)
    |> warn(
      "The Tailwind theme at #{job.entry} could not be built with #{job.bin}: #{message}. The Tailwind build is unavailable there, so rules use the class grammar."
    )
    |> reply_all(job)
    |> pump()
  end

  @doc false
  # Whether the output has `class` as a whole selector: .flex-col does not make
  # flex known, nor .tw\:flex make tw:fle known.
  def selector?(css, class), do: selector_ends(css, class) != []

  @doc false
  # Whether the output's rule for `class` sets a font size, directly or inside an
  # @media a variant wraps it in, as Tailwind's own answer for a candidate would.
  def sets_font_size?(css, class) do
    css
    |> selector_ends(class)
    |> Enum.any?(&Regex.match?(@font_size, rule_body(css, &1)))
  end

  defp selector_ends(css, class) do
    css
    |> :binary.matches("." <> css_escape(class))
    |> Enum.map(fn {at, length} -> at + length end)
    |> Enum.filter(&selector_end?(css, &1))
  end

  # The block that follows a selector, with the blocks nested in it.
  defp rule_body(css, at) do
    rest = binary_part(css, at, byte_size(css) - at)

    case :binary.match(rest, "{") do
      {open, 1} ->
        block = binary_part(rest, open, byte_size(rest) - open)
        binary_part(block, 0, block_length(block, 0, 0))

      :nomatch ->
        ""
    end
  end

  defp block_length(<<>>, _depth, length), do: length
  defp block_length(<<"}", _::binary>>, 1, length), do: length + 1

  defp block_length(<<"{", rest::binary>>, depth, length),
    do: block_length(rest, depth + 1, length + 1)

  defp block_length(<<"}", rest::binary>>, depth, length),
    do: block_length(rest, depth - 1, length + 1)

  defp block_length(<<_, rest::binary>>, depth, length), do: block_length(rest, depth, length + 1)

  defp selector_end?(css, at) when at == byte_size(css), do: true

  defp selector_end?(css, at) do
    c = :binary.at(css, at)
    not (c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?-, ?_, ?\\] or c >= 0x80)
  end

  # The utility a token's variants stand on, to tell a misspelled variant from
  # a misspelled utility. A project's prefix is a variant segment in the source
  # and stays on the bare utility: tw:hovr:flex stands on tw:flex, and under
  # prefix(tw) a plain flex generates nothing. The build says which name is the
  # prefix: a real variant on a class that does not exist generates nothing either.
  defp bare_candidates([], _base), do: []
  defp bare_candidates([_only], base), do: [base]
  defp bare_candidates([first | _], base), do: [base, first <> ":" <> base]

  @doc false
  # CSS.escape for an identifier, as Tailwind escapes class selectors.
  def css_escape(text) do
    chars = String.to_charlist(text)

    chars
    |> Enum.with_index()
    |> Enum.map_join(fn {c, i} ->
      cond do
        c == 0 -> "�"
        c in 0x01..0x1F or c == 0x7F -> "\\" <> Integer.to_string(c, 16) <> " "
        i == 0 and c in ?0..?9 -> "\\" <> Integer.to_string(c, 16) <> " "
        i == 1 and c in ?0..?9 and hd(chars) == ?- -> "\\" <> Integer.to_string(c, 16) <> " "
        i == 0 and c == ?- and length(chars) == 1 -> "\\-"
        c >= 0x80 or c in [?-, ?_] or c in ?0..?9 or c in ?a..?z or c in ?A..?Z -> <<c::utf8>>
        true -> "\\" <> <<c::utf8>>
      end
    end)
  end

  defp warn(state, message), do: %{state | warnings: [message | state.warnings]}
end

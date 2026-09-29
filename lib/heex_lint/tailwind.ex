defmodule HeexLint.Tailwind do
  @moduledoc """
  Asks the project's own Tailwind v4 which classes generate CSS.

  Two ways, tried in order:

    * **Node**: when `node` and the project's `tailwindcss` (or
      `@tailwindcss/node`) are installed, a long-lived Node process loads
      the design system with its imports and plugins and answers with
      spelling and variant suggestions.
    * **Standalone CLI**: otherwise, the `tailwind` binary Phoenix installs
      in `_build/` (or `:tailwind_bin`) builds the theme with the
      candidates as `@source inline(...)`, and a class is known when its
      selector is in the output. No suggestions this way.

  When neither works, `unknown/2` returns nil and rules fall back to the
  class grammar. Answers are cached for the run.
  """

  use GenServer

  alias HeexLint.Grammar.Classes

  @timeout 120_000

  @type unknown :: %{token: String.t(), suggestion: String.t() | nil, base_known: boolean()}

  ## Client

  @doc "Starts an oracle for one run."
  def start_link(project), do: GenServer.start_link(__MODULE__, project)

  @doc "Stops an oracle."
  def stop(nil), do: :ok

  def stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  @doc """
  The tokens Tailwind does not know, with suggestions, or nil when no
  Tailwind can be asked.
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
        GenServer.call(project.oracle, {:unknown, project.entry, Enum.uniq(tokens)}, @timeout)
    end
  end

  @doc "The strategy an oracle uses, and why, for diagnostics."
  def status(nil), do: {:none, "not started"}
  def status(pid), do: GenServer.call(pid, :status, @timeout)

  @doc "The warnings an oracle collected, such as a theme that could not be built."
  def warnings(nil), do: []
  def warnings(pid), do: GenServer.call(pid, :warnings, @timeout)

  ## Server

  @impl true
  def init(project) do
    {:ok,
     %{
       project: project,
       strategy: nil,
       port: nil,
       buffer: "",
       pending: %{},
       next: 1,
       cache: %{},
       reason: nil,
       warnings: []
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    state = ensure_strategy(state)
    {:reply, {state.strategy, state.reason}, state}
  end

  def handle_call(:warnings, _from, state), do: {:reply, Enum.reverse(state.warnings), state}

  def handle_call({:unknown, entry, tokens}, from, state) do
    state = ensure_strategy(state)
    missing = Enum.reject(tokens, &Map.has_key?(state.cache, {entry, &1}))

    case state.strategy do
      :none ->
        {:reply, nil, state}

      :standalone ->
        state = run_standalone(state, entry, missing)
        {:reply, answer(state, entry, tokens), state}

      :node when missing == [] ->
        {:reply, answer(state, entry, tokens), state}

      :node ->
        id = state.next
        request = JSON.encode!(%{id: id, css: entry, candidates: missing})
        Port.command(state.port, request <> "\n")
        pending = Map.put(state.pending, id, {from, entry, tokens, missing})
        {:noreply, %{state | pending: pending, next: id + 1}}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data
    {lines, rest} = split_lines(buffer)
    state = Enum.reduce(lines, %{state | buffer: rest}, &node_answer/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    for {_id, {from, _entry, _tokens, _missing}} <- state.pending, do: GenServer.reply(from, nil)

    {:noreply,
     %{state | strategy: :none, port: nil, pending: %{}, reason: "the Tailwind process exited"}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when port != nil do
    Port.close(port)
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp node_answer(line, state) do
    case JSON.decode(line) do
      {:ok, %{"id" => id} = answer} ->
        case Map.pop(state.pending, id) do
          {nil, _} ->
            state

          {{from, entry, tokens, missing}, pending} ->
            state = %{state | pending: pending}

            case answer do
              %{"ok" => true, "unknown" => unknown} ->
                results =
                  Enum.map(unknown, fn item ->
                    %{
                      token: item["token"],
                      suggestion: item["suggestion"],
                      base_known: item["baseKnown"] == true
                    }
                  end)

                state = cache(state, entry, missing, results)
                GenServer.reply(from, answer(state, entry, tokens))
                state

              %{"ok" => false, "reason" => reason} ->
                # Fall back to the standalone CLI, then to the grammar.
                state = %{state | reason: reason}

                case standalone_binary(state.project) do
                  nil ->
                    GenServer.reply(from, nil)

                    warn(
                      %{state | strategy: :none},
                      "The Tailwind theme at #{entry} could not be built (#{reason}); no_unknown_classes is using the class grammar."
                    )

                  _bin ->
                    state = run_standalone(%{state | strategy: :standalone}, entry, missing)
                    GenServer.reply(from, answer(state, entry, tokens))
                    state
                end
            end
        end

      _ ->
        state
    end
  end

  defp run_standalone(state, entry, missing) do
    case standalone(state.project, entry, missing) do
      {:ok, results} ->
        cache(state, entry, missing, results)

      {:error, message} ->
        warn(
          %{state | strategy: :none},
          message <> " no_unknown_classes is using the class grammar."
        )
    end
  end

  defp cache(state, entry, missing, results) do
    by_token = Map.new(results, &{&1.token, &1})

    cache =
      Enum.reduce(missing, state.cache, fn token, cache ->
        Map.put(cache, {entry, token}, Map.get(by_token, token, :known))
      end)

    %{state | cache: cache}
  end

  defp answer(%{strategy: :none}, _entry, _tokens), do: nil

  defp answer(state, entry, tokens) do
    for token <- tokens, result = Map.get(state.cache, {entry, token}), is_map(result), do: result
  end

  defp ensure_strategy(%{strategy: nil} = state) do
    node = System.find_executable("node")
    script = Application.app_dir(:heex_lint, "priv/tailwind_oracle.mjs")

    cond do
      node && File.regular?(script) && node_tailwind?(state.project) ->
        port =
          Port.open({:spawn_executable, node}, [
            :binary,
            :exit_status,
            :use_stdio,
            args: [script],
            cd: state.project.root
          ])

        %{state | strategy: :node, port: port}

      standalone_binary(state.project) ->
        %{state | strategy: :standalone}

      true ->
        %{
          state
          | strategy: :none,
            reason: "neither the tailwindcss package nor a tailwind binary was found"
        }
    end
  end

  defp ensure_strategy(state), do: state

  # tailwindcss is installed where Node would resolve it from the theme.
  defp node_tailwind?(project) do
    project.entry
    |> Path.dirname()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.take(32)
    |> Enum.uniq()
    |> Enum.any?(fn dir ->
      File.regular?(Path.join([dir, "node_modules", "tailwindcss", "package.json"]))
    end)
  end

  ## Standalone CLI

  defp standalone_binary(project) do
    configured = project.settings[:tailwind_bin]

    cond do
      configured && File.regular?(Path.expand(configured, project.root)) ->
        Path.expand(configured, project.root)

      found =
          project.root
          |> Path.join("_build/tailwind-*")
          |> Path.wildcard()
          |> Enum.find(&File.regular?/1) ->
        found

      true ->
        System.find_executable("tailwindcss")
    end
  end

  defp standalone(_project, _entry, []), do: {:ok, []}

  defp standalone(project, entry, tokens) do
    bin = standalone_binary(project)
    dir = Path.join(System.tmp_dir!(), "heex_lint_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      bases =
        for token <- tokens,
            {variants, base} = Classes.split_variants(token),
            variants != [],
            do: base

      candidates =
        Enum.uniq(tokens ++ bases) |> Enum.reject(&String.contains?(&1, ["\"", "\\", "{", "}"]))

      input = Path.join(dir, "input.css")
      output = Path.join(dir, "output.css")

      File.write!(input, """
      @import "#{entry}";
      @source inline("#{Enum.join(candidates, " ")}");
      """)

      case System.cmd(bin, ["--input", input, "--output", output],
             stderr_to_stdout: true,
             cd: project.root
           ) do
        {_out, 0} ->
          css = File.read!(output)
          known? = fn candidate -> String.contains?(css, "." <> css_escape(candidate)) end

          results =
            for token <- tokens, not known?.(token) do
              {variants, base} = Classes.split_variants(token)
              %{token: token, suggestion: nil, base_known: variants != [] and known?.(base)}
            end

          {:ok, results}

        {out, _status} ->
          {:error,
           "The Tailwind theme at #{entry} could not be built with #{bin}: #{String.slice(out, 0, 300)}."}
      end
    after
      File.rm_rf(dir)
    end
  end

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

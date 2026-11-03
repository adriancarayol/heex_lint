defmodule HeexLint.TailwindOracleTest do
  # Changes HEEX_LINT_TAILWIND_TIMEOUT and PATH, which the whole VM reads.
  use ExUnit.Case, async: false

  import HeexLint.TestProject

  alias HeexLint.{Project, Tailwind}

  @moduletag :tmp_dir

  # Every fake gives up by itself, so a test that fails leaves nothing behind.
  @give_up_ms 30_000

  @template ~s|<div class="flex zorblax" />|

  setup do
    previous = System.get_env("HEEX_LINT_TAILWIND_TIMEOUT")
    path = System.get_env("PATH")

    on_exit(fn ->
      System.put_env("PATH", path)

      if previous,
        do: System.put_env("HEEX_LINT_TAILWIND_TIMEOUT", previous),
        else: System.delete_env("HEEX_LINT_TAILWIND_TIMEOUT")
    end)
  end

  defp deadline(milliseconds),
    do: System.put_env("HEEX_LINT_TAILWIND_TIMEOUT", to_string(milliseconds))

  defp page(template \\ @template),
    do: %{"lib/app_web/live/page_live.ex" => live(template)}

  defp write(dir, path, contents) do
    file = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, contents)
    file
  end

  defp script(dir, path, contents) do
    file = write(dir, path, contents)
    File.chmod!(file, 0o755)
    file
  end

  # What a fake appends each time it starts.
  defp pids(file) do
    case File.read(file) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&String.to_integer/1)
      {:error, _} -> []
    end
  end

  defp alive?(os_pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", to_string(os_pid)], stderr_to_stdout: true) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      _ -> false
    end
  end

  defp eventually(check, within \\ 5_000) do
    cond do
      check.() ->
        true

      within <= 0 ->
        false

      true ->
        Process.sleep(25)
        eventually(check, within - 25)
    end
  end

  defp gone?(os_pid), do: eventually(fn -> not alive?(os_pid) end)

  defp timed(fun) do
    {microseconds, result} = :timer.tc(fun)
    {div(microseconds, 1000), result}
  end

  # A stand-in for `node` on the PATH. It reads nothing and answers nothing, so
  # only a kill stops it: the sync form cannot even run a signal handler.
  defp fake_node(dir, form) do
    pid_file = Path.join(dir, "node.pids")
    real = System.find_executable("node")

    hang =
      case form do
        :async -> "setInterval(() => {}, 1000)"
        :sync -> "while (Date.now() < end) {}"
      end

    worker =
      write(dir, "fake/worker.js", """
      const end = Date.now() + #{@give_up_ms}
      setTimeout(() => process.exit(0), #{@give_up_ms})
      process.on("SIGTERM", () => {})
      process.on("SIGINT", () => {})
      process.on("SIGHUP", () => {})
      #{hang}
      """)

    script(dir, "fake/bin/node", """
    #!/bin/sh
    echo $$ >> "#{pid_file}"
    exec "#{real}" "#{worker}"
    """)

    System.put_env("PATH", Path.join(dir, "fake/bin") <> ":" <> System.get_env("PATH"))
    pid_file
  end

  # The real worker script, with a Tailwind that does what `body` says.
  defp fake_tailwind(dir, name \\ "fake", body) do
    pid_file = Path.join(dir, name <> ".pids")

    write(
      dir,
      "node_modules/tailwindcss/package.json",
      ~s({"name": "tailwindcss", "main": "index.js"})
    )

    write(dir, "node_modules/tailwindcss/index.js", """
    const fs = require("node:fs")
    const end = Date.now() + #{@give_up_ms}
    const system = {
      theme: { prefix: null },
      candidatesToCss: (classes) => classes.map((c) => (c.startsWith("zorblax") ? null : ".x{}")),
      getClassList: () => ["flex"],
      getVariants: () => [],
    }
    exports.__unstable__loadDesignSystem = async () => {
      fs.appendFileSync("#{pid_file}", process.pid + "\\n")
      #{body}
      return system
    }
    """)

    pid_file
  end

  @hangs [
    async: "await new Promise((resolve) => setTimeout(resolve, #{@give_up_ms}))",
    sync: "while (Date.now() < end) {}"
  ]

  describe "the worker and its stdin" do
    @describetag :node

    defp start_worker(dir) do
      node = System.find_executable("node")
      worker = Application.app_dir(:heex_lint, "priv/tailwind_oracle.mjs")

      port =
        Port.open({:spawn_executable, node}, [:binary, :exit_status, args: [worker], cd: dir])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      {port, os_pid}
    end

    defp request(port, css) do
      Port.command(port, JSON.encode!(%{id: 1, css: css, candidates: ["flex"]}) <> "\n")
    end

    for {form, body} <- @hangs do
      test "ends when stdin closes while the theme hangs (#{form})", %{tmp_dir: dir} do
        pid_file = fake_tailwind(dir, unquote(body))
        css = write(dir, "app.css", ~s(@import "tailwindcss";\n))
        {port, os_pid} = start_worker(dir)
        request(port, css)

        # At work, and past the point where a handler on that thread would run.
        assert eventually(fn -> pids(pid_file) == [os_pid] end)
        Process.sleep(100)
        assert alive?(os_pid)

        Port.close(port)
        assert gone?(os_pid)
      end
    end

    test "ends when stdin closes with nothing to do", %{tmp_dir: dir} do
      {port, os_pid} = start_worker(dir)
      Process.sleep(100)
      assert alive?(os_pid)

      Port.close(port)
      assert gone?(os_pid)
    end

    @tag :tailwind
    test "ends when stdin closes while a plugin spins", %{tmp_dir: dir} do
      with_tailwind(dir)
      started = Path.join(dir, "started")

      write(dir, "plugin.mjs", """
      import * as fs from "node:fs"
      fs.writeFileSync("#{started}", "")
      const end = Date.now() + #{@give_up_ms}
      while (Date.now() < end) {}
      export default function () {}
      """)

      css = write(dir, "app.css", ~s(@import "tailwindcss";\n@plugin "./plugin.mjs";\n))
      {port, os_pid} = start_worker(dir)
      request(port, css)
      assert eventually(fn -> File.exists?(started) end, 10_000)

      Port.close(port)
      assert gone?(os_pid)
    end

    test "keeps a plugin's console.log out of the protocol", %{tmp_dir: dir} do
      fake_tailwind(dir, ~s|console.log("chatty")|)
      css = write(dir, "app.css", ~s(@import "tailwindcss";\n))
      {port, os_pid} = start_worker(dir)
      request(port, css)

      assert_receive {^port, {:data, line}}, 5_000
      assert %{"id" => 1, "ok" => true} = JSON.decode!(line)
      Port.close(port)
      assert gone?(os_pid)
    end

    test "says so when a plugin ends its thread, and takes the next question", %{tmp_dir: dir} do
      fake_tailwind(dir, ~s|process.exit(3)|)
      css = write(dir, "app.css", ~s(@import "tailwindcss";\n))
      {port, os_pid} = start_worker(dir)

      request(port, css)
      assert_receive {^port, {:data, line}}, 5_000
      assert %{"id" => 1, "ok" => false, "reason" => reason} = JSON.decode!(line)
      assert reason =~ "exited with code 3"

      request(port, css)
      assert_receive {^port, {:data, line}}, 5_000
      assert %{"ok" => false} = JSON.decode!(line)

      Port.close(port)
      assert gone?(os_pid)
    end
  end

  describe "a deadline, on a process that ignores everything" do
    @describetag :node

    for form <- [:async, :sync] do
      test "kills it and uses the grammar (#{form})", %{tmp_dir: dir} do
        with_tailwind_stub(dir)
        pid_file = fake_node(dir, unquote(form))
        deadline(1_000)

        {elapsed, result} =
          timed(fn -> run(dir, page(), rules: [no_unknown_classes: :error]) end)

        assert elapsed < 5_000

        # The grammar's answer: it reads the class and offers no spelling.
        assert [finding] = result.diagnostics
        assert finding.message =~ ~s("zorblax")
        refute finding.message =~ "Did you mean"

        assert [warning] = result.warnings
        assert warning =~ "within 1.0 s"
        assert warning =~ "rules use the class grammar"
        refute warning =~ "no_unknown_classes"

        assert [os_pid] = pids(pid_file)
        assert gone?(os_pid)
      end
    end

    test "fires though the question fills a stdin nobody reads", %{tmp_dir: dir} do
      with_tailwind_stub(dir)
      pid_file = fake_node(dir, :sync)
      deadline(1_000)

      # Far past a pipe's buffer.
      classes = Enum.map_join(1..8_000, " ", &"zorblax-#{&1}")

      {elapsed, result} =
        timed(fn ->
          run(dir, page(~s|<div class="#{classes}" />|), rules: [no_unknown_classes: :error])
        end)

      assert elapsed < 10_000
      assert [warning] = result.warnings
      assert warning =~ "within 1.0 s"
      assert [os_pid] = pids(pid_file)
      assert gone?(os_pid)
    end

    test "does not start another process for that stylesheet", %{tmp_dir: dir} do
      with_tailwind_stub(dir)
      pid_file = fake_node(dir, :async)
      deadline(1_000)

      pages =
        for n <- 1..8, into: %{} do
          {"lib/app_web/live/page_#{n}_live.ex",
           live(~s|<div class="zorblax-#{n}" />|)
           |> String.replace("PageLive", "Page#{n}Live")}
        end

      result = run(dir, pages, rules: [no_unknown_classes: :error, no_raw_colors: :error])

      assert length(result.diagnostics) == 8
      assert length(pids(pid_file)) == 1
      assert [warning] = Enum.filter(result.warnings, &(&1 =~ "within"))
      assert warning =~ "rules use the class grammar"
    end

    test "a process that keeps dying is not restarted forever", %{tmp_dir: dir} do
      with_tailwind_stub(dir)
      pid_file = Path.join(dir, "node.pids")

      script(dir, "fake/bin/node", """
      #!/bin/sh
      echo $$ >> "#{pid_file}"
      exit 7
      """)

      System.put_env("PATH", Path.join(dir, "fake/bin") <> ":" <> System.get_env("PATH"))

      result = run(dir, page(), rules: [no_unknown_classes: :error])

      assert length(pids(pid_file)) == 1
      assert [finding] = result.diagnostics
      assert finding.message =~ ~s("zorblax")
      assert [warning] = result.warnings
      assert warning =~ "exited with status 7"
      assert warning =~ "rules use the class grammar"
    end

    defp with_tailwind_stub(dir) do
      write(dir, "node_modules/tailwindcss/package.json", ~s({"name": "tailwindcss"}))
      write(dir, "node_modules/tailwindcss/index.css", "")
    end
  end

  describe "a deadline, on the real worker" do
    @describetag :node

    for {form, body} <- @hangs do
      test "kills it and uses the grammar (#{form})", %{tmp_dir: dir} do
        pid_file = fake_tailwind(dir, unquote(body))
        deadline(2_000)

        {elapsed, result} =
          timed(fn -> run(dir, page(), rules: [no_unknown_classes: :error]) end)

        assert elapsed < 8_000
        assert [finding] = result.diagnostics
        refute finding.message =~ "Did you mean"
        assert [warning] = result.warnings
        assert warning =~ "rules use the class grammar"
        assert [os_pid] = pids(pid_file)
        assert gone?(os_pid)
      end
    end

    test "a slow answer inside the deadline is used, without a warning", %{tmp_dir: dir} do
      pid_file =
        fake_tailwind(dir, "await new Promise((resolve) => setTimeout(resolve, 300))")

      deadline(10_000)
      result = run(dir, page(), rules: [no_unknown_classes: :error])

      assert result.warnings == []
      # The fake's Tailwind offers `flex` for nothing near it, so no suggestion here
      # either, but the build is what reported this.
      assert [finding] = result.diagnostics
      assert finding.message =~ ~s("zorblax")
      assert [os_pid] = pids(pid_file)
      assert gone?(os_pid)
    end

    test "a theme that cannot load is not a failure of the process", %{tmp_dir: dir} do
      pid_file = fake_tailwind(dir, ~s|throw new Error("broken theme")|)
      result = run(dir, page(), rules: [no_unknown_classes: :error])

      assert [warning] = result.warnings
      assert warning =~ "could not be built (broken theme)"
      assert warning =~ "rules use the class grammar"
      refute warning =~ "no_unknown_classes"
      assert [os_pid] = pids(pid_file)
      assert gone?(os_pid)
    end
  end

  describe "the stylesheets of an umbrella" do
    @describetag :node

    defp umbrella_app(dir, name, body) do
      pid_file = fake_tailwind(Path.join(dir, "apps/#{name}"), name, body)

      %{
        "apps/#{name}/mix.exs" => "",
        "apps/#{name}/assets/css/app.css" => ~s(@import "tailwindcss";\n),
        "apps/#{name}/lib/#{name}_web/live/page_live.ex" =>
          live(~s|<div class="zorblax" />|)
          |> String.replace("AppWeb", "#{Macro.camelize(name)}Web")
      }
      |> then(&{&1, pid_file})
    end

    test "a hung one does not cost the others their answers", %{tmp_dir: dir} do
      {hung, hung_pids} = umbrella_app(dir, "hung", "while (Date.now() < end) {}")
      {fine, fine_pids} = umbrella_app(dir, "fine", "")
      deadline(2_000)

      result =
        run(dir, Map.merge(hung, fine),
          rules: [no_unknown_classes: :error],
          inputs: ["apps/**/*.ex"]
        )

      assert length(result.diagnostics) == 2
      assert [warning] = result.warnings
      assert warning =~ "rules use the class grammar"
      assert [hung_pid] = pids(hung_pids)
      assert gone?(hung_pid)
      # A new process for the other app, which the first left out.
      assert [fine_pid] = pids(fine_pids)
      assert gone?(fine_pid)
    end

    test "two hung ones turn the oracle off", %{tmp_dir: dir} do
      apps =
        for name <- ~w(aaa bbb ccc), do: umbrella_app(dir, name, "while (Date.now() < end) {}")

      deadline(2_000)

      {elapsed, result} =
        timed(fn ->
          run(dir, apps |> Enum.map(&elem(&1, 0)) |> Enum.reduce(&Map.merge/2),
            rules: [no_unknown_classes: :error],
            inputs: ["apps/**/*.ex"]
          )
        end)

      assert elapsed < 15_000
      started = apps |> Enum.flat_map(&pids(elem(&1, 1)))
      assert length(started) == 2
      assert Enum.all?(started, &gone?/1)
      assert Enum.any?(result.warnings, &(&1 =~ "failed twice"))
      assert Enum.all?(result.warnings, &(&1 =~ "rules use the class grammar"))
    end
  end

  describe "the standalone binary" do
    defp hung_binary(dir) do
      pid_file = Path.join(dir, "bin.pids")

      bin =
        script(dir, "fake/tailwind", """
        #!/bin/sh
        trap '' TERM INT HUP
        echo $$ >> "#{pid_file}"
        sleep #{div(@give_up_ms, 1000)} &
        echo $! >> "#{pid_file}"
        wait
        wait
        """)

      {bin, pid_file}
    end

    test "is killed past the deadline, with what it started", %{tmp_dir: dir} do
      {bin, pid_file} = hung_binary(dir)
      deadline(1_000)

      {elapsed, result} =
        timed(fn ->
          run(dir, page(), rules: [no_unknown_classes: :error], settings: [tailwind_bin: bin])
        end)

      assert elapsed < 5_000
      assert [finding] = result.diagnostics
      assert finding.message =~ ~s("zorblax")
      assert [warning] = result.warnings
      assert warning =~ "within 1.0 s"
      assert warning =~ "rules use the class grammar"

      assert [_shell, _sleep] = started = pids(pid_file)
      assert Enum.all?(started, &gone?/1)
    end

    test "is asked once for that stylesheet", %{tmp_dir: dir} do
      {bin, pid_file} = hung_binary(dir)
      deadline(1_000)

      pages =
        for n <- 1..6, into: %{} do
          {"lib/app_web/live/page_#{n}_live.ex",
           live(~s|<div class="zorblax-#{n}" />|)
           |> String.replace("PageLive", "Page#{n}Live")}
        end

      result = run(dir, pages, rules: [no_unknown_classes: :error], settings: [tailwind_bin: bin])

      assert length(result.diagnostics) == 6
      assert [_shell, _sleep] = pids(pid_file)
      assert [_warning] = result.warnings
    end

    test "that cannot start warns and uses the grammar", %{tmp_dir: dir} do
      bin = write(dir, "fake/not_executable", "")

      result =
        run(dir, page(), rules: [no_unknown_classes: :error], settings: [tailwind_bin: bin])

      assert [finding] = result.diagnostics
      assert finding.message =~ ~s("zorblax")
      assert [warning] = result.warnings
      assert warning =~ "could not be built with"
      assert warning =~ "rules use the class grammar"
    end

    test "that fails warns and uses the grammar", %{tmp_dir: dir} do
      bin = script(dir, "fake/tailwind", "#!/bin/sh\necho nope >&2\nexit 2\n")

      result =
        run(dir, page(), rules: [no_unknown_classes: :error], settings: [tailwind_bin: bin])

      assert [_finding] = result.diagnostics
      assert [warning] = result.warnings
      assert warning =~ "could not be built with #{bin}: nope"
      assert warning =~ "rules use the class grammar"
      refute warning =~ "no_unknown_classes"
    end

    @tag :standalone
    test "a slow build inside the deadline is used, without a warning", %{tmp_dir: dir} do
      bin =
        script(dir, "fake/tailwind", """
        #!/bin/sh
        sleep 0.3
        exec "#{standalone_bin()}" "$@"
        """)

      deadline(20_000)

      result =
        run(dir, page(~s|<div class="flex-cols flex" />|),
          rules: [no_unknown_classes: :error],
          settings: [tailwind_bin: bin]
        )

      assert result.warnings == []
      assert [finding] = result.diagnostics
      assert finding.message =~ ~s("flex-cols")
    end
  end

  describe "a VM that dies without stopping anything" do
    defp die_during_lint(dir, pid_file, started, settings) do
      ebin = Path.wildcard(Path.expand("../../_build/test/lib/*/ebin", __DIR__))

      script =
        write(dir, "die.exs", """
        spawn(fn ->
          config =
            HeexLint.Config.new(
              rules: [no_unknown_classes: :error],
              settings: #{inspect(settings)}
            )

          HeexLint.run(config, nil, root: #{inspect(dir)})
        end)

        # Once it is at work, and with no time to stop anything.
        wait = fn wait, tries ->
          lines =
            case File.read(#{inspect(pid_file)}) do
              {:ok, text} -> length(String.split(text, "\\n", trim: true))
              {:error, _} -> 0
            end

          if lines < #{started} and tries > 0 do
            Process.sleep(20)
            wait.(wait, tries - 1)
          end
        end

        wait.(wait, 1_000)
        Process.sleep(100)
        System.halt(0)
        """)

      # Its output goes to a file: what it starts inherits stderr, and a pipe would
      # keep this waiting for them, which is the thing being tested.
      command =
        ["exec", System.find_executable("elixir")] ++
          Enum.flat_map(ebin, &["-pa", &1]) ++ [script, ">", Path.join(dir, "die.log"), "2>&1"]

      {_output, 0} =
        System.cmd("sh", ["-c", Enum.join(command, " ")],
          env: [{"HEEX_LINT_TAILWIND_TIMEOUT", "#{@give_up_ms}"}]
        )
    end

    defp project_files(dir, files) do
      for {path, contents} <- Map.merge(%{"assets/css/app.css" => theme()}, files) do
        write(dir, path, contents)
      end

      for {path, contents} <- %{
            "lib/app_web.ex" => "defmodule AppWeb do\nend\n"
          } do
        write(dir, path, contents)
      end
    end

    @tag :node
    test "leaves no worker behind", %{tmp_dir: dir} do
      pid_file = fake_tailwind(dir, "while (Date.now() < end) {}")
      project_files(dir, page())
      die_during_lint(dir, pid_file, 1, [])

      assert [os_pid] = pids(pid_file)
      assert gone?(os_pid)
    end

    test "leaves no standalone build behind", %{tmp_dir: dir} do
      {bin, pid_file} = hung_binary(dir)
      project_files(dir, page())
      die_during_lint(dir, pid_file, 2, tailwind_bin: bin)

      assert [_shell, _sleep] = started = pids(pid_file)
      assert Enum.all?(started, &gone?/1)
    end
  end

  describe "an oracle that cannot answer" do
    defp bare_project(dir) do
      write(dir, "assets/css/app.css", ~s(@import "tailwindcss";\n))
      Project.load(dir, [], %{})
    end

    test "that crashed answers nil, and the run goes on", %{tmp_dir: dir} do
      project = bare_project(dir)
      {:ok, oracle} = Tailwind.start(project)
      Process.exit(oracle, :kill)
      eventually(fn -> not Process.alive?(oracle) end)

      assert Tailwind.unknown(%{project | oracle: oracle}, ["flex"]) == nil
      assert [warning] = Tailwind.warnings(oracle)
      assert warning =~ "rules used the class grammar"
      assert Tailwind.stop(oracle) == :ok
      assert Tailwind.status(oracle, project.entry) == {:none, "the oracle stopped"}
    end

    test "that does not answer in time answers nil, and says so", %{tmp_dir: dir} do
      project = bare_project(dir)
      {:ok, oracle} = Tailwind.start(project)
      deadline(1)
      :sys.suspend(oracle)

      assert Tailwind.unknown(%{project | oracle: oracle}, ["flex"]) == nil

      :sys.resume(oracle)
      deadline(5_000)
      assert [warning] = Tailwind.warnings(oracle)
      assert warning =~ "did not answer"
      assert warning =~ "rules checked a file with the class grammar"
      Tailwind.stop(oracle)
    end

    test "that a crash took down does not take its caller with it", %{tmp_dir: dir} do
      project = bare_project(dir)
      {:ok, oracle} = Tailwind.start(project)
      ref = Process.monitor(oracle)
      Process.exit(oracle, :boom)
      assert_receive {:DOWN, ^ref, :process, ^oracle, :boom}
    end

    test "ends with the process that started it", %{tmp_dir: dir} do
      project = bare_project(dir)
      test = self()

      owner =
        spawn(fn ->
          {:ok, oracle} = Tailwind.start(project)
          send(test, {:oracle, oracle})
          Process.sleep(:infinity)
        end)

      assert_receive {:oracle, oracle}
      ref = Process.monitor(oracle)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^oracle, :normal}, 1_000
    end
  end

  describe "classes past the limits" do
    # Tailwind overflows its stack on thousands of variants and takes seconds on a
    # value hundreds of kilobytes long.
    defp past_the_limits do
      [
        String.duplicate("hover:", 5000) <> "p-4",
        "w-[calc(" <> String.duplicate("1px+", 60_000) <> "1px)]"
      ]
    end

    defp limits_template do
      long = past_the_limits() |> Enum.join(" ")
      at_limit = String.duplicate("hover:", 64) <> "flx"
      ~s|<div class="#{long} #{at_limit} flex flx" />|
    end

    defp unknown_tokens(result) do
      for finding <- result.diagnostics,
          [_, token] <- [Regex.run(~r/^"([^"]+)"/, finding.message)],
          do: token
    end

    @tag :tailwind
    test "are not judged, through Node", %{tmp_dir: dir} do
      with_tailwind(dir)
      result = run(dir, page(limits_template()), rules: [no_unknown_classes: :error])

      assert unknown_tokens(result) == [String.duplicate("hover:", 64) <> "flx", "flx"]
      assert result.warnings == []
    end

    @tag :standalone
    test "are not judged, with the standalone binary", %{tmp_dir: dir} do
      result =
        run(dir, page(limits_template()),
          rules: [no_unknown_classes: :error],
          settings: [tailwind_bin: standalone_bin()]
        )

      assert unknown_tokens(result) == [String.duplicate("hover:", 64) <> "flx", "flx"]
      assert result.warnings == []
    end
  end

  describe "a plugin that throws on a class" do
    @boom """
    export default function ({ matchUtilities }) {
      matchUtilities(
        {
          boom: (value) => {
            if (value === "bad") throw new Error("boom")
            return { color: value }
          },
        },
        { values: { bad: "bad", red: "red" } }
      )
    }
    """

    @boom_theme ~s(@import "tailwindcss";\n@plugin "./plugin.mjs";\n)
    @boom_template ~s|<div class="boom-red boom-bad hovr:boom-bad flex flx hovr:flex" />|

    defp boom_files(template \\ @boom_template) do
      Map.merge(page(template), %{
        "assets/css/app.css" => @boom_theme,
        "assets/css/plugin.mjs" => @boom
      })
    end

    @tag :tailwind
    test "costs that class alone, through Node", %{tmp_dir: dir} do
      with_tailwind(dir)
      result = run(dir, boom_files(), rules: [no_unknown_classes: :error])

      assert unknown_tokens(result) == ["hovr:boom-bad", "flx", "hovr:flex"]
      assert result.warnings == []

      messages = Enum.map(result.diagnostics, & &1.message)
      assert Enum.any?(messages, &(&1 =~ ~s("flx") and &1 =~ ~s(Did you mean "flex"?)))

      assert Enum.any?(
               messages,
               &(&1 =~ ~s("hovr:flex") and &1 =~ ~s(Did you mean "hover:flex"?))
             )
    end

    @tag :standalone
    test "costs that class alone, with the standalone binary", %{tmp_dir: dir} do
      result =
        run(dir, boom_files(),
          rules: [no_unknown_classes: :error],
          settings: [tailwind_bin: standalone_bin()]
        )

      assert unknown_tokens(result) == ["hovr:boom-bad", "flx", "hovr:flex"]
      assert result.warnings == []

      hovr =
        Enum.find(result.diagnostics, &(&1.message =~ ~s("hovr:flex")))

      assert hovr.message =~ "uses a variant this project's Tailwind does not know"
    end

    @tag :standalone
    test "only one build fails when the plugin takes the theme down", %{tmp_dir: dir} do
      counter = Path.join(dir, "builds")

      bin =
        script(dir, "fake/tailwind", """
        #!/bin/sh
        echo x >> "#{counter}"
        exec "#{standalone_bin()}" "$@"
        """)

      files =
        Map.merge(page(), %{
          "assets/css/app.css" => ~s(@import "tailwindcss";\n@plugin "./missing.mjs";\n)
        })

      result = run(dir, files, rules: [no_unknown_classes: :error], settings: [tailwind_bin: bin])

      # Once with the classes and once without, which says it is not them.
      assert length(String.split(File.read!(counter), "\n", trim: true)) == 2
      assert [warning] = result.warnings
      assert warning =~ "could not be built with"
      assert warning =~ "rules use the class grammar"
    end

    @tag :standalone
    test "a deadline covers every build the search takes", %{tmp_dir: dir} do
      counter = Path.join(dir, "builds")

      bin =
        script(dir, "fake/tailwind", """
        #!/bin/sh
        echo x >> "#{counter}"
        sleep 0.2
        exit 1
        """)

      classes = Enum.map_join(1..64, " ", &"zorblax-#{&1}")
      # The theme builds, by a build with no classes: only that one passes here.
      bin_with_theme =
        script(dir, "fake/tailwind_theme", """
        #!/bin/sh
        if grep -q zorblax "$2"; then exec "#{bin}" "$@"; fi
        echo x >> "#{counter}"
        : > "$4"
        exit 0
        """)

      deadline(700)

      {elapsed, result} =
        timed(fn ->
          run(dir, page(~s|<div class="#{classes}" />|),
            rules: [no_unknown_classes: :error],
            settings: [tailwind_bin: bin_with_theme]
          )
        end)

      assert elapsed < 5_000
      assert [warning] = result.warnings
      assert warning =~ "within 0.7 s"
    end
  end

  describe "Tailwind installed beside a stylesheet the theme imports" do
    # Only the UI package depends on Tailwind, so the app's stylesheet cannot
    # resolve it.
    defp ui_package(dir) do
      write(dir, "packages/ui/package.json", ~s({"name": "@acme/ui"}))

      write(
        dir,
        "packages/ui/styles.css",
        ~s(@import "tailwindcss";\n@utility kit-frame { display: flex; }\n)
      )

      File.ln_s!(
        Path.expand("../fixtures/node/node_modules", __DIR__),
        Path.join(dir, "packages/ui/node_modules")
      )

      Path.join(dir, "apps/web")
    end

    @kit_template ~s|<div class="kit-frame flex kit-frmae" />|

    defp kit_messages(result), do: Enum.map(result.diagnostics, & &1.message)

    @tag :tailwind
    test "is found through a relative import", %{tmp_dir: dir} do
      root = ui_package(dir)

      result =
        run(
          root,
          Map.merge(page(@kit_template), %{
            "assets/css/app.css" => ~s(@import "../../../../packages/ui/styles.css";\n)
          }),
          rules: [no_unknown_classes: :error],
          settings: [theme: "assets/css/app.css"]
        )

      assert result.warnings == []
      assert [message] = kit_messages(result)
      assert message =~ ~s("kit-frmae")
      assert message =~ ~s(Did you mean "kit-frame"?)
    end

    @tag :tailwind
    test "is found through a linked workspace package", %{tmp_dir: dir} do
      root = ui_package(dir)
      File.mkdir_p!(Path.join(root, "node_modules/@acme"))

      File.ln_s!(
        Path.join(dir, "packages/ui"),
        Path.join(root, "node_modules/@acme/ui")
      )

      result =
        run(
          root,
          Map.merge(page(@kit_template), %{
            "assets/css/app.css" => ~s(@import "@acme/ui/styles.css";\n)
          }),
          rules: [no_unknown_classes: :error],
          settings: [theme: "assets/css/app.css"]
        )

      assert result.warnings == []
      assert [message] = kit_messages(result)
      assert message =~ ~s(Did you mean "kit-frame"?)
    end

    @tag :tailwind
    @tag :fan_out
    test "and the imports graph may have a cycle in it", %{tmp_dir: dir} do
      root = ui_package(dir)

      write(
        dir,
        "packages/ui/styles.css",
        ~s(@import "tailwindcss";\n@import "../../apps/web/assets/css/app.css";\n)
      )

      result =
        run(
          root,
          Map.merge(page(@kit_template), %{
            "assets/css/app.css" => ~s(@import "../../../../packages/ui/styles.css";\n)
          }),
          rules: [no_unknown_classes: :error],
          settings: [theme: "assets/css/app.css"]
        )

      # No fan-out, so Tailwind's own limit on depth ends it.
      assert [warning] = result.warnings
      assert warning =~ "could not be built"
      assert warning =~ "rules use the class grammar"
    end
  end

  describe "a package's stylesheet, in the Node build" do
    @describetag :tailwind

    defp installed_kit(dir, files) do
      File.mkdir_p!(Path.join(dir, "node_modules"))
      source = Path.expand("../fixtures/node/node_modules", __DIR__)

      for name <- File.ls!(source),
          do: File.ln_s!(Path.join(source, name), Path.join(dir, "node_modules/#{name}"))

      for {path, contents} <- files, do: write(dir, "node_modules/kit/#{path}", contents)
    end

    @kit_css "@utility kit-frame { display: flex; }\n"

    for {shape, import, files} <- [
          {"named by main", "kit",
           [{"package.json", ~s({"main": "theme.css"})}, {"theme.css", @kit_css}]},
          {"named by style", "kit",
           [{"package.json", ~s({"style": "theme.css"})}, {"theme.css", @kit_css}]},
          {"under src", "kit/theme.css",
           [{"package.json", ~s({"name": "kit"})}, {"src/theme.css", @kit_css}]},
          {"without a manifest", "kit/theme.css", [{"theme.css", @kit_css}]}
        ] do
      test "is read when it is #{shape}", %{tmp_dir: dir} do
        installed_kit(dir, unquote(Macro.escape(files)))

        files =
          Map.put(
            page(~s|<div class="kit-frame flex kit-frmae" />|),
            "assets/css/app.css",
            ~s(@import "tailwindcss";\n@import "#{unquote(import)}";\n)
          )

        result = run(dir, files, rules: [no_unknown_classes: :error])

        assert result.warnings == []
        assert [finding] = result.diagnostics
        assert finding.message =~ ~s(Did you mean "kit-frame"?)
      end
    end

    test "that does not resolve warns and uses the grammar", %{tmp_dir: dir} do
      installed_kit(dir, [])

      files =
        Map.put(
          page(),
          "assets/css/app.css",
          ~s(@import "tailwindcss";\n@import "no-such-kit/theme.css";\n)
        )

      result = run(dir, files, rules: [no_unknown_classes: :error])

      assert [warning] = result.warnings
      assert warning =~ ~s(@import "no-such-kit/theme.css" could not be resolved)
      assert warning =~ "rules use the class grammar"
    end
  end

  describe "a cycle of imports with fan-out" do
    @describetag :fan_out

    defp fan_out_theme(dir) do
      write(dir, "assets/css/f1.css", ~s(@import "./f2.css";\n@import "./f2.css";\n))
      write(dir, "assets/css/f2.css", ~s(@import "./f1.css";\n@import "./f1.css";\n))
      ~s(@import "tailwindcss";\n@import "./f1.css";\n)
    end

    defp fan_out_page(dir), do: Map.put(page(), "assets/css/app.css", fan_out_theme(dir))

    defp oracle_workers do
      {out, 0} = System.cmd("ps", ["-axo", "pid=,command="])

      for line <- String.split(out, "\n"),
          line =~ "tailwind_oracle.mjs",
          do: line
    end

    # A real one: these ran for as long as nothing stopped them, each holding 290,000
    # files, and they outlived mix. The deadline here is the bound, should the limit
    # on reads ever go.
    @tag :tailwind
    test "fails fast through Node, with no worker left", %{tmp_dir: dir} do
      with_tailwind(dir)
      deadline(10_000)
      before = oracle_workers()

      {elapsed, result} =
        timed(fn -> run(dir, fan_out_page(dir), rules: [no_unknown_classes: :error]) end)

      assert elapsed < 9_000
      assert [finding] = result.diagnostics
      assert finding.message =~ ~s("zorblax")
      assert [warning] = result.warnings
      assert warning =~ "probably form a cycle"
      assert warning =~ "rules use the class grammar"
      assert eventually(fn -> oracle_workers() -- before == [] end)
    end

    @tag :standalone
    test "is stopped at the deadline with the standalone binary", %{tmp_dir: dir} do
      deadline(1_000)

      {elapsed, result} =
        timed(fn ->
          run(dir, fan_out_page(dir),
            rules: [no_unknown_classes: :error],
            settings: [tailwind_bin: standalone_bin()]
          )
        end)

      assert elapsed < 5_000
      assert [finding] = result.diagnostics
      assert finding.message =~ ~s("zorblax")
      assert [warning] = result.warnings
      assert warning =~ "within 1.0 s"
      assert warning =~ "rules use the class grammar"
    end
  end

  describe "HEEX_LINT_TAILWIND_TIMEOUT" do
    test "without it, a first answer gets longer than the ones after" do
      System.delete_env("HEEX_LINT_TAILWIND_TIMEOUT")
      assert Tailwind.timeout_for(true) == 60_000
      assert Tailwind.timeout_for(false) == 30_000
    end

    test "a positive number of milliseconds replaces both" do
      for {value, milliseconds} <- [
            {"120000", 120_000},
            {"1500.5", 1501},
            {" 250 ", 250},
            {"1e3", 1000}
          ] do
        System.put_env("HEEX_LINT_TAILWIND_TIMEOUT", value)
        assert Tailwind.timeout_for(true) == milliseconds
        assert Tailwind.timeout_for(false) == milliseconds
      end
    end

    test "anything else keeps the defaults" do
      for value <- ["", "0", "-5", "soon", "Infinity", "NaN", "10s", "1e400"] do
        System.put_env("HEEX_LINT_TAILWIND_TIMEOUT", value)
        assert Tailwind.timeout_for(true) == 60_000
        assert Tailwind.timeout_for(false) == 30_000
      end
    end

    test "a number too large to wait for is cut down, not an error" do
      System.put_env("HEEX_LINT_TAILWIND_TIMEOUT", "1e30")
      assert Tailwind.timeout_for(true) == 4_294_967_295
    end
  end
end

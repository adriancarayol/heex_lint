defmodule Mix.Tasks.HeexLintTest do
  # Changes the working directory, so it can't run concurrently.
  use ExUnit.Case

  import ExUnit.CaptureIO
  import HeexLint.TestProject

  @moduletag :tmp_dir

  defp setup_project(dir, template, rules) do
    run(dir, %{"lib/app_web/live/page_live.ex" => live(template)}, rules: [])
    File.write!(Path.join(dir, ".heex_lint.exs"), inspect(rules: rules))
  end

  # Runs the task in `dir`, returning its exit status and printed output.
  defp task(dir, args) do
    File.cd!(dir, fn ->
      stderr =
        capture_io(:stderr, fn ->
          stdout = capture_io(fn -> send(self(), {:status, status(args)}) end)
          send(self(), {:stdout, stdout})
        end)

      assert_received {:status, status}
      assert_received {:stdout, stdout}
      {status, stdout, stderr}
    end)
  end

  defp status(args) do
    Mix.Tasks.HeexLint.run(args)
    :ok
  catch
    :exit, reason -> reason
  end

  test "passes on clean projects", %{tmp_dir: dir} do
    setup_project(dir, ~s(<div class="bg-primary" />), no_raw_colors: :error)
    assert {:ok, output, _} = task(dir, [])
    assert output =~ ~r/No problems in \d+ files./
  end

  test "prints diagnostics and exits with status 1", %{tmp_dir: dir} do
    setup_project(dir, ~s(<div class="bg-neutral-900 p-[12px]" />),
      no_raw_colors: :error,
      no_arbitrary_values: :error
    )

    assert {{:shutdown, 1}, output, _} = task(dir, [])
    assert output =~ "lib/app_web/live/page_live.ex:6:17"
    assert output =~ "[no_raw_colors]"
    assert output =~ "[no_arbitrary_values]"
    assert output =~ "2 errors in"
    # The nearest color is a suggestion; the scale step is exact.
    assert output =~ "1 can be fixed with --fix."
  end

  test "warnings pass unless over --max-warnings", %{tmp_dir: dir} do
    setup_project(dir, ~s(<div class="bg-neutral-900" />), no_raw_colors: :warning)
    assert {:ok, output, _} = task(dir, [])
    assert output =~ "1 warning in"
    assert {{:shutdown, 1}, _, _} = task(dir, ["--max-warnings", "0"])
  end

  test "--quiet prints errors only, and warnings still count", %{tmp_dir: dir} do
    setup_project(dir, ~s(<div class="bg-neutral-900 flex-cols" />),
      no_raw_colors: :warning,
      no_unknown_classes: :error
    )

    assert {{:shutdown, 1}, output, _} = task(dir, ["--quiet"])
    assert output =~ "[no_unknown_classes]"
    refute output =~ "[no_raw_colors]"
    assert output =~ "1 error, 1 warning in"

    File.write!(Path.join(dir, ".heex_lint.exs"), inspect(rules: [no_raw_colors: :warning]))
    assert {{:shutdown, 1}, _, _} = task(dir, ["--quiet", "--max-warnings", "0"])
    assert {:ok, _, _} = task(dir, ["--quiet", "--max-warnings", "1"])
  end

  test "JSON output carries suggestions", %{tmp_dir: dir} do
    setup_project(dir, ~s(<div class="bg-neutral-900" />), no_raw_colors: :error)
    assert {{:shutdown, 1}, output, _} = task(dir, ["--format", "json"])
    assert %{"diagnostics" => [diagnostic]} = JSON.decode!(output)

    assert %{
             "rule" => "no_raw_colors",
             "line" => 6,
             "suggestions" => [%{"replacement" => "bg-primary"}]
           } = diagnostic
  end

  test "GitHub annotations", %{tmp_dir: dir} do
    setup_project(dir, ~s(<div class="bg-neutral-900" />), no_raw_colors: :warning)
    assert {:ok, output, _} = task(dir, ["--format", "github"])

    assert output =~
             ~s(::warning file=lib/app_web/live/page_live.ex,line=6,col=17,title=no_raw_colors::"bg-neutral-900" uses the raw Tailwind palette.)
  end

  test "--fix applies suggestions and lints again", %{tmp_dir: dir} do
    setup_project(dir, ~s(<div class="p-[12px]" />), no_arbitrary_values: :error)
    assert {:ok, output, _} = task(dir, ["--fix"])
    assert output =~ "Applied 1 fix."
    assert File.read!(Path.join(dir, "lib/app_web/live/page_live.ex")) =~ ~s(class="p-3")
  end
end

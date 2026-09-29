defmodule Mix.Tasks.HeexLintTest do
  # Changes the working directory, so it can't run concurrently.
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias HeexLint.LintHelpers

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, ".heex_lint.exs"), inspect(theme: LintHelpers.theme()))
    :ok
  end

  # Runs the task in `dir`, returning its exit status and printed output.
  defp run_task(dir, args) do
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

  defp write(dir, file, contents), do: File.write!(Path.join([dir, "lib", file]), contents)

  test "passes on clean templates", %{tmp_dir: dir} do
    write(dir, "page.html.heex", ~s|<p class="p-4 text-(--ink)">x</p>|)

    assert {:ok, output, ""} = run_task(dir, [])
    assert output =~ "No problems in 1 file."
  end

  test "prints diagnostics and exits with status 1", %{tmp_dir: dir} do
    write(dir, "page.html.heex", ~s(<p class="text-white p-[13px]">x</p>))

    assert {{:shutdown, 1}, output, _} = run_task(dir, [])
    assert output =~ "lib/page.html.heex:1:11"
    assert output =~ "[no_raw_colors]"
    assert output =~ "[no_arbitrary_values]"
    assert output =~ "2 errors in 1 file."
  end

  test "passes when only warnings are under --max-warnings", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, ".heex_lint.exs"),
      inspect(theme: LintHelpers.theme(), rules: [no_raw_colors: :warning])
    )

    write(dir, "page.html.heex", ~s(<p class="text-white">x</p>))

    assert {:ok, output, _} = run_task(dir, [])
    assert output =~ "1 warning in 1 file."
    assert {{:shutdown, 1}, _, _} = run_task(dir, ["--max-warnings", "0"])
  end

  test "prints JSON", %{tmp_dir: dir} do
    write(dir, "page.html.heex", ~s(<p class="text-white">x</p>))

    assert {{:shutdown, 1}, output, _} = run_task(dir, ["--format", "json"])
    assert %{"diagnostics" => [diagnostic], "files" => 1} = JSON.decode!(output)
    assert %{"rule" => "no_raw_colors", "line" => 1, "column" => 11} = diagnostic
  end

  test "reports unparsable templates", %{tmp_dir: dir} do
    write(dir, "broken.html.heex", ~s(<p class="x></p>))

    assert {{:shutdown, 1}, _, stderr} = run_task(dir, [])
    assert stderr =~ "could not parse template"
  end
end

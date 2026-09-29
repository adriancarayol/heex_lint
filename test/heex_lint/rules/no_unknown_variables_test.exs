defmodule HeexLint.Rules.NoUnknownVariablesTest do
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  @moduletag :tmp_dir

  defp variables(dir, template, options \\ []) do
    files = %{"lib/app_web/live/page_live.ex" => live(template)}
    lint(dir, files, rules: [no_unknown_variables: {:error, options}])
  end

  test "undefined variables are reported with close names", %{tmp_dir: dir} do
    [finding] = variables(dir, ~s|<div class="bg-(--backgrund)" />|)

    assert finding.message ==
             ~s|"bg-(--backgrund)" reads --backgrund, which assets/css/app.css does not define, so the class has no effect. Did you mean --background?|
  end

  test "theme variables, dark-mode ones and inline ones are defined", %{tmp_dir: dir} do
    template = """
    <div class="bg-(--muted) text-[var(--foreground)] w-(--progress)" />
    <div style="--progress: 40%" />
    """

    assert variables(dir, template) == []
  end

  test "allow patterns", %{tmp_dir: dir} do
    assert variables(dir, ~s|<div class="h-(--radix-height)" />|, allow: ["--radix-*"]) == []
  end
end

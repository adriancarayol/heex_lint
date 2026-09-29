defmodule HeexLint.Rules.NoUnknownClassesTest do
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  @moduletag :tmp_dir

  defp unknown(dir, template, options \\ [], extra \\ %{}) do
    files = Map.merge(%{"lib/app_web/live/page_live.ex" => live(template)}, extra)
    lint(dir, files, rules: [no_unknown_classes: {:error, options}])
  end

  defp tokens(findings), do: Enum.map(findings, &hd(Regex.run(~r/"[^"]+"/, &1.message)))

  describe "with the project's Tailwind" do
    @describetag :tailwind

    test "typos get the nearest real class", %{tmp_dir: dir} do
      with_tailwind(dir)
      assert unknown(dir, ~s(<div class="flex-col rounded-lg hover:flex" />)) == []

      [cols] = unknown(dir, ~s(<div class="flex-cols" />))

      assert cols.message ==
               ~s|"flex-cols" is not a class this project's Tailwind knows, so no CSS is generated for it. Did you mean "flex-col"?|

      assert [%{replacement: "flex-col"}] = cols.suggestions
    end

    test "misspelled variants on a real utility", %{tmp_dir: dir} do
      with_tailwind(dir)
      [finding] = unknown(dir, ~s(<div class="hovr:flex" />))
      assert finding.message =~ ~s(Did you mean "hover:flex"?)
    end

    test "unknown classes without a close match point at @utility", %{tmp_dir: dir} do
      with_tailwind(dir)
      [finding] = unknown(dir, ~s(<div class="zorblax" />))

      assert finding.message ==
               ~s|"zorblax" is not a class this project's Tailwind knows, so no CSS is generated for it. Fix the spelling, or declare it with @utility in assets/css/app.css.|
    end

    test "custom utilities, class selectors and theme tokens are known", %{tmp_dir: dir} do
      with_tailwind(dir)

      assert unknown(
               dir,
               ~s|<div class="tap-target legacy-card bg-primary text-muted-foreground bg-(--x) [mask-type:alpha] group" />|
             ) == []
    end

    test "color typos are left to no_raw_colors, other utilities' typos are not", %{tmp_dir: dir} do
      with_tailwind(dir)
      findings = unknown(dir, ~s(<div class="bg-primry text-smal" />))
      assert tokens(findings) == [~s("text-smal")]
      assert hd(findings).message =~ ~s(Did you mean "text-sm"?)
    end

    test "allow exempts external classes; contracts limit them to a component", %{tmp_dir: dir} do
      with_tailwind(dir)

      template = """
      <.card class="editor-root" />
      <div class="editor-root" />
      """

      [finding] = unknown(dir, template, contracts: [[pattern: "^card$", allow: ["editor-root"]]])
      assert finding.line == 7
      assert unknown(dir, template, allow: ["editor-root"]) == []
    end
  end

  describe "without a Tailwind to ask" do
    test "the grammar, @utility names and class selectors answer", %{tmp_dir: dir} do
      findings =
        unknown(dir, ~s(<div class="flex-col tap-target legacy-card flex-cols rounded-huge" />))

      assert tokens(findings) == [~s("flex-cols"), ~s("rounded-huge")]

      assert hd(findings).message =~
               "Fix the spelling, or declare it with @utility in assets/css/app.css."
    end
  end
end

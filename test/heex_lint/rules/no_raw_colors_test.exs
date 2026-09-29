defmodule HeexLint.Rules.NoRawColorsTest do
  use ExUnit.Case, async: true

  import HeexLint.LintHelpers

  test "reports palette colors and suggests the closest theme color" do
    [diagnostic] = lint(~s(<div class="p-4 bg-white">x</div>), :no_raw_colors)

    assert diagnostic.rule == :no_raw_colors
    assert {diagnostic.line, diagnostic.column} == {1, 17}
    assert diagnostic.message =~ ~s("bg-white" is a raw Tailwind palette color)
    assert diagnostic.message =~ "bg-(--surface-raised) (#ffffff)"
  end

  test "keeps variants and opacity in the suggestion" do
    [diagnostic] = lint(~s(<div class="hover:bg-zinc-950/50">x</div>), :no_raw_colors)
    assert diagnostic.message =~ "hover:bg-(--ink)/50"
  end

  test "prefers theme colors the project already uses with the same utility" do
    template = """
    <p class="text-(--muted)">a</p>
    <p class="text-[var(--muted)]">b</p>
    <p class="text-zinc-700">c</p>
    """

    [diagnostic] = lint(template, :no_raw_colors)
    assert diagnostic.message =~ "Use the closest theme color: text-(--muted)"
  end

  test "reads classes inside expressions" do
    diagnostics =
      lint(~S|<div class={["p-2", @active && "text-rose-500", @class]}>x</div>|, :no_raw_colors)

    assert positions(diagnostics) == [{1, 33}]
  end

  test "ignores theme colors, non-color utilities and allowed classes" do
    template = """
    <div class="bg-brand text-(--ink) bg-transparent text-current border-2 text-sm text-red">x</div>
    <div class="text-white">x</div>
    """

    assert lint(template, :no_raw_colors, rule: [allow: ["text-white"]]) == []
  end

  test "uses a custom message and appends the note" do
    [diagnostic] =
      lint(~s(<p class="text-white">x</p>), :no_raw_colors,
        rule: [message: "{{class}} is off-palette."],
        note: "See DESIGN.md."
      )

    assert diagnostic.message == "text-white is off-palette. See DESIGN.md."
  end
end

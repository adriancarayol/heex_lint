defmodule HeexLint.Rules.RequireStaticClassesTest do
  use ExUnit.Case, async: true

  import HeexLint.LintHelpers

  test "reports classes built with interpolation or concatenation" do
    template = """
    <div class={"p-2 bg-\#{@color}"}>x</div>
    <div class={["m-1", "w-" <> @width]}>x</div>
    """

    assert [interpolated, concatenated] = lint(template, :require_static_classes)
    assert {interpolated.line, interpolated.column} == {1, 18}
    assert interpolated.message =~ ~s("bg-\#{…}" is built at runtime)
    assert concatenated.message =~ ~s("w-\#{…}")
  end

  test "allows whole runtime values" do
    assert lint(~S|<div class={["p-2", @class, "#{@extra}"]}>x</div>|, :require_static_classes) ==
             []
  end

  test "allows prefixes of plain CSS classes from the stylesheet" do
    assert lint(~S|<div class={"toast--#{@kind}"}>x</div>|, :require_static_classes) == []
  end
end

defmodule HeexLint.Rules.NoInlineStylesTest do
  use ExUnit.Case, async: true

  import HeexLint.LintHelpers

  test "reports each property of a static style" do
    diagnostics = lint(~s(<div style="color: red; margin-top: 4px">x</div>), :no_inline_styles)

    assert positions(diagnostics) == [{1, 13}, {1, 25}]

    assert Enum.map(diagnostics, & &1.message)
           |> Enum.all?(&(&1 =~ "Style with Tailwind classes"))
  end

  test "reports properties in expressions and runtime styles" do
    template = """
    <div style={"width: \#{@percent}%"}>x</div>
    <div style={@style}>x</div>
    """

    assert [width, dynamic] = lint(template, :no_inline_styles)
    assert width.message =~ "sets width"
    assert dynamic.message =~ "runtime value"
  end

  test "allows custom properties and allowed properties" do
    template = """
    <div style={"--progress: \#{@percent}%"}>x</div>
    <div style="view-transition-name: card">x</div>
    """

    assert lint(template, :no_inline_styles, rule: [allow: ["view-transition-name"]]) == []
  end

  test "reports custom properties when they are not allowed" do
    assert [_] =
             lint(~s(<div style="--x: 1">x</div>), :no_inline_styles,
               rule: [allow_custom_properties: false]
             )
  end

  test "reports <style> elements" do
    assert [%{message: message}] = lint("<style>p { color: red }</style>", :no_inline_styles)
    assert message =~ "<style> elements"
  end
end

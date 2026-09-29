defmodule HeexLint.Rules.NoInlineStylesTest do
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  @moduletag :tmp_dir

  defp styles(dir, template, options \\ [], extra \\ %{}) do
    files = Map.merge(%{"lib/app_web/live/page_live.ex" => live(template)}, extra)
    lint(dir, files, rules: [no_inline_styles: {:error, options}])
  end

  test "ordinary properties are reported one by one", %{tmp_dir: dir} do
    [color, margin] = styles(dir, ~s(<div style="color: red; margin-top: 4px">x</div>))

    assert color.message ==
             "Inline style sets color. Style through classes; use CSS custom properties for dynamic values."

    assert margin.message =~ "Inline style sets margin-top."
    assert {color.line, color.column} == {6, 17}
  end

  test "custom properties pass unless they hardcode a color", %{tmp_dir: dir} do
    template = """
    <div class="w-(--panel-width)" style={"--panel-width: \#{@width}px"} />
    <div style="--label-color: var(--color-primary)" />
    <div style="--label-color: #ec4899" />
    <div style="--shadow: 0 0 4px rgb(0 0 0 / 0.5)" />
    <div style="--bg: url(data:image/png;base64,iVBORw0KGgo=)" />
    """

    [hex, shadow] = styles(dir, template)

    assert hex.message ==
             "Custom property --label-color hardcodes a color. Define it as a theme token instead of injecting a raw value."

    assert shadow.message =~ "Custom property --shadow hardcodes a color."
  end

  test "style values that cannot be read are reported", %{tmp_dir: dir} do
    [finding] = styles(dir, ~s(<div style={@style} />))

    assert finding.message ==
             "Dynamic style object cannot be checked. Build it from CSS custom properties only."
  end

  test "a component forwarding its received style is allowed, and its default is checked", %{
    tmp_dir: dir
  } do
    component =
      component_module("Panel", "panel", ~s(attr :style, :string, default: "color: red"), """
      <div style={@style} />
      """)

    [finding] =
      lint(dir, %{"lib/app_web/panel.ex" => component}, rules: [no_inline_styles: :error])

    assert finding.message =~ "Inline style sets color."
  end

  test "<style> elements are reported", %{tmp_dir: dir} do
    [finding] = styles(dir, ~s(<style>.panel { color: red; }</style>))

    assert finding.message ==
             "A <style> element injects CSS outside the design system. Use classes, or declare the rule in your theme CSS."
  end

  test "colocated CSS is not an inline <style>", %{tmp_dir: dir} do
    assert styles(
             dir,
             ~s|<style :type={Phoenix.LiveView.ColocatedCSS}>.a { color: red; }</style>|
           ) == []
  end

  test "readable maps spread onto an element are checked", %{tmp_dir: dir} do
    [finding] = styles(dir, ~s|<div {%{style: "color: red", id: "x"}} />|)
    assert finding.message =~ "Inline style sets color."
  end

  test "allow exempts properties, in either spelling", %{tmp_dir: dir} do
    template = ~s|<div style="transform: translateX(10px); color: red; background-color: red" />|
    findings = styles(dir, template, allow: ["transform", "backgroundColor"])

    assert Enum.map(findings, & &1.message) == [
             "Inline style sets color. Style through classes; use CSS custom properties for dynamic values."
           ]
  end

  test "deny brings back the color check an allow exempted", %{tmp_dir: dir} do
    template = ~s(<div style="--tone: #ffffff; --other: #ffffff; --gap: 4px" />)
    [finding] = styles(dir, template, allow: ["--*"], deny: ["--tone"])
    assert finding.message =~ "Custom property --tone hardcodes a color."
  end

  test "contracts match the component name as written", %{tmp_dir: dir} do
    template = """
    <.card style="transform: rotate(2deg)" />
    <div style="transform: rotate(2deg)" />
    """

    [finding] = styles(dir, template, contracts: [[pattern: "^card$", allow: ["transform"]]])
    assert finding.line == 7
  end

  test "a class-shaped entry is a configuration error", %{tmp_dir: dir} do
    findings = styles(dir, ~s(<div />), allow: ["bg-red-500"])
    assert Enum.all?(findings, &(&1.message =~ ~s(entry "bg-red-500" is not a CSS property name)))
  end

  test "{{component}} is the element as written, empty on HTML tags", %{tmp_dir: dir} do
    template = """
    <.card style="color: red" />
    <div style="color: red" />
    """

    options = [message: "{{property}} on {{component|an element}}."]

    assert Enum.map(styles(dir, template, options), & &1.message) == [
             "color on .card.",
             "color on an element."
           ]
  end

  test "custom messages", %{tmp_dir: dir} do
    [finding] =
      styles(dir, ~s(<div style="color: red" />),
        message: "Use a class instead of {{property|inline CSS}}."
      )

    assert finding.message == "Use a class instead of color."
  end
end

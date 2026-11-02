defmodule HeexLint.Rules.NoArbitraryValuesTest do
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  @moduletag :tmp_dir

  defp arbitrary(dir, template, options \\ [], extra \\ %{}) do
    files = Map.merge(%{"lib/app_web/live/page_live.ex" => live(template)}, extra)
    lint(dir, files, rules: [no_arbitrary_values: {:error, options}])
  end

  defp message(dir, class, options \\ [], extra \\ %{}) do
    [finding] = arbitrary(dir, ~s(<div class="#{class}" />), options, extra)
    finding.message
  end

  test "exact spacing steps are named, with the project's unit", %{tmp_dir: dir} do
    assert message(dir, "p-[13px]") ==
             ~s|"p-[13px]" hardcodes an off-token value. Use "p-3.25" instead (same value, on the scale).|

    assert message(dir, "md:!-mt-[12px]") =~ ~s(Use "md:!-mt-3" instead)
    assert message(dir, "w-[200px]") =~ ~s(Use "w-50" instead)
    assert message(dir, "border-spacing-x-[8px]") =~ ~s(Use "border-spacing-x-2" instead)
  end

  test "values off the quarter-step scale get general guidance", %{tmp_dir: dir} do
    assert message(dir, "p-[13.5px]") ==
             ~s|"p-[13.5px]" hardcodes an off-token value. Use a theme token or scale value instead.|

    assert message(dir, "p-[1rem]") =~ "Use a theme token or scale value instead."
  end

  test "a theme --spacing changes the unit", %{tmp_dir: dir} do
    css = theme() <> "\n@theme { --spacing: 0.3rem; }\n"
    [finding] = arbitrary(dir, ~s(<div class="p-[12px]" />), [], %{"assets/css/app.css" => css})
    assert finding.message =~ ~s(Use "p-2.5" instead)
  end

  test "font sizes and radii name the exact or nearest steps", %{tmp_dir: dir} do
    assert message(dir, "text-[14px]") =~ ~s(Use "text-sm" instead)

    assert message(dir, "text-[13px]") ==
             ~s|"text-[13px]" hardcodes an off-token value. Nearest on the scale: text-xs (12px), text-sm (14px).|

    # The theme's own --radius-lg: 10px wins over Tailwind's default.
    assert message(dir, "rounded-[10px]") =~ ~s(Use "rounded-lg" instead)
    # Ties go to the smaller step.
    assert message(dir, "rounded-t-[7px]") =~
             "Nearest on the scale: rounded-t-md (6px), rounded-t-sm (4px)."
  end

  test "arbitrary colors suggest theme tokens", %{tmp_dir: dir} do
    assert message(dir, "bg-[#171717]") ==
             ~s|"bg-[#171717]" hardcodes a color. Nearest theme tokens: bg-primary. Use one of those, or declare --color-<name> in assets/css/app.css.|

    assert message(dir, "bg-[#00ff00]") =~
             "hardcodes a color and no declared theme color is close to it. Use one of: background,"
  end

  test "a variable in brackets is arbitrary; the shorthand is suggested", %{tmp_dir: dir} do
    [finding] =
      arbitrary(dir, ~s|<div class="hover:px-[var(--gutter)] text-[length:var(--size)]" />|,
        allow: ["text-*"]
      )

    assert finding.message =~ ~s|"hover:px-[var(--gutter)]" hardcodes an off-token value.|
    assert [%{replacement: "hover:px-(--gutter)"}] = finding.suggestions

    [typed] = arbitrary(dir, ~s|<div class="text-[length:var(--size)]" />|)
    assert [%{replacement: "text-(length:--size)"}] = typed.suggestions
  end

  test "arbitrary variants and variable shorthands are not arbitrary values", %{tmp_dir: dir} do
    assert arbitrary(dir, ~s|<div class="data-[state=open]:flex [&_svg]:size-4 bg-(--brand)" />|) ==
             []
  end

  test "arbitrary properties are", %{tmp_dir: dir} do
    assert message(dir, "[padding:13px]") =~ ~s("[padding:13px]" hardcodes an off-token value.)
  end

  test "layout allowed covers widths but not appearance", %{tmp_dir: dir} do
    findings =
      arbitrary(dir, ~s(<div class="w-[320px] p-[13px] rounded-[10px]" />), allow: ["layout"])

    assert Enum.map(findings, &hd(Regex.run(~r/"[^"]+"/, &1.message))) == [
             ~s("p-[13px]"),
             ~s("rounded-[10px]")
           ]
  end

  test "an exact class is allowed in every variant", %{tmp_dir: dir} do
    findings =
      arbitrary(dir, ~s(<div class="p-[13px] md:p-[13px] p-[15px]" />),
        allow: ["layout", "p-[13px]"]
      )

    assert [finding] = findings
    assert finding.message =~ ~s("p-[15px]")
  end

  test "contracts open a value on one component", %{tmp_dir: dir} do
    template = """
    <.card class="w-[320px]" />
    <.button class="w-[320px]">Save</.button>
    """

    [finding] = arbitrary(dir, template, contracts: [[pattern: "^card$", allow: ["w-*"]]])
    assert finding.message =~ ~s("w-[320px]")
    assert finding.line == 7
  end

  test "exact replacements are editor suggestions that rewrite the literal", %{tmp_dir: dir} do
    [finding] = arbitrary(dir, ~s(<div class="flex p-[12px]" />))

    assert [%{replacement: "p-3", exact: true, fix: %{old: "flex p-[12px]", new: "flex p-3"}}] =
             finding.suggestions
  end

  test "a font size step also sets a line height, so it is not exact", %{tmp_dir: dir} do
    [text, radius] = arbitrary(dir, ~s(<div class="text-[14px] rounded-[10px]" />))
    assert [%{replacement: "text-sm", exact: false}] = text.suggestions
    assert [%{replacement: "rounded-lg", exact: true}] = radius.suggestions
  end

  # A density class declared after :root sets --radius only inside it, so
  # the scale comes from :root: lg is 10px and xl 12px, and 8px is on
  # neither. The :root value wins from an imported stylesheet too.
  test "the scale reads --radius from :root, not a scoped selector", %{tmp_dir: dir} do
    css = %{
      "assets/css/base.css" => ":root { --radius: 0.5rem; }",
      "assets/css/app.css" => """
      @import "tailwindcss";
      @import "./base.css";
      .compact { --radius: 0.25rem; }
      @theme inline {
        --radius-lg: calc(var(--radius) + 2px);
        --radius-xl: calc(var(--radius) + 4px);
      }
      """
    }

    [near] = arbitrary(dir, ~s(<div class="rounded-[8px]" />), [], css)
    assert near.message =~ "Nearest on the scale"

    [exact] = arbitrary(dir, ~s(<div class="rounded-[12px]" />), [], css)
    assert exact.message =~ ~s(Use "rounded-xl" instead)
    assert [%{replacement: "rounded-xl", exact: true}] = exact.suggestions
  end

  describe "steps of equal value" do
    defp radius(dir, css, px) do
      css = ~s(@import "tailwindcss";\n) <> css
      message(dir, "rounded-[#{px}]", [], %{"assets/css/app.css" => css})
    end

    test "Tailwind's own step comes before one the theme adds", %{tmp_dir: dir} do
      assert radius(dir, "@theme { --radius-card: 8px; }", "8px") =~ ~s(Use "rounded-lg" instead)
    end

    test "Tailwind's steps keep their order when the theme changes one", %{tmp_dir: dir} do
      assert radius(dir, "@theme { --radius-lg: 4px; }", "4px") =~ ~s(Use "rounded-sm" instead)
    end

    test "the theme's steps keep the order it declares them in", %{tmp_dir: dir} do
      css = "@theme { --radius-*: initial; --radius-zed: 4px; --radius-abc: 4px; }"
      assert radius(dir, css, "4px") =~ ~s(Use "rounded-zed" instead)
    end

    test "a step removed and declared again goes last", %{tmp_dir: dir} do
      css = "@theme { --radius-sm: initial; --radius-card: 4px; --radius-sm: 4px; }"
      assert radius(dir, css, "4px") =~ ~s(Use "rounded-card" instead)
    end
  end
end

defmodule HeexLint.Rules.NoRawColorsTest do
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  alias HeexLint.Rules.NoRawColors

  @moduletag :tmp_dir

  defp colors(dir, template, options \\ [], extra \\ %{}) do
    files = Map.merge(%{"lib/app_web/live/page_live.ex" => live(template)}, extra)
    lint(dir, files, rules: [no_raw_colors: {:error, options}])
  end

  test "theme colors pass; palette colors are reported with the nearest tokens", %{tmp_dir: dir} do
    assert colors(dir, ~s(<div class="bg-primary text-muted-foreground" />)) == []

    [finding] = colors(dir, ~s(<div class="bg-neutral-900" />))

    assert finding.message ==
             ~s|"bg-neutral-900" uses the raw Tailwind palette. Nearest theme tokens: bg-primary. Use one of those, or declare --color-<name> in assets/css/app.css for a new color.|

    # A surface is not offered -foreground tokens while a surface token is close.
    assert [%{replacement: "bg-primary"}] = finding.suggestions
  end

  test "text utilities prefer foreground tokens", %{tmp_dir: dir} do
    [finding] = colors(dir, ~s(<p class="text-neutral-500" />))
    assert finding.message =~ "Nearest theme tokens: text-muted-foreground."
  end

  test "far colors list the theme's tokens", %{tmp_dir: dir} do
    [finding] = colors(dir, ~s(<div class="bg-lime-400" />))

    assert finding.message ==
             ~s|"bg-lime-400" uses the raw Tailwind palette and no declared theme color is close to it. Use one of: background, border, destructive, foreground, muted, primary, muted-foreground, primary-foreground, or declare --color-<name> in assets/css/app.css for a new color.|
  end

  test "variants, opacity and important markers survive in suggestions", %{tmp_dir: dir} do
    [finding] = colors(dir, ~s(<div class="hover:!bg-neutral-900/50" />))
    assert hd(finding.suggestions).replacement == "hover:!bg-primary/50"
  end

  test "undeclared tokens and spelling corrections", %{tmp_dir: dir} do
    [undeclared, typo] = colors(dir, ~s(<div class="bg-highlight text-primry" />))

    assert undeclared.message =~
             ~s("bg-highlight" is not a declared theme color. Use one of: background,)

    assert undeclared.message =~
             "To add a color, declare --color-<name> in assets/css/app.css first."

    assert typo.message =~
             ~s("text-primry" is not a declared theme color. Did you mean "text-primary"?)

    assert [%{replacement: "text-primary"}] = typo.suggestions
  end

  test "readable maps spread onto an element are checked", %{tmp_dir: dir} do
    [finding] = colors(dir, ~s|<div {[class: "p-2 bg-pink-500"]} />|)
    assert finding.message =~ ~s("bg-pink-500")
  end

  test "named colors, arbitrary colors and variable shorthands pass", %{tmp_dir: dir} do
    template =
      ~s|<div class="bg-white text-black bg-transparent text-current fill-inherit bg-[#333] bg-(--brand)" />|

    assert colors(dir, template) == []
  end

  test "fill-none and stroke-none paint nothing", %{tmp_dir: dir} do
    assert colors(dir, ~s|<svg class="fill-none stroke-none" />|) == []
  end

  test "a palette name the theme declares is one of its tokens", %{tmp_dir: dir} do
    css = theme() <> "\n@theme { --color-amber-500: #f59e0b; }\n"
    assert colors(dir, ~s(<div class="bg-amber-500" />), [], %{"assets/css/app.css" => css}) == []
  end

  test "scoped namespaces declare a token for one utility", %{tmp_dir: dir} do
    css = theme() <> "\n@theme { --background-color-surface: #fafafa; }\n"

    [finding] =
      colors(dir, ~s(<div class="bg-surface text-surface" />), [], %{"assets/css/app.css" => css})

    assert finding.message =~ ~s("text-surface" is not a declared theme color.)
  end

  describe "divide-* falls back to --border-color-*, as in Tailwind" do
    @border_token %{
      "assets/css/app.css" => theme() <> "\n@theme { --border-color-edge: #e5e5e5; }\n"
    }

    test "a border color token is a divide color", %{tmp_dir: dir} do
      assert colors(dir, ~s(<ul class="divide-y divide-edge" />), [], @border_token) == []
      assert colors(dir, ~s(<ul class="hover:divide-edge/50" />), [], @border_token) == []
    end

    test "a mistyped divide class is offered the border color token", %{tmp_dir: dir} do
      [finding] = colors(dir, ~s(<ul class="divide-edgee" />), [], @border_token)

      assert finding.message =~ ~s(Did you mean "divide-edge"?)
      assert [%{replacement: "divide-edge"}] = finding.suggestions
    end

    test "its own namespace still counts, and only divide falls back", %{tmp_dir: dir} do
      css =
        theme() <> "\n@theme { --divide-color-line: #e5e5e5; --border-color-edge: #e5e5e5; }\n"

      extra = %{"assets/css/app.css" => css}

      assert colors(dir, ~s(<ul class="divide-line divide-edge" />), [], extra) == []
      assert [ring] = colors(dir, ~s(<div class="ring-edge" />), [], extra)
      assert ring.message =~ ~s("ring-edge" is not a declared theme color)
      assert [border] = colors(dir, ~s(<div class="border-line" />), [], extra)
      assert border.message =~ ~s("border-line" is not a declared theme color)
    end
  end

  test "theme namespaces that share a color prefix are not colors", %{tmp_dir: dir} do
    css = theme() <> "\n@theme { --text-stat-label: 13px; --shadow-card-glow: 0 0 4px #000; }\n"

    assert colors(dir, ~s(<div class="text-stat-label shadow-card-glow" />), [], %{
             "assets/css/app.css" => css
           }) == []
  end

  test "a class the theme declares with @utility is its vocabulary", %{tmp_dir: dir} do
    css = theme() <> "\n@utility text-brand { color: #ec4899; }\n.text-danger { color: #f00; }\n"

    [finding] =
      colors(dir, ~s(<p class="text-brand text-danger" />), [], %{"assets/css/app.css" => css})

    assert finding.message =~ ~s("text-danger" is not a declared theme color.)
  end

  test "without declared tokens, palette colors are still reported", %{tmp_dir: dir} do
    [finding] =
      colors(dir, ~s(<div class="bg-pink-500" />), [], %{
        "assets/css/app.css" => ~s(@import "tailwindcss";\n)
      })

    assert finding.message ==
             ~s|"bg-pink-500" uses the raw Tailwind palette. Use a theme token, or define one for this color.|
  end

  test "SVG color attributes", %{tmp_dir: dir} do
    template = """
    <svg class="text-primary" fill="currentColor"><path fill="var(--color-primary)" stroke="blue" /></svg>
    <svg fill="#0a0a0a" />
    <.icon name="hero-x-mark" color="red" />
    """

    [stroke, fill] = colors(dir, template)

    assert stroke.message ==
             ~s|stroke="blue" hardcodes a color. Use currentColor with a text color class, or var(--color-<token>).|

    assert fill.message ==
             ~s|fill="#0a0a0a" hardcodes a color. Use currentColor with a text color class, or the nearest theme token: var(--color-foreground).|
  end

  test "allow and deny", %{tmp_dir: dir} do
    template = ~s(<div class="text-amber-500 bg-amber-500 bg-pink-500" />)
    findings = colors(dir, template, allow: ["*-amber-*"], deny: ["bg-amber-500"])

    assert Enum.map(findings, &hd(Regex.run(~r/"[^"]+"/, &1.message))) == [
             ~s("bg-amber-500"),
             ~s("bg-pink-500")
           ]
  end

  test "deny alone checks only the named colors", %{tmp_dir: dir} do
    assert [_] = colors(dir, ~s(<div class="bg-amber-500 bg-pink-500" />), deny: ["bg-amber-500"])
  end

  test "contracts apply exceptions to one component", %{tmp_dir: dir} do
    template = """
    <.button class="bg-amber-500">Pending</.button>
    <div class="bg-amber-500">Pending</div>
    """

    [finding] = colors(dir, template, contracts: [[pattern: "^button$", allow: ["*-amber-500"]]])
    assert finding.line == 7
  end

  test "an allow entry naming a color without its utility is a config error", %{tmp_dir: dir} do
    findings = colors(dir, ~s(<div />), allow: ["amber-500"])
    # Reported at the top of every file the rule checks, which it pauses.
    assert length(findings) == 3
    finding = hd(findings)
    assert {finding.line, finding.column} == {1, 1}

    assert finding.message =~
             ~s(allow entry "amber-500" names a color, not a class, so it would match nothing.)
  end

  test "custom messages with placeholders", %{tmp_dir: dir} do
    [finding] =
      colors(dir, ~s(<div class="bg-pink-500" />),
        message: ~s(Use a theme color for "{{className}}". See {{file}}.)
      )

    assert finding.message == ~s(Use a theme color for "bg-pink-500". See assets/css/app.css.)
  end

  test "the note is appended to every message", %{tmp_dir: dir} do
    files = %{"lib/app_web/live/page_live.ex" => live(~s(<div class="bg-pink-500" />))}

    [finding] =
      lint(dir, files, rules: [no_raw_colors: :error], settings: [note: "See DESIGN.md."])

    assert String.ends_with?(finding.message, " See DESIGN.md.")
  end

  test "reads classes in helpers and assigns of the rendering function", %{tmp_dir: dir} do
    module = """
    defmodule AppWeb.StatusLive do
      use AppWeb, :live_view

      @tones %{ok: "text-emerald-600", error: "text-destructive"}

      def render(assigns) do
        assigns = assign(assigns, :tone, Map.fetch!(@tones, assigns.status))

        ~H\"\"\"
        <p class={[@tone, badge_class(@kind)]}>x</p>
        \"\"\"
      end

      defp badge_class(:new), do: "bg-sky-100"
      defp badge_class(_), do: "bg-muted"
    end
    """

    findings =
      lint(dir, %{"lib/app_web/live/status_live.ex" => module}, rules: [no_raw_colors: :error])

    assert Enum.map(findings, &hd(Regex.run(~r/"[^"]+"/, &1.message))) == [
             ~s("text-emerald-600"),
             ~s("bg-sky-100")
           ]

    assert Enum.map(findings, &{&1.line, &1.column}) == [{4, 17}, {14, 32}]
  end

  test "merge-function calls anywhere in a module are checked", %{tmp_dir: dir} do
    module = """
    defmodule AppWeb.Helpers do
      def classes(active), do: cn(["px-2", active && "bg-pink-500"])
      defp cn(list), do: Enum.join(list, " ")
    end
    """

    [finding] = lint(dir, %{"lib/app_web/helpers.ex" => module}, rules: [no_raw_colors: :error])
    assert finding.message =~ ~s("bg-pink-500")
  end

  test "scan_all_strings checks every string literal", %{tmp_dir: dir} do
    module = """
    defmodule AppWeb.Tones do
      def tone(:warning), do: "bg-amber-100 text-amber-900"
    end
    """

    files = %{"lib/app_web/tones.ex" => module}
    assert lint(dir, files, rules: [no_raw_colors: :error]) == []
    assert [_, _] = lint(dir, files, rules: [no_raw_colors: {:error, scan_all_strings: true}])
  end

  describe "scan_all_strings and map keys" do
    defp scanned(dir, body, options \\ [no_raw_colors: {:error, scan_all_strings: true}]) do
      module = """
      defmodule AppWeb.Layer do
        import AppWeb.Cn

        def layer(map, tone, on) do
          #{body}
        end
      end
      """

      helper = """
      defmodule AppWeb.Cn do
        def cn(value), do: value
      end
      """

      lint(dir, %{"lib/app_web/layer.ex" => module, "lib/app_web/cn.ex" => helper},
        rules: options
      )
    end

    test "a plain map key names a field", %{tmp_dir: dir} do
      assert scanned(dir, ~S|%{"bg-pink-500" => tone, "text-pink-500" => on}|) == []
      assert scanned(dir, ~S(%{map | "bg-pink-500" => tone})) == []
      assert scanned(dir, ~S|%{"paint" => %{"bg-pink-500" => tone}}|) == []
      assert scanned(dir, ~S|%{"bg-pink-500" => pink} = map; pink|) == []
      assert scanned(dir, ~S|Map.merge(map, %{"bg-pink-500" => tone})|) == []
    end

    test "other rules reading the scan skip them too", %{tmp_dir: dir} do
      rules = [no_arbitrary_values: {:error, scan_all_strings: true}]

      assert scanned(dir, ~S|%{"p-[13px]" => tone}|, rules) == []
      assert [_] = scanned(dir, ~S|%{tone => "p-[13px]"}|, rules)
    end

    test "map values still count", %{tmp_dir: dir} do
      assert [finding] = scanned(dir, ~S|%{"fill-color" => "bg-pink-500"}|)
      assert finding.message =~ ~s("bg-pink-500")

      assert [_] = scanned(dir, ~S(%{map | "fill-color" => "bg-pink-500"}))
      assert [_] = scanned(dir, ~S|%{fill: "bg-pink-500"}|)
    end

    test "a computed key still counts", %{tmp_dir: dir} do
      assert [_] = scanned(dir, ~S|%{String.trim("bg-pink-500") => tone}|)
    end

    test "strings in other tuples and lists still count", %{tmp_dir: dir} do
      assert [_] = scanned(dir, ~S|{"bg-pink-500", tone}|)
      assert [_] = scanned(dir, ~S|[{"bg-pink-500", tone}]|)
    end

    test "a class map key is still reached by its class site", %{tmp_dir: dir} do
      assert [finding] = scanned(dir, ~S|cn(%{"bg-pink-500" => on})|)
      assert finding.message =~ ~s("bg-pink-500")
    end

    test "class map keys count however the map reaches the merge function", %{tmp_dir: dir} do
      for body <- [
            ~S|cn(["p-1", %{"bg-pink-500" => on}])|,
            ~S|cn(if on, do: %{"bg-pink-500" => on})|,
            ~S|cn(on && %{"bg-pink-500" => on})|,
            ~S/%{"bg-pink-500" => on} |> cn()/,
            ~S/["p-1", %{"bg-pink-500" => on}] |> cn()/,
            ~S|cn(Map.merge(map, %{"bg-pink-500" => on}))|,
            ~S|tones = %{"bg-pink-500" => on}; cn(tones)|
          ] do
        assert [finding] = scanned(dir, body), body
        assert finding.message =~ ~s("bg-pink-500")
      end
    end

    test "class map keys count through module attributes and functions", %{tmp_dir: dir} do
      module = """
      defmodule AppWeb.Tones do
        import AppWeb.Cn

        @tones %{"bg-pink-500" => true}

        def a, do: cn(@tones)
        def b, do: cn(@tones)
        def c, do: cn(tones())

        defp tones, do: %{"text-pink-500" => true}

        def cn_head, do: cn(%{"border-pink-500" => true}) |> layer()

        defp layer(%{"fill-pink-500" => value}), do: value
      end
      """

      helper = "defmodule AppWeb.Cn do\n  def cn(value), do: value\nend\n"

      findings =
        lint(dir, %{"lib/app_web/tones.ex" => module, "lib/app_web/cn.ex" => helper},
          rules: [no_raw_colors: {:error, scan_all_strings: true}]
        )

      assert length(findings) == 3
      assert Enum.any?(findings, &(&1.message =~ "bg-pink-500"))
      assert Enum.any?(findings, &(&1.message =~ "text-pink-500"))
      assert Enum.any?(findings, &(&1.message =~ "border-pink-500"))
    end

    test "no_arbitrary_values reads class map keys too", %{tmp_dir: dir} do
      rules = [no_arbitrary_values: {:error, scan_all_strings: true}]

      assert [_] = scanned(dir, ~S|tones = %{"p-[13px]" => on}; cn(tones)|, rules)
    end

    test "a map that never reaches a merge function stays plain", %{tmp_dir: dir} do
      assert scanned(dir, ~S|tones = %{"bg-pink-500" => on}; tones|) == []
      assert scanned(dir, ~S|tones = %{"bg-pink-500" => on}; Map.keys(tones)|) == []
    end

    test "a merge function's own head is a pattern", %{tmp_dir: dir} do
      module = """
      defmodule AppWeb.Cn do
        def cn(%{"bg-pink-500" => value}), do: value
        def cn(%{"text-pink-500" => value}) when is_binary(value), do: value
      end
      """

      assert lint(dir, %{"lib/app_web/cn.ex" => module},
               rules: [no_raw_colors: {:error, scan_all_strings: true}]
             ) == []
    end

    test "class map keys stay out of the default scan", %{tmp_dir: dir} do
      assert scanned(dir, ~S|cn(["p-1", %{"bg-pink-500" => on}])|, no_raw_colors: :error) == []
    end
  end

  test "a color function over one theme variable is not a raw color" do
    for value <- [
          "oklch(var(--primary-oklch))",
          "oklch(var(--x) / 0.2)",
          "oklch(var(--x) / var(--alpha))",
          "  hsl( var(--x) / 50% )  "
        ] do
      refute NoRawColors.raw_color_value?(value), value
    end

    for value <- [
          "oklch(0.62 0.19 260)",
          "oklch(var(--x, 0.62 0.19 260))",
          "oklch(var(--x) var(--y))",
          "oklch(var(--x) / red)",
          "color-mix(var(--x))"
        ] do
      assert NoRawColors.raw_color_value?(value), value
    end
  end

  test "SVG attributes over one theme variable pass, literals are reported", %{tmp_dir: dir} do
    template = """
    <svg><path fill="oklch(var(--primary-oklch))" stroke="oklch(var(--border-oklch) / 0.2)" /></svg>
    """

    assert colors(dir, template) == []

    [finding] = colors(dir, ~s|<svg><path fill="oklch(var(--x, 0.5 0.1 200))" /></svg>|)
    assert finding.message =~ ~s|fill="oklch(var(--x, 0.5 0.1 200))" hardcodes a color|
  end
end

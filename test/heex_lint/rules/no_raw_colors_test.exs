defmodule HeexLint.Rules.NoRawColorsTest do
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  alias HeexLint.{Project, Sites}
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

  describe "merge-function calls no class site reads" do
    @calls [no_raw_colors: :error]
    @contract [no_raw_colors: {:error, contracts: [[pattern: "^button$", allow: ["*-pink-*"]]]}]

    defp in_code(dir, code, options \\ []) do
      module = """
      defmodule AppWeb.Styles do
        import AppWeb.Cn

        #{code}
      end
      """

      helper = "defmodule AppWeb.Cn do\n  def cn(value), do: value\nend\n"

      lint(dir, %{"lib/app_web/styles.ex" => module, "lib/app_web/cn.ex" => helper},
        rules: [no_raw_colors: {:error, options}]
      )
    end

    test "a call another call read is one finding, and one it did not read its own",
         %{tmp_dir: dir} do
      for {body, count} <- [
            {~S|cn(cn("bg-pink-500"))|, 1},
            {~S'"bg-pink-500" |> cn() |> cn()', 1},
            {~S|cn(["p-1", cn("bg-pink-500"), cn("text-pink-500")])|, 2},
            {~S|cn(if cn("bg-pink-500"), do: "p-1")|, 1},
            {~S|cn(cn("bg-pink-500") && "p-1")|, 1},
            {~S|cn(foo(cn("bg-pink-500")))|, 1},
            {~S|x = cn("bg-pink-500"); cn(x)|, 1}
          ] do
        code = "def a, do: (#{body})"

        assert length(in_code(dir, code)) == count, body
      end
    end

    test "are checked wherever a template has them", %{tmp_dir: dir} do
      for template <- [
            ~S|<div title={cn("bg-pink-500")} />|,
            ~S|<div>{cn("bg-pink-500")}</div>|,
            ~S|<div>{render_slot(@a, cn("bg-pink-500"))}</div>|,
            ~S|<.button {Map.put(@rest, :class, cn("bg-pink-500"))}>x</.button>|,
            ~S|<div {%{title: cn("bg-pink-500")}} />|,
            ~S|<div class={foo(cn("bg-pink-500"))} />|,
            ~S|<div class={if cn("bg-pink-500"), do: "p-1", else: "p-2"} />|,
            ~S|<div class={cn("p-1", foo(cn("bg-pink-500")))} />|,
            ~S|<% c = cn("bg-pink-500") %><b class={c} />|,
            ~S|<%= cn("bg-pink-500") %>|,
            ~S|<%= if cn("bg-pink-500") do %>x<% end %>|,
            ~S|<div :if={cn("bg-pink-500")} />|,
            ~S|<div :for={x <- cn("bg-pink-500")} />|,
            ~S|<div style={cn("bg-pink-500")} />|,
            ~S|<div style={"--x: #{cn("bg-pink-500")}"} />|,
            ~S|<div data-class={cn("bg-pink-500")} />|,
            ~S|<.card><:foo title={cn("bg-pink-500")}>x</:foo></.card>|,
            ~S|<div title={Tails.classes("bg-pink-500")} />|,
            ~S[<div title={"bg-pink-500" |> cn()} />],
            ~S[<div title={"bg-pink-500" |> cn() |> foo()} />]
          ] do
        assert [finding] = colors(dir, template), template
        assert finding.message =~ ~s("bg-pink-500"), template
      end
    end

    test "but only those", %{tmp_dir: dir} do
      assert colors(dir, ~S|<div title={other("bg-pink-500")} />|) == []
      assert colors(dir, ~S|<div title={@cn} />|) == []
      assert colors(dir, ~S|<div title={cn} />|) == []
      assert colors(dir, ~S|<div title="cn('bg-pink-500')" />|) == []
      assert colors(dir, ~S|<div title={@v.cn("bg-pink-500")} />|) == []
      assert colors(dir, ~S|<%!-- cn("bg-pink-500") --%><!-- {cn("bg-pink-500")} -->|) == []
      assert colors(dir, ~S|<%% cn("bg-pink-500") %>|) == []
    end

    test "are one finding when one reads another", %{tmp_dir: dir} do
      assert [_] = colors(dir, ~S|<div title={cn("p-1", cn("bg-pink-500"))} />|)
      assert [_] = colors(dir, ~S|<div title={cn(cn(cn("bg-pink-500")))} />|)
      assert [_] = colors(dir, ~S|<div class={cn("p-1", cn("bg-pink-500"))} />|)
    end

    test "a call a class site reads stays that site's", %{tmp_dir: dir} do
      for template <- [
            ~S|<.button class={cn("bg-pink-500")}>x</.button>|,
            ~S|<.button class={cn("p-1", cn("bg-pink-500"))}>x</.button>|,
            ~S|<.button class={@a && cn("bg-pink-500")}>x</.button>|,
            ~S|<.button class={if @a, do: cn("bg-pink-500")}>x</.button>|,
            ~S|<.button class={[cn("bg-pink-500")]}>x</.button>|,
            ~S|<.button {%{class: cn("bg-pink-500")}}>x</.button>|,
            ~S[<.button class={"bg-pink-500" |> cn()}>x</.button>]
          ] do
        files = %{"lib/app_web/live/page_live.ex" => live(template)}
        assert lint(dir, files, rules: @contract) == [], template
      end
    end

    test "any other call is on no component, so a contract does not reach it", %{tmp_dir: dir} do
      for template <- [
            ~S|<.button title={cn("bg-pink-500")}>x</.button>|,
            ~S|<.button class={foo(cn("bg-pink-500"))}>x</.button>|,
            ~S|<.button class={cn("p-1", foo(cn("bg-pink-500")))}>x</.button>|,
            ~S|<.button class={if cn("bg-pink-500"), do: "p-1", else: "p-2"}>x</.button>|,
            ~S|<.button class={cn("bg-pink-500") && "p-1"}>x</.button>|,
            ~S|<.button {Map.put(@rest, :class, cn("bg-pink-500"))}>x</.button>|
          ] do
        files = %{"lib/app_web/live/page_live.ex" => live(template)}
        assert [finding] = lint(dir, files, rules: @contract), template
        refute finding.message =~ ".button", template
      end
    end

    test "a class site does not claim another attribute's call", %{tmp_dir: dir} do
      template = ~S|<.button class={cn("bg-pink-500")} title={cn("bg-pink-500")}>x</.button>|
      files = %{"lib/app_web/live/page_live.ex" => live(template)}
      assert [%{column: column}] = lint(dir, files, rules: @contract)
      assert column > String.length(~S|<.button class={cn("bg-pink-500")} title|)
    end

    test "are reported at the literal", %{tmp_dir: dir} do
      assert [{1, 15, "bg-pink-500"}] =
               in_template(dir, ~S|<b title={cn("bg-pink-500")} />|, @calls)

      assert [{1, 9, "bg-pink-500"}] = in_template(dir, ~S|<b>{cn("bg-pink-500")}</b>|, @calls)
      assert [{1, 9, "bg-pink-500"}] = in_template(dir, ~S|<%= cn("bg-pink-500") %>|, @calls)

      assert [{4, 2, "bg-pink-500"}] =
               in_template(dir, ~s|<b\n  title={cn(\n"p-1",\n"bg-pink-500")} />|, @calls)
    end

    test "are reported at the literal in a sigil", %{tmp_dir: dir} do
      module = """
      defmodule AppWeb.Page do
        use Phoenix.Component

        def page(assigns) do
          ~H\"\"\"
          <b
            title={cn("bg-pink-500")}
          />
          \"\"\"
        end
      end
      """

      assert [%{line: 7, column: 18}] =
               lint(dir, %{"lib/app_web/page.ex" => module}, rules: @calls)
    end

    test "read assigns, props and the module's functions as a class site does", %{tmp_dir: dir} do
      helpers = ~S|def tone, do: "bg-pink-500"|

      module =
        component_module(
          "Rows",
          "row",
          ~S|attr :class, :string, default: "bg-pink-600"|,
          ~S|<b title={cn(@class, tone())} />|,
          "assigns = assign(assigns, :a, 1)\n"
        )
        |> String.replace("end\nend\n", "end\n#{helpers}\nend\n")

      files = %{"lib/app_web/rows.ex" => module}
      found = lint(dir, files, rules: @calls)
      assert found |> Enum.map(& &1.message) |> Enum.count(&(&1 =~ ~s("bg-pink-500"))) == 1
      assert found |> Enum.map(& &1.message) |> Enum.count(&(&1 =~ ~s("bg-pink-600"))) == 1
    end

    test "are read from a function by an embedded template, at the call", %{tmp_dir: dir} do
      files = %{
        "lib/app_web/page.ex" => """
        defmodule AppWeb.Page do
          use Phoenix.Component
          embed_templates "page/*"
          def tone, do: "bg-pink-500"
        end
        """,
        "lib/app_web/page/show.html.heex" => ~S|<b title={cn(tone())} />| <> "\n"
      }

      assert [%{line: 1, column: 14} = finding] = lint(dir, files, rules: @calls)
      assert Path.basename(finding.file) == "show.html.heex"
    end

    test "answer to the configured names", %{tmp_dir: dir} do
      assert colors(dir, ~S|<div title={classes("bg-pink-500")} />|) == []

      assert [_] =
               colors(dir, ~S|<div title={classes("bg-pink-500")} />|,
                 merge_functions: ["classes"]
               )

      assert [_] =
               colors(dir, ~S|<div title={Helpers.classes("bg-pink-500")} />|,
                 merge_functions: ["Helpers.classes"]
               )

      assert colors(dir, ~S|<div title={tv(%{base: "bg-pink-500"})} />|) == []

      assert [_] =
               colors(dir, ~S|<div title={tv(%{base: "bg-pink-500"})} />|,
                 variant_functions: ["tv"]
               )
    end

    for {name, template} <- [
          {"a class attribute", ~S[<div class={tv(%{@base | base: "bg-pink-500"})} />]},
          {"another attribute", ~S[<div title={tv(%{@base | base: "bg-pink-500"})} />]},
          {":if", ~S[<div :if={tv(%{@base | base: "bg-pink-500"})} />]},
          {"a body", ~S[<div>{tv(%{@base | base: "bg-pink-500"})}</div>]}
        ] do
      test "a map update in #{name} has its entries read", %{tmp_dir: dir} do
        assert [finding] = colors(dir, unquote(template), variant_functions: ["tv"])
        assert finding.message =~ ~s("bg-pink-500")
      end
    end

    test "a map update in code has its entries read", %{tmp_dir: dir} do
      for code <- [
            ~S[@x tv(%{@y | base: "bg-pink-500"})],
            ~S[def a(b \\ tv(%{y() | base: "bg-pink-500"})), do: b],
            ~S[tv(%{y() | base: "bg-pink-500"})]
          ] do
        module = "defmodule AppWeb.Code do\n#{code}\nend\n"
        rules = [no_raw_colors: {:error, variant_functions: ["tv"]}]
        assert [_] = lint(dir, %{"lib/app_web/code.ex" => module}, rules: rules), code
      end
    end

    test "a map update's string keys have their values read too", %{tmp_dir: dir} do
      for {update, count} <- [
            {~S["base" => "bg-pink-500"], 1},
            {~S[:base => "bg-pink-500", "class" => "bg-red-500"], 2},
            {~S["variants" => %{"s" => %{"x" => "bg-pink-500"}}], 1}
          ] do
        template = "<div class={tv(%{@a | #{update}})} />"
        findings = colors(dir, template, variant_functions: ["tv"])
        assert length(findings) == count, template
      end
    end

    test "a variant config reads only what holds classes", %{tmp_dir: dir} do
      for config <- [
            ~S|%{meta: "bg-pink-500"}|,
            ~S|%{default_variants: %{size: "bg-pink-500"}}|,
            ~S|%{compound_variants: [%{size: "bg-pink-500", class: "p-1"}]}|,
            ~S|[meta: "bg-pink-500"]|
          ] do
        assert colors(dir, "<div title={tv(#{config})} />", variant_functions: ["tv"]) == [],
               config
      end

      for config <- [
            ~S|%{base: "bg-pink-500"}|,
            ~S|%{"base" => "bg-pink-500"}|,
            ~S|%{class: "bg-pink-500"}|,
            ~S|%{slots: %{title: "bg-pink-500"}}|,
            ~S|%{variants: %{size: %{sm: "bg-pink-500"}}}|,
            ~S|%{compound_variants: [%{size: "sm", class: "bg-pink-500"}]}|,
            ~S|%{compound_slots: [[slots: ["title"], class_name: "bg-pink-500"]]}|,
            ~S|[base: "bg-pink-500"]|
          ] do
        assert [finding] = colors(dir, "<div title={tv(#{config})} />", variant_functions: ["tv"]),
               config

        assert finding.message =~ ~s("bg-pink-500")
      end
    end

    test "a merge call reads a map's keys and not its values", %{tmp_dir: dir} do
      assert [finding] = colors(dir, ~S|<div class={cn(%{"bg-pink-500" => @on})} />|)
      assert finding.message =~ ~s("bg-pink-500")
      assert {finding.line, finding.column} == {6, 23}

      assert [finding] =
               colors(
                 dir,
                 ~S|<div class={cn(["p-1", %{"p-2" => "bg-pink-500"}, %{"bg-lime-400" => 1}])} />|
               )

      assert finding.message =~ ~s("bg-lime-400")

      assert [_] = colors(dir, ~S|<div title={cn(%{@a \| "bg-pink-500" => @on})} />|)
    end

    test "a map outside a merge call has no class keys", %{tmp_dir: dir} do
      assert colors(dir, ~S|<div data-x={%{"bg-pink-500" => @on}} />|) == []
    end

    test "a variant call inside a merge call keeps its rule", %{tmp_dir: dir} do
      assert colors(dir, ~S|<div title={cn(tv(%{meta: 1, "bg-pink-500" => 1}))} />|,
               variant_functions: ["tv"]
             ) == []
    end

    test "a ~s hole is read as a string's is", %{tmp_dir: dir} do
      assert [finding] = colors(dir, ~S|<div class={~s(p-2 #{"bg-pink-500"})} />|)
      assert finding.message =~ ~s("bg-pink-500")

      assert [finding] = colors(dir, ~S|<div class={~s(bg-pink-500 #{@x} p-1)} />|)
      assert {finding.line, finding.column} == {6, 20}

      assert [finding] = colors(dir, ~S|<div class={~s(#{@x} bg-pink-500)} />|)
      assert {finding.line, finding.column} == {6, 26}
    end

    test "a ~s hole on an assigned table reads it", %{tmp_dir: dir} do
      module = fn read ->
        """
        defmodule AppWeb.Tabled do
          use AppWeb, :html

          def render(assigns) do
            assigns = assign(assigns, :t, %{a: "bg-pink-500"})
            ~H"<.button class={~s(p-2 \#{#{read}})}>x</.button>"
          end
        end
        """
      end

      for read <- ["@t.a", "@t[:a]"] do
        assert [finding] =
                 lint(dir, %{"lib/app_web/tabled.ex" => module.(read)},
                   rules: [no_raw_colors: :error]
                 ),
               read

        assert finding.message =~ "bg-pink-500"
      end

      assert [finding] =
               lint(dir, %{"lib/app_web/tabled.ex" => module.("@t[@v]")},
                 rules: [require_static_classes: :error]
               )

      assert finding.message =~ "cannot be checked"
    end

    test "two modules on one line keep their own code", %{tmp_dir: dir} do
      for code <- [
            ~S|defmodule A do @x cn("bg-pink-500"); end; defmodule A do @y cn("bg-red-500"); end|,
            ~S|defmodule A.B do @x cn("bg-pink-500"); end; defmodule A do defmodule B do @y cn("bg-red-500"); end; end|
          ] do
        assert [_, _] = lint(dir, %{"lib/app_web/one.ex" => code <> "\n"}, rules: @calls), code
      end
    end

    test "an attribute named like one holds no map keys", %{tmp_dir: dir} do
      module = """
      defmodule AppWeb.Named do
        @cn %{"fill-color" => true}
        @x cn(%{"bg-pink-500" => true})
      end
      """

      rules = [no_raw_colors: {:error, scan_all_strings: true}]
      assert [finding] = lint(dir, %{"lib/app_web/named.ex" => module}, rules: rules)
      assert finding.message =~ "bg-pink-500"
    end

    test "a variant config's base and any other entry end nothing", %{tmp_dir: dir} do
      assert colors(dir, ~S[<div title={tv(%{@a | b})} />], variant_functions: ["tv"]) == []

      for template <- [
            ~S|<div title={tv(%{unquote_splicing(@y)})} />|,
            ~S[<div title={tv(%{@a | "k" => @b})} />]
          ] do
        assert colors(dir, template, variant_functions: ["tv"]) == [], template
      end

      assert [_] =
               colors(dir, ~S[<div title={tv(%{%{base: "bg-pink-500"} | class: "p-1"})} />],
                 variant_functions: ["tv"]
               )
    end

    test "reach the other class rules, and none about a component", %{tmp_dir: dir} do
      template = ~S|<.button title={cn("bg-(--nope) p-[13px] foo()")}>x</.button>|
      files = %{"lib/app_web/live/page_live.ex" => live(template)}

      rules = [no_arbitrary_values: :error, no_unknown_variables: :error]

      assert [%{rule: :no_arbitrary_values}, %{rule: :no_unknown_variables}] =
               lint(dir, files, rules: rules) |> Enum.sort_by(& &1.rule)

      assert lint(dir, files, rules: [no_restyle: :error, require_static_classes: :error]) == []
    end

    test "--fix rewrites them in place", %{tmp_dir: dir} do
      for {template, fixed} <- [
            {~S|<b title={cn("p-[16px]")} />|, ~S|<b title={cn("p-4")} />|},
            {~S|<b>{cn("p-1", "p-[16px]")}</b>|, ~S|<b>{cn("p-1", "p-4")}</b>|},
            {~S|<%= cn("p-[16px]") %>|, ~S|<%= cn("p-4") %>|},
            {~S|<b class={foo(cn("p-[16px]"))} />|, ~S|<b class={foo(cn("p-4"))} />|}
          ] do
        files = %{
          "lib/app_web/page.ex" =>
            "defmodule AppWeb.Page do\n  use Phoenix.Component\n  embed_templates \"page/*\"\nend\n",
          "lib/app_web/page/show.html.heex" => template <> "\n",
          "lib/app_web/live/page_live.ex" => live(template)
        }

        result = run(dir, files, rules: [no_arbitrary_values: :error])
        assert HeexLint.Fixer.apply(result.diagnostics) == 2, template
        assert File.read!(Path.join(dir, "lib/app_web/page/show.html.heex")) == fixed <> "\n"
        assert File.read!(Path.join(dir, "lib/app_web/live/page_live.ex")) == live(fixed)
      end
    end

    test "do not add to a template that does not parse, or code that does not", %{tmp_dir: dir} do
      assert colors(dir, ~S|<div title={cn("bg-pink-500"} />|) == []
      assert colors(dir, ~S|<div title={cn(} />|) == []
    end

    test "a tag a block leaves open does not parse alone, so it is unread", %{tmp_dir: dir} do
      assert colors(dir, ~S|<%= Enum.map(cn("bg-pink-500"), fn x -> %><b /><% end) %>|) == []
      assert colors(dir, ~S|<%= Enum.map(@a, fn x -> %><b /><% end, cn("bg-pink-500")) %>|) == []
    end

    test "are checked anywhere in Elixir code", %{tmp_dir: dir} do
      for code <- [
            ~S|@x cn("bg-pink-500")|,
            ~S|@x Tails.classes("bg-pink-500")|,
            ~S|def a(x \\ cn("bg-pink-500")), do: x|,
            ~S|def a(x \\ cn("bg-pink-500")) when is_binary(x), do: x|,
            ~S|defp a(x \\ cn("bg-pink-500")), do: x|,
            ~S|attr :foo, :string, default: cn("bg-pink-500")|,
            ~S|cn("bg-pink-500")|,
            ~S[def a, do: "bg-pink-500" |> cn()],
            ~S[def a, do: "bg-pink-500" |> cn() |> String.trim()],
            ~S|if true do def a, do: cn("bg-pink-500") end|,
            ~S|for x <- [1] do def a(unquote(x)), do: cn("bg-pink-500") end|,
            ~S|def unquote(:a)(), do: cn("bg-pink-500")|,
            ~S|if true do defmodule In do def a, do: cn("bg-pink-500") end end|
          ] do
        assert [finding] = in_code(dir, code), code
        assert finding.message =~ ~s("bg-pink-500"), code
      end
    end

    test "in a function's other sections too", %{tmp_dir: dir} do
      for section <- ["rescue\n  _ -> ", "catch\n  _ -> ", "else\n  _ -> ", "after\n  "] do
        code = ~s|def a do\n  :ok\n#{section}cn("bg-pink-500")\nend|
        assert [_] = in_code(dir, code), code
      end
    end

    test "an attribute named like one is no call", %{tmp_dir: dir} do
      assert in_code(dir, ~S|@cn "bg-pink-500"|) == []

      module = """
      defmodule AppWeb.Named do
        @classes "bg-pink-500"
        def a, do: @classes
      end
      """

      rules = [no_raw_colors: {:error, merge_functions: ["classes"]}]
      assert lint(dir, %{"lib/app_web/named.ex" => module}, rules: rules) == []
    end

    test "but what it holds can be", %{tmp_dir: dir} do
      assert [_] = in_code(dir, ~S|@cn cn("bg-pink-500")|)
    end

    test "outside a function they read the module's attributes", %{tmp_dir: dir} do
      assert [_] = in_code(dir, ~s|@a "bg-pink-500"\n@b cn(@a)|)
      assert [_] = in_code(dir, ~s|@a "bg-pink-500"\ndef b(c \\\\ cn(@a)), do: c|)
    end

    test "a nested module reads its own attributes, once", %{tmp_dir: dir} do
      code = """
      @a "p-1"

      defmodule In do
        @a "bg-pink-500"
        @b cn(@a)
      end
      """

      assert [finding] = in_code(dir, code)
      assert finding.message =~ ~s("bg-pink-500")
    end

    test "and in a file with no module", %{tmp_dir: dir} do
      files = %{"lib/app_web/script.exs" => ~S|Tails.classes("bg-pink-500")| <> "\n"}
      assert [_] = lint(dir, files, rules: @calls)
    end

    test "a function's own head is a pattern and no call", %{tmp_dir: dir} do
      for code <- [
            ~S|def cn(%{"bg-pink-500" => value}), do: value|,
            ~S|def cn("bg-pink-500"), do: 1|,
            ~S|def cn(value) when value == "bg-pink-500", do: value|,
            ~S|def cn(x \\ "bg-pink-500"), do: x|,
            ~S|if true do def cn("bg-pink-500"), do: 1 end|,
            ~S|defmacro cn("bg-pink-500"), do: 1|
          ] do
        assert in_code(dir, code) == [], code
      end
    end
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

  describe "a defimpl" do
    test "a merge call's variable is followed, under plain rules", %{tmp_dir: dir} do
      module = ~S"""
      defimpl String.Chars, for: Foo do
        @tone "text-pink-500"

        def to_string(_) do
          x = "bg-pink-500"
          cn([x, @tone, tone()])
        end

        defp tone, do: "border-pink-500"
      end
      """

      findings = lint(dir, %{"lib/app_web/foo.ex" => module}, rules: [no_raw_colors: :error])

      assert findings |> Enum.map(&{&1.line, hd(String.split(&1.message, " "))}) |> Enum.sort() ==
               [
                 {2, ~s("text-pink-500")},
                 {5, ~s("bg-pink-500")},
                 {9, ~s("border-pink-500")}
               ]
    end

    test "a direct call is one finding, and a one-line defimpl is read too", %{tmp_dir: dir} do
      module = ~S"""
      defimpl String.Chars, for: Foo, do: def(to_string(_), do: cn("bg-pink-500"))

      defimpl Enumerable, for: Foo do
        def count(_), do: cn("text-pink-500")
      end
      """

      assert [_, _] = lint(dir, %{"lib/app_web/foo.ex" => module}, rules: [no_raw_colors: :error])
    end

    test "a template stays unread, as it was", %{tmp_dir: dir} do
      module = ~S"""
      defimpl String.Chars, for: Foo do
        use Phoenix.Component
        def to_string(assigns), do: ~H"<div class='bg-pink-500' />"
      end
      """

      assert lint(dir, %{"lib/app_web/foo.ex" => module}, rules: [no_raw_colors: :error]) == []
    end
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

    for {shape, code} <- [
          {"an attribute's call", [~S|@tones %{"bg-pink-500" => true}|, "@x cn(@tones)"]},
          {"a default argument",
           [~S|@tones %{"bg-pink-500" => true}|, ~S|def d(a \\ cn(@tones)), do: a|]},
          {"a literal default argument", [~S|def d(a \\ cn(%{"bg-pink-500" => true})), do: a|]}
        ] do
      test "a map read outside a function body: #{shape}", %{tmp_dir: dir} do
        module = """
        defmodule AppWeb.Outside do
          import AppWeb.Cn
          #{Enum.join(unquote(code), "\n  ")}
        end
        """

        helper = "defmodule AppWeb.Cn do\n  def cn(value), do: value\nend\n"

        assert [_one] =
                 lint(dir, %{"lib/app_web/outside.ex" => module, "lib/app_web/cn.ex" => helper},
                   rules: [no_raw_colors: {:error, scan_all_strings: true}]
                 )
      end
    end

    for {shape, setup, read} <- [
          {"a dot", ~S|t = %{a: %{"bg-pink-500" => true}}|, "t.a"},
          {"Access", ~S|t = %{a: %{"bg-pink-500" => true}}|, "t[:a]"},
          {"Map.get", ~S|t = %{a: %{"bg-pink-500" => true}}|, "Map.get(t, :a)"},
          {"an assign and a dot",
           ~S|assigns = assign(assigns, :t, %{a: %{"bg-pink-500" => true}})|, "@t.a"},
          {"an assign and Access",
           ~S|assigns = assign(assigns, :t, %{a: %{"bg-pink-500" => true}})|, "@t[:a]"}
        ] do
      test "a table lookup in a template's merge call: #{shape}", %{tmp_dir: dir} do
        module = """
        defmodule AppWeb.Looked do
          use AppWeb, :html
          import AppWeb.Cn

          def looked(assigns) do
            #{unquote(setup)}
            ~H\"\"\"
            <div class={cn(#{unquote(read)})} />
            \"\"\"
          end
        end
        """

        helper = "defmodule AppWeb.Cn do\n  def cn(value), do: value\nend\n"

        assert [_one] =
                 lint(dir, %{"lib/app_web/looked.ex" => module, "lib/app_web/cn.ex" => helper},
                   rules: [no_raw_colors: {:error, scan_all_strings: true}]
                 )
      end
    end

    test "an attr's default leaves an assigned table in the assigning function", %{tmp_dir: dir} do
      helper = "defmodule AppWeb.Cn do\n  def cn(value), do: value\nend\n"

      module = """
      defmodule AppWeb.Tabled do
        use AppWeb, :html
        import AppWeb.Cn

        attr :t, :map, default: %{}
        def comp(assigns), do: ~H"<i />"

        def mount(_, _, socket) do
          t = %{a: %{"bg-pink-500" => 1}}
          {:ok, assign(socket, :t, t)}
        end

        def render(assigns) do
          t = %{a: %{"bg-red-500" => 1}}
          _ = t
          ~H"<div class={cn(@t.a)} />"
        end
      end
      """

      assert [finding] =
               lint(
                 dir,
                 %{"lib/app_web/tabled.ex" => module, "lib/app_web/cn.ex" => helper},
                 rules: [no_raw_colors: {:error, scan_all_strings: true}]
               )

      assert finding.message =~ "bg-pink-500"
    end

    test "an assigned table's variable is the assigning function's", %{tmp_dir: dir} do
      helper = "defmodule AppWeb.Cn do\n  def cn(value), do: value\nend\n"

      module = fn render ->
        """
        defmodule AppWeb.Tabled do
          use AppWeb, :html
          import AppWeb.Cn

          def mount(_, _, socket) do
            t = %{a: %{"bg-pink-500" => 1}}
            {:ok, assign(socket, :t, t)}
          end

          def render(assigns) do
            #{render}
            ~H"<div class={cn(@t.a)} />"
          end
        end
        """
      end

      for render <- [~S|t = %{a: %{"bg-red-500" => 1}}|, "x = 1"] do
        assert [finding] =
                 lint(
                   dir,
                   %{"lib/app_web/tabled.ex" => module.(render), "lib/app_web/cn.ex" => helper},
                   rules: [no_raw_colors: {:error, scan_all_strings: true}]
                 )

        assert finding.message =~ "bg-pink-500"
      end
    end

    test "a module inside a defimpl keeps its merge calls", %{tmp_dir: dir} do
      module = """
      defimpl R, for: Foo do
        defmodule Inner do
          def f(_x), do: cn("bg-pink-500")
        end
      end
      """

      helper = "defmodule AppWeb.Cn do\n  def cn(value), do: value\nend\n"

      assert [_finding] =
               lint(dir, %{"lib/app_web/impl.ex" => module, "lib/app_web/cn.ex" => helper},
                 rules: [no_raw_colors: :error]
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

    test "a nested call's map is read, once", %{tmp_dir: dir} do
      for body <- [
            ~S|cn(cn(%{"bg-pink-500" => on}))|,
            ~S'%{"bg-pink-500" => on} |> cn() |> cn()',
            ~S|cn(if cn(%{"bg-pink-500" => on}), do: "p-1")|
          ] do
        assert [finding] = scanned(dir, body)
        assert finding.message =~ "bg-pink-500"
      end
    end

    test "a map through Map.put keeps its keys and adds the one put", %{tmp_dir: dir} do
      for body <- [
            ~S|base = %{"bg-pink-500" => on}; cn(Map.put(base, "k", tone))|,
            ~S't = %{"bg-pink-500" => on} |> Map.put("k", 1); cn(t)',
            ~S'%{"bg-pink-500" => on} |> Map.put("k", 1) |> cn()',
            ~S|cn(Map.put(map, "bg-pink-500", on))|
          ] do
        assert [finding] = scanned(dir, body)
        assert finding.message =~ "bg-pink-500"
      end

      assert scanned(dir, ~S|cn(Map.delete(%{"bg-pink-500" => on}, "k"))|) == []
    end

    test "an assign through Map.put in a template's merge call is read", %{tmp_dir: dir} do
      body = ~S"""
      def a(assigns) do
        assigns = assign(assigns, :t, %{"bg-pink-500" => true})
        ~H|<div class={cn(Map.put(@t, :k, 1))} />|
      end
      """

      assert [finding] = templated(dir, body)
      assert finding.message =~ "bg-pink-500"
    end

    test "a variable in a defimpl is followed", %{tmp_dir: dir} do
      for module <- [
            ~S"""
            defimpl String.Chars, for: Foo do
              def to_string(on) do
                tones = %{"bg-pink-500" => on}
                cn(tones)
              end
            end
            """,
            ~S"""
            defmodule AppWeb.Foo do
              defimpl String.Chars do
                def to_string(on) do
                  tones = %{"bg-pink-500" => on}
                  cn(tones)
                end
              end
            end
            """
          ] do
        assert [finding] =
                 lint(dir, %{"lib/app_web/foo.ex" => module},
                   rules: [no_raw_colors: {:error, scan_all_strings: true}]
                 )

        assert finding.message =~ "bg-pink-500"
      end
    end

    test "a module two files define follows the variables of each", %{tmp_dir: dir} do
      module = fn body -> "defmodule AppWeb.Dup do\n  def cn(x), do: x\n#{body}\nend\n" end

      files = %{
        "lib/a.ex" => module.(~S|def a(on), do: {@first, on}|),
        "lib/b.ex" =>
          module.(~S"""
          @tones %{"text-pink-500" => true}

          def b(on) do
            tones = %{"bg-pink-500" => on}
            cn(tones)
          end

          def c, do: cn(@tones)
          """)
      }

      messages =
        dir
        |> lint(files, rules: [no_raw_colors: {:error, scan_all_strings: true}])
        |> Enum.map(&{Path.basename(&1.file), &1.line, hd(String.split(&1.message, " "))})

      assert messages == [{"b.ex", 3, ~s("text-pink-500")}, {"b.ex", 6, ~s("bg-pink-500")}]
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

    # A module whose ~H template calls cn, so its map keys are read only there.
    defp templated(dir, body, files \\ %{}, options \\ nil) do
      module = """
      defmodule AppWeb.Layer do
        use Phoenix.LiveView
        import AppWeb.Cn

        #{body}
      end
      """

      helper = "defmodule AppWeb.Cn do\n  def cn(value), do: value\nend\n"

      lint(
        dir,
        Map.merge(files, %{"lib/app_web/layer.ex" => module, "lib/app_web/cn.ex" => helper}),
        rules: options || [no_raw_colors: {:error, scan_all_strings: true}]
      )
    end

    test "an assign set by the qualified call or a map update is followed", %{tmp_dir: dir} do
      for set <- [
            ~S|Phoenix.Component.assign(assigns, :tones, %{"bg-pink-500" => true})|,
            ~S|Phoenix.Component.assign(assigns, tones: %{"bg-pink-500" => true})|,
            ~S'assigns |> Phoenix.Component.assign(:tones, %{"bg-pink-500" => true})',
            ~S|Phoenix.Component.assign_new(assigns, :tones, fn -> %{"bg-pink-500" => true} end)|,
            ~S'%{assigns | tones: %{"bg-pink-500" => true}}'
          ] do
        body = """
        def a(assigns) do
          assigns = #{set}
          ~H"<div class={cn(@tones)} />"
        end
        """

        assert [finding] = templated(dir, body)
        assert finding.message =~ "bg-pink-500"
      end
    end

    test "a map update of something else sets no assign", %{tmp_dir: dir} do
      body = ~S"""
      def a(assigns) do
        other = %{assigns.other | tones: %{"bg-pink-500" => true}}
        ~H"<div class={cn(@tones)} data-x={other} />"
      end
      """

      assert templated(dir, body) == []
    end

    test "class map keys count when a template's merge call reads them", %{tmp_dir: dir} do
      for body <- [
            ~S"""
            def a(assigns) do
              tones = %{"bg-pink-500" => assigns.on}
              ~H"<div class={cn(tones)} />"
            end
            """,
            ~S"""
            def a(assigns) do
              tones = if assigns.on, do: %{"bg-pink-500" => true}
              ~H"<div class={cn(tones)} />"
            end
            """,
            ~S"""
            def a(assigns) do
              assigns = assign(assigns, :tones, %{"bg-pink-500" => true})
              ~H"<div class={cn(@tones)} />"
            end
            """,
            ~S"""
            def a(assigns) do
              assigns = assign(assigns, :tones, %{"bg-pink-500" => true})
              ~H"<div class={cn(assigns.tones)} />"
            end
            """,
            ~S"""
            def mount(_params, _session, socket) do
              {:ok, assign(socket, :tones, %{"bg-pink-500" => true})}
            end

            def render(assigns), do: ~H"<div class={cn(@tones)} />"
            """,
            ~S"""
            def mount(_params, _session, socket) do
              tones = %{"bg-pink-500" => true}
              {:ok, assign(socket, tones: tones)}
            end

            def render(assigns), do: ~H"<div class={cn(@tones)} />"
            """,
            ~S"""
            @tones %{"bg-pink-500" => true}

            def a(assigns) do
              assigns = assign(assigns, :tones, @tones)
              ~H"<div class={cn(@tones)} />"
            end
            """,
            ~S"""
            attr :tones, :map, default: %{"bg-pink-500" => true}

            def a(assigns), do: ~H"<div class={cn(@tones)} />"
            """,
            ~S"""
            def a(assigns) do
              assigns = assign(assigns, :tones, %{"bg-pink-500" => true})
              ~H"<span>{cn(@tones)}</span>"
            end
            """,
            ~S"""
            def a(assigns) do
              assigns = assign(assigns, :tones, %{"bg-pink-500" => true})
              ~H"<span><%= cn(@tones) %></span>"
            end
            """,
            ~S"""
            def a(assigns) do
              assigns = assign(assigns, :tones, %{"bg-pink-500" => true})
              ~H"<%= if cn(@tones) do %><b>x</b><% end %>"
            end
            """
          ] do
        assert [finding] = templated(dir, body), body
        assert finding.message =~ ~s("bg-pink-500")
        assert finding.file =~ "layer.ex"
      end
    end

    test "class map keys count in a table an assign holds", %{tmp_dir: dir} do
      body = ~S"""
      def a(assigns) do
        assigns = assign(assigns, :tones, %{warn: %{"bg-pink-500" => true}})
        ~H"<div class={cn(@tones.warn)} />"
      end
      """

      assert [_finding] = templated(dir, body)
    end

    test "class map keys count when an embedded template reads them", %{tmp_dir: dir} do
      template = ~S|<div class={cn(@tones)} />|

      embedded = ~S"""
      embed_templates "inner/*"

      def a(assigns) do
        assigns = assign(assigns, :tones, %{"bg-pink-500" => true})
        card(assigns)
      end
      """

      assert [finding] =
               templated(dir, embedded, %{"lib/app_web/inner/card.html.heex" => template})

      assert finding.file =~ "layer.ex"

      colocated = ~S"""
      def mount(_params, _session, socket) do
        {:ok, assign(socket, :tones, %{"bg-pink-500" => true})}
      end
      """

      assert [finding] = templated(dir, colocated, %{"lib/app_web/layer.html.heex" => template})
      assert finding.file =~ "layer.ex"
    end

    test "a template's merge call reads through no_arbitrary_values too", %{tmp_dir: dir} do
      body = ~S"""
      def a(assigns) do
        assigns = assign(assigns, :tones, %{"p-[13px]" => true})
        ~H"<div class={cn(@tones)} />"
      end
      """

      assert [_] =
               templated(dir, body, %{}, no_arbitrary_values: {:error, scan_all_strings: true})
    end

    test "two template calls reading one map are one finding", %{tmp_dir: dir} do
      body = ~S"""
      def a(assigns) do
        assigns = assign(assigns, :tones, %{"bg-pink-500" => true})
        ~H"<div class={cn(@tones)} /><div class={cn(@tones)} />"
      end
      """

      assert [_] = templated(dir, body)
    end

    test "a template without a merge call leaves a map plain", %{tmp_dir: dir} do
      for body <- [
            ~S"""
            def a(assigns) do
              assigns = assign(assigns, :tones, %{"bg-pink-500" => true})
              ~H"<div title={@tones} />"
            end
            """,
            ~S"""
            def a(assigns) do
              tones = %{"bg-pink-500" => true}
              ~H"<div title={tones} />"
            end
            """,
            ~S"""
            def a(assigns) do
              assigns = assign(assigns, :fields, %{"bg-pink-500" => true})
              ~H"<div class={cn(@tones)} />"
            end
            """
          ] do
        assert templated(dir, body) == [], body
      end
    end

    test "a template's merge call reads a map's keys", %{tmp_dir: dir} do
      assert [_] =
               templated(
                 dir,
                 ~S|def a(assigns), do: ~H"<div class={cn(%{\"bg-pink-500\" => @on})} />"|
               )

      assert [_] =
               templated(dir, ~S"""
               def a(assigns), do: ~H"<div class={cn(tones())} />"

               defp tones, do: %{"bg-pink-500" => true}
               """)
    end

    test "class map keys are in the default scan, each once", %{tmp_dir: dir} do
      assert [_] = scanned(dir, ~S|cn(["p-1", %{"bg-pink-500" => on}])|, no_raw_colors: :error)
      assert [_] = scanned(dir, ~S|cn(["p-1", %{"bg-pink-500" => on}])|)
    end
  end

  describe "scan_all_strings in template expressions" do
    @scan [no_raw_colors: {:error, scan_all_strings: true}]

    # What each template reports, as {line, column} in the template and the text there.
    defp in_template(dir, template, rules \\ @scan) do
      files = %{
        "lib/app_web/page.ex" => """
        defmodule AppWeb.Page do
          use Phoenix.Component
          embed_templates "page/*"
        end
        """,
        "lib/app_web/page/show.html.heex" => template <> "\n"
      }

      lines = String.split(template, "\n")

      for finding <- lint(dir, files, rules: rules) do
        assert Path.basename(finding.file) == "show.html.heex"

        text =
          lines
          |> Enum.at(finding.line - 1)
          |> String.slice(finding.column - 1, String.length("bg-pink-500"))

        {finding.line, finding.column, text}
      end
    end

    defp in_sigil(dir, template, rules) do
      indented = template |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))

      module = """
      defmodule AppWeb.Page do
        use Phoenix.Component

        def page(assigns) do
          ~H\"\"\"
      #{indented}
          \"\"\"
        end
      end
      """

      lines = String.split(module, "\n")

      for finding <- lint(dir, %{"lib/app_web/page.ex" => module}, rules: rules) do
        lines
        |> Enum.at(finding.line - 1)
        |> String.slice(finding.column - 1, String.length("bg-pink-500"))
      end
    end

    @read [
      {~S|<div title={"bg-pink-500"} />|, {1, 14}},
      {~S|<div data-class={"bg-pink-500"} />|, {1, 19}},
      {~S|<div title={if @a, do: "bg-pink-500", else: "x"} />|, {1, 25}},
      {~S|<div title={%{"fill-color" => "bg-pink-500"}} />|, {1, 32}},
      {~S|<div title={"x #{"bg-pink-500"}"} />|, {1, 19}},
      {~S|<div {%{title: "bg-pink-500"}} />|, {1, 17}},
      {~S|<div :if={@a == "bg-pink-500"} />|, {1, 18}},
      {~S|<div :for={a <- ["bg-pink-500"]}>{a}</div>|, {1, 19}},
      {~S|<div class={@a == "bg-pink-500" && "p-1"} />|, {1, 20}},
      {~S|<div>{"bg-pink-500"}</div>|, {1, 8}},
      {~S|<div><%= "bg-pink-500" %></div>|, {1, 11}},
      {~S|<div><% a = "bg-pink-500" %></div>|, {1, 14}},
      {~S|<%= if @a == "bg-pink-500" do %><b>x</b><% end %>|, {1, 15}},
      {~s|<%= case @a do %>\n<% "bg-pink-500" -> %><b>x</b>\n<% end %>|, {2, 5}},
      {~s|<div title={\n  "bg-pink-500"\n} />|, {2, 4}},
      {~s|<div>{\n  "bg-pink-500"\n}</div>|, {2, 4}},
      {~s|<div><%=\n  "bg-pink-500"\n%></div>|, {2, 4}},
      {~s|<p>x</p>\n<p>{"bg-pink-500"}</p>|, {2, 6}}
    ]

    test "reads every literal, where it is written", %{tmp_dir: dir} do
      for {template, {line, column}} <- @read do
        assert in_template(dir, template) == [{line, column, "bg-pink-500"}], template
      end
    end

    test "reads them in a sigil at the same places", %{tmp_dir: dir} do
      for {template, _position} <- @read do
        assert in_sigil(dir, template, @scan) == ["bg-pink-500"], template
      end
    end

    test "reads nothing of them without the option", %{tmp_dir: dir} do
      for {template, _position} <- @read, not String.contains?(template, "class=") do
        assert in_template(dir, template, no_raw_colors: :error) == [], template
      end
    end

    test "reports what a class site also reads once", %{tmp_dir: dir} do
      for template <- [
            ~S|<div class={"bg-pink-500"} />|,
            ~S|<div class={if @a, do: "bg-pink-500"} />|,
            ~S|<div class={["p-1", "bg-pink-500"]} />|,
            ~S|<div class="bg-pink-500" />|
          ] do
        assert [{1, _column, "bg-pink-500"}] = in_template(dir, template), template
      end
    end

    test "text and comments are not literals", %{tmp_dir: dir} do
      for template <- [
            ~S|<div>bg-pink-500</div>|,
            ~S|<%!-- bg-pink-500 --%><div />|,
            ~S|<div phx-no-curly-interpolation>{"bg-pink-500"}</div>|,
            ~S|<%= if @a do %><b>x</b><% else %><b>y</b><% end %>|
          ] do
        assert in_template(dir, template) == [], template
      end
    end

    test "a plain map key still names a field", %{tmp_dir: dir} do
      assert in_template(dir, ~S|<div title={%{"bg-pink-500" => 1}} />|) == []
      assert in_template(dir, ~S|<.a :let={%{"bg-pink-500" => a}}>{a}</.a>|) == []
    end

    test "no_arbitrary_values reads them too", %{tmp_dir: dir} do
      rules = [no_arbitrary_values: {:error, scan_all_strings: true}]

      assert [{1, 14, "p-[13px]" <> _}] = in_template(dir, ~S|<div title={"p-[13px]"} />|, rules)
    end

    test "a string with no hyphen is left to the class sites", %{tmp_dir: dir} do
      rules = [no_arbitrary_values: {:error, scan_all_strings: true}]

      for template <- [
            ~S|<div title="[padding:13px]" />|,
            ~S|<div title={"[padding:13px]"} />|,
            ~S|<div>{"[padding:13px]"}</div>|
          ] do
        assert in_template(dir, template, rules) == [], template
      end

      module = ~S|defmodule AppWeb.Text do def text, do: "[padding:13px]" end|
      assert lint(dir, %{"lib/app_web/text.ex" => module}, rules: rules) == []

      assert [_] = in_template(dir, ~S|<div class="[padding:13px]" />|, rules)
      assert [_] = in_template(dir, ~S|<div class={"[padding:13px]"} />|, rules)
    end

    @contract [
      no_raw_colors:
        {:error, scan_all_strings: true, contracts: [[pattern: "^button$", allow: ["bg-pink-*"]]]}
    ]

    test "a component's contract keeps what its class site reads", %{tmp_dir: dir} do
      for template <- [
            ~S|<.button class="bg-pink-500">x</.button>|,
            ~S|<.button class={"bg-pink-500"}>x</.button>|,
            ~S|<.button class={if @a, do: "bg-pink-500"}>x</.button>|,
            ~S|<.button class={cn("bg-pink-500")}>x</.button>|,
            ~S|<.button class={"bg-pink-500 #{@a}"}>x</.button>|,
            ~S|<.button class={"bg-pink-500 " <> @a}>x</.button>|,
            ~S|<.button class={@a <> " bg-pink-500"}>x</.button>|,
            ~S|<.button class={"p-1 #{"bg-pink-500"}"}>x</.button>|
          ] do
        files = %{"lib/app_web/live/page_live.ex" => live(template)}
        assert lint(dir, files, rules: @contract) == [], template
      end
    end

    test "but not the other literals on that component", %{tmp_dir: dir} do
      for template <- [
            ~S|<.button title="bg-pink-500">x</.button>|,
            ~S|<.button title={"bg-pink-500"}>x</.button>|,
            ~S|<.button class={@a == "bg-pink-500" && "p-1"}>x</.button>|
          ] do
        files = %{"lib/app_web/live/page_live.ex" => live(template)}
        assert [_] = lint(dir, files, rules: @contract), template
      end
    end

    test "a string the code binds stays the code's", %{tmp_dir: dir} do
      module = """
      defmodule AppWeb.PageLive do
        use AppWeb, :live_view

        def render(assigns) do
          tone = "bg-pink-500"
          ~H"<.button class={tone}>x</.button>"
        end
      end
      """

      assert [finding] = lint(dir, %{"lib/app_web/live/page_live.ex" => module}, rules: @contract)
      assert finding.line == 5
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

  describe "SVG attributes in braces" do
    test "report a literal, as a quoted value does", %{tmp_dir: dir} do
      assert [finding] = colors(dir, ~S|<svg fill={"#ec4899"} />|)
      assert finding.message =~ ~s|fill="#ec4899" hardcodes a color|

      assert [finding] = colors(dir, ~S|<svg stroke={"red"} />|)
      assert finding.message =~ ~s|stroke="red" hardcodes a color|

      assert [finding] = colors(dir, ~S|<svg><path stop-color={ "blue" } /></svg>|)
      assert finding.message =~ ~s|stop-color="blue" hardcodes a color|

      assert [finding] = colors(dir, ~S|<svg fill={"\x72ed"} />|)
      assert finding.message =~ ~s|fill="red" hardcodes a color|

      assert [finding] = colors(dir, ~S|<svg fill={"\#f00"} />|)
      assert finding.message =~ ~s|fill="#f00" hardcodes a color|
    end

    test "read no heredoc", %{tmp_dir: dir} do
      path = "lib/app_web/controllers/page_html/show.html.heex"

      page =
        "defmodule AppWeb.PageHTML do\n  use AppWeb, :html\n  embed_templates \"page_html/*\"\nend\n"

      files = %{"lib/app_web/controllers/page_html.ex" => page}
      rules = [no_raw_colors: :error]

      assert [_] = lint(dir, Map.put(files, path, ~S|<svg fill={"red"} />|), rules: rules)

      heredoc = ~s|<svg fill={"""\nred\n"""} />|
      assert lint(dir, Map.put(files, path, heredoc), rules: rules) == []
    end

    test "with no value have nothing to read", %{tmp_dir: dir} do
      for template <- [
            ~S|<svg fill />|,
            ~S|<svg stroke />|,
            ~S|<input color />|,
            ~S|<font color>x</font>|,
            ~S|<svg><path stop-color /></svg>|
          ] do
        assert colors(dir, template) == [], template
      end
    end

    test "report at the literal", %{tmp_dir: dir} do
      assert [quoted] = colors(dir, ~S|<svg fill="#ec4899" />|)
      assert [braced] = colors(dir, ~S|<svg fill={"#ec4899"} />|)
      assert [spaced] = colors(dir, ~S|<svg fill={ "#ec4899" } />|)

      assert {braced.line, braced.column} == {quoted.line, quoted.column + 1}
      assert {spaced.line, spaced.column} == {quoted.line, quoted.column + 2}

      for literal <- [~S|"\x72ed"|, ~S|"\#f00"|] do
        assert [escaped] = colors(dir, "<svg fill={#{literal}} />"), literal
        assert {escaped.line, escaped.column} == {braced.line, braced.column}, literal
      end
    end

    test "read nothing but a literal, and pass what a quoted value passes", %{tmp_dir: dir} do
      for template <- [
            ~S|<svg fill={@color} />|,
            ~S|<svg fill={if @on, do: "red", else: "blue"} />|,
            ~S|<svg fill={"#{@color}"} />|,
            ~S|<svg fill={"red" <> @rest} />|,
            ~S|<svg fill={"currentColor"} />|,
            ~S|<svg fill={"none"} />|,
            ~S|<svg fill={"var(--color-primary)"} />|,
            ~S|<svg fill={"rgb(\xFF)"} />|,
            ~S|<svg fill={"rgb(0 0 0 / \xFF)"} />|,
            ~S|<svg fill={"oklch(\xFF)"} />|,
            ~S|<.icon fill={"red"} />|
          ] do
        assert colors(dir, template) == [], template
      end
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

  # Tailwind declares white and black in every theme, and core components
  # use them, so they pass until deny names them.
  describe "white and black" do
    @mixed ~s(<div class="text-white bg-black/50" />)

    test "pass by default and under an allow that does not name them", %{tmp_dir: dir} do
      assert colors(dir, @mixed) == []
      assert colors(dir, @mixed, allow: ["*-red-*"]) == []
    end

    test "deny reports them, and keeps variants and opacity in the suggestions", %{tmp_dir: dir} do
      [white, black] =
        colors(dir, ~s(<div class="hover:text-white bg-black/50" />),
          deny: ["*-white", "*-black"]
        )

      assert white.message ==
               ~s|"hover:text-white" uses the raw Tailwind palette. Nearest theme tokens: hover:text-background, hover:text-primary-foreground. Use one of those, or declare --color-<name> in assets/css/app.css for a new color.|

      assert Enum.map(white.suggestions, & &1.replacement) ==
               ["hover:text-background", "hover:text-primary-foreground"]

      # No surface token is close to black in this theme.
      assert black.message =~
               ~s("bg-black/50" uses the raw Tailwind palette and no declared theme color is close to it.)

      [faded] = colors(dir, ~s(<div class="text-white/50" />), deny: ["*-white"])

      assert Enum.map(faded.suggestions, & &1.replacement) ==
               ["text-background/50", "text-primary-foreground/50"]
    end

    test "denying white leaves black alone", %{tmp_dir: dir} do
      assert [%{message: message}] = colors(dir, @mixed, deny: ["*-white"])
      assert message =~ ~s("text-white")
    end

    test "a category in deny reaches them", %{tmp_dir: dir} do
      assert [_, _] = colors(dir, @mixed, deny: ["color"])
    end

    test "allow takes back nothing deny names", %{tmp_dir: dir} do
      assert [_] =
               colors(dir, ~s(<div class="text-white" />), allow: ["*-white"], deny: ["text-*"])

      assert colors(dir, ~s(<div class="text-white" />), allow: ["*-white"]) == []
    end

    test "a contract with its own deny lets one component keep them", %{tmp_dir: dir} do
      options = [deny: ["*-white"], contracts: [[pattern: "^button$", deny: []]]]
      assert colors(dir, ~s(<.button class="text-white">Go</.button>), options) == []
      assert [_] = colors(dir, ~s(<.card class="text-white">Go</.card>), options)
    end

    test "a theme declaring them owns them, even under deny", %{tmp_dir: dir} do
      css = theme() <> "\n@theme { --color-white: #fefefe; }\n"
      extra = %{"assets/css/app.css" => css}

      assert colors(dir, ~s(<div class="text-white" />), [deny: ["*-white"]], extra) == []

      assert [_] = colors(dir, ~s(<div class="bg-black" />), [deny: ["*-black"]], extra)
    end

    test "a scoped token of that name passes for its utility only", %{tmp_dir: dir} do
      css = theme() <> "\n@theme { --background-color-white: #fefefe; }\n"
      extra = %{"assets/css/app.css" => css}

      assert colors(dir, ~s(<div class="bg-white" />), [deny: ["*-white"]], extra) == []
      assert [_] = colors(dir, ~s(<div class="text-white" />), [deny: ["*-white"]], extra)
    end

    test "deny reports them without a theme to read", %{tmp_dir: dir} do
      extra = %{"assets/css/app.css" => ""}
      assert colors(dir, @mixed, [], extra) == []

      assert [finding] = colors(dir, ~s(<div class="text-white" />), [deny: ["*-white"]], extra)

      assert finding.message ==
               ~s("text-white" uses the raw Tailwind palette. Use a theme token, or define one for this color.)
    end

    test "the other named colors stay out of reach of deny", %{tmp_dir: dir} do
      template = ~s(<div class="bg-transparent text-current fill-inherit" />)
      assert colors(dir, template, deny: ["*-transparent", "*-current", "*-inherit"]) == []
    end

    test "scan_all_strings follows the same rule", %{tmp_dir: dir} do
      module = """
      defmodule AppWeb.Tones do
        def tone, do: "text-white"
      end
      """

      extra = %{"lib/app_web/tones.ex" => module}
      assert colors(dir, ~s(<div />), [scan_all_strings: true], extra) == []
      assert [_] = colors(dir, ~s(<div />), [scan_all_strings: true, deny: ["*-white"]], extra)
    end
  end

  # A task lints one file, so only a direct call shows what its verdicts are kept under.
  test "a verdict belongs to the theme, not to its stylesheet's path", %{tmp_dir: dir} do
    path = "lib/app_web/live/page_live.ex"
    template = ~s(<div class="bg-brand" />)

    check = fn theme ->
      file = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(file))
      File.mkdir_p!(Path.join(dir, "assets/css"))
      File.write!(file, live(template))
      File.write!(Path.join(dir, "assets/css/app.css"), theme)
      project = Project.load(dir, [file], [])
      {:ok, policy, _warnings} = NoRawColors.prepare([], project)
      collected = Sites.collect(project, project.sources[file], merge_functions: [])

      NoRawColors.check(
        %{
          project: project,
          source: project.sources[file],
          sites: collected.sites,
          elements: collected.elements,
          merge_functions: [],
          note: nil
        },
        policy,
        []
      )
    end

    assert check.(
             ~s(@import "tailwindcss";\n@theme { --color-brand: red; --color-primary: blue; })
           ) == []

    assert [%{message: message}] =
             check.(~s(@import "tailwindcss";\n@theme { --color-primary: blue; }))

    assert message =~ ~s("bg-brand" is not a declared theme color)
  end
end

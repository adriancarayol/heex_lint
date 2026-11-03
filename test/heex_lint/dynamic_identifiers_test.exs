defmodule HeexLint.DynamicIdentifiersTest do
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  alias HeexLint.Collector
  alias HeexLint.Rules.NoInlineStyles

  @moduletag :tmp_dir
  @moduletag timeout: 30_000

  @path "lib/app_web/page.ex"
  @dynamic "Dynamic style object cannot be checked. Build it from CSS custom properties only."
  @color "Inline style sets color. Style through classes; use CSS custom properties for dynamic values."

  # A function binding `body`, then rendering `template`, in a module with `extra`.
  defp page(body, template, extra \\ "") do
    %{
      @path => """
      defmodule AppWeb.Page do
        use AppWeb, :html
      #{extra}
        def page(assigns) do
      #{body}
          ~H\"\"\"
          #{template}
          \"\"\"
        end
      end
      """
    }
  end

  defp findings(dir, files, names) do
    for d <-
          lint(dir, files, rules: [no_inline_styles: {:error, allow_dynamic_identifiers: names}]),
        do: d.message
  end

  defp styled(dir, body, value, names),
    do: findings(dir, page(body, "<div style={#{value}} />"), names)

  describe "upstream's table" do
    test "an allowed name is exempt", %{tmp_dir: dir} do
      assert styled(dir, "", "@floating_styles", ["@floating_styles"]) == []
    end

    test "an unlisted name is still reported", %{tmp_dir: dir} do
      assert styled(dir, "", "@other_styles", ["@floating_styles"]) == [@dynamic]
    end

    test "an allowed name whose value is written out is still checked", %{tmp_dir: dir} do
      body = ~s(floating_styles = "color: red")
      assert styled(dir, body, "floating_styles", ["floating_styles"]) == [@color]
    end

    test "an allowed name a library's call sets is exempt", %{tmp_dir: dir} do
      body = "floating_styles = Floating.compute(assigns.anchor)"
      assert styled(dir, body, "floating_styles", ["floating_styles"]) == []
      assert styled(dir, body, "floating_styles", ["other"]) == [@dynamic]
    end

    test "an allowed name in a list is exempt, and the rest is checked", %{tmp_dir: dir} do
      body = "floating_styles = Floating.compute()"
      value = ~s([floating_styles, "color: red"])
      assert styled(dir, body, value, ["floating_styles"]) == [@color]
    end

    test "an unlisted name in a list is still reported", %{tmp_dir: dir} do
      assert styled(dir, "other = Floating.compute()", "[other]", ["floating_styles"]) == [
               @dynamic
             ]
    end

    test "a dotted name allows that path", %{tmp_dir: dir} do
      assert styled(dir, "styles = Popper.compute()", "styles.popper", ["styles.popper"]) == []
    end

    test "a dotted name is exact", %{tmp_dir: dir} do
      assert styled(dir, "styles = Popper.compute()", "styles.arrow", ["styles.popper"]) ==
               [@dynamic]
    end
  end

  describe "what a name matches" do
    for {value, name} <- [
          {"@floating_styles", "@floating_styles"},
          {"assigns.floating_styles", "assigns.floating_styles"},
          {"assigns[:floating_styles]", "assigns.floating_styles"},
          {"Map.get(assigns, :floating_styles)", "assigns.floating_styles"},
          {"Map.fetch!(assigns, :floating_styles)", "assigns.floating_styles"},
          {"floating_styles", "floating_styles"},
          {"styles.popper", "styles.popper"},
          {"styles[:popper]", "styles.popper"},
          {"Map.get(styles, :popper)", "styles.popper"},
          {"Map.fetch!(styles, :popper)", "styles.popper"},
          {"Keyword.get(styles, :popper)", "styles.popper"},
          {"Keyword.fetch!(styles, :popper)", "styles.popper"},
          {"styles |> Map.get(:popper)", "styles.popper"},
          {"styles.popper.inner", "styles.popper.inner"},
          {"Map.get(styles, :popper).inner", "styles.popper.inner"},
          {"Keyword.fetch!(styles, :popper)[:inner]", "styles.popper.inner"},
          {"styles[:popper][:inner]", "styles.popper.inner"},
          {"@styles.popper", "@styles.popper"},
          {"@styles[:popper]", "@styles.popper"},
          {"assigns.styles.popper", "assigns.styles.popper"},
          {"Floating.styles", "Floating.styles"},
          {"Floating.styles()", "Floating.styles"},
          {"Floating.styles(@anchor)", "Floating.styles"},
          {"@anchor |> Floating.styles()", "Floating.styles"},
          {"MyApp.Floating.styles(@anchor)", "MyApp.Floating.styles"}
        ] do
      test "#{value} is #{name}", %{tmp_dir: dir} do
        assert styled(dir, "", unquote(value), [unquote(name)]) == []
        assert styled(dir, "", unquote(value), ["unrelated"]) == [@dynamic]
      end
    end

    for {value, name} <- [
          {"@floating_styles", "floating_styles"},
          {"@floating_styles", "assigns.floating_styles"},
          {"assigns.floating_styles", "@floating_styles"},
          {"assigns.floating_styles", "floating_styles"},
          {"floating_styles", "@floating_styles"},
          {"styles.popper", "styles"},
          {"styles.popper", "popper"},
          {"styles.popper", "@styles.popper"},
          {"styles.popper.inner", "styles.popper"},
          {"styles", "styles.popper"},
          {~s(styles["popper"]), "styles.popper"},
          {"styles[key]", "styles"},
          {"styles[nil]", "styles.nil"},
          {"styles[true]", "styles.true"},
          {"Enum.at(styles, :popper).inner", "styles.popper.inner"},
          {"Floating.styles", "styles"},
          {"Floating.styles()", "MyApp.Floating.styles"},
          {"MyApp.Floating.styles()", "Floating.styles"},
          {"Floating.styles(@anchor).popper", "Floating.styles"},
          {"Floating.styles.popper", "Floating.styles"},
          {"floating_styles()", "floating_styles"},
          {"floating_styles(@anchor)", "floating_styles"},
          {"Enum.join(@styles)", "Enum.join"}
        ] do
      test "#{value} is not #{name}", %{tmp_dir: dir} do
        assert styled(dir, "", unquote(value), [unquote(name)]) == [@dynamic]
      end
    end

    test "a variable a component's head binds goes by its own name", %{tmp_dir: dir} do
      files = %{
        @path => """
        defmodule AppWeb.Page do
          use AppWeb, :html

          def page(%{floating_styles: fs} = assigns) do
            ~H"<div style={fs} />"
          end
        end
        """
      }

      assert findings(dir, files, ["fs"]) == []
      assert findings(dir, files, ["@floating_styles"]) == [@dynamic]
    end

    test "a variable a pattern binds goes by its own name", %{tmp_dir: dir} do
      body = "%{floating_styles: fs} = Floating.compute()"

      assert styled(dir, body, "fs", ["fs"]) == []
      assert styled(dir, body, "fs", ["floating_styles"]) == [@dynamic]
    end

    test "a :for variable is that variable", %{tmp_dir: dir} do
      files = page("", ~s|<div :for={styles <- @list} style={styles} />|)

      assert findings(dir, files, ["styles"]) == []
      assert findings(dir, files, ["unrelated"]) == [@dynamic]
    end

    test "a :let variable is that variable", %{tmp_dir: dir} do
      files = page("", ~s|<.card :let={styles}><div style={styles} /></.card>|)

      assert findings(dir, files, ["styles"]) == []
      assert findings(dir, files, ["unrelated"]) == [@dynamic]
    end

    test "@name is a module attribute in code", %{tmp_dir: dir} do
      extra = "@floating_styles Floating.compute()"
      files = page("styles = @floating_styles", "<div style={styles} />", extra)

      assert findings(dir, files, ["@floating_styles"]) == []
      assert findings(dir, files, ["Floating.compute"]) == []
      assert findings(dir, files, ["unrelated"]) == [@dynamic]
    end

    test "an attribute with no value goes by @name in code", %{tmp_dir: dir} do
      files = page("styles = @floating_styles", "<div style={styles} />")

      assert findings(dir, files, ["@floating_styles"]) == []
      assert findings(dir, files, ["unrelated"]) == [@dynamic]
    end
  end

  describe "a name's value" do
    for {kind, value} <- [
          {"a string", ~s("color: red")},
          {"a string with a hole", ~S("color: #{x}")},
          {"a heredoc", ~s("""\n    color: red\n    """)},
          {"a concatenation", ~s("color: " <> x)},
          {"a ~s sigil", ~S|~s(color: red)|},
          {"a list", ~s|["color: red", Floating.compute()]|}
        ] do
      test "written out as #{kind} is still checked", %{tmp_dir: dir} do
        body = "floating_styles = #{unquote(value)}"
        assert @color in styled(dir, body, "floating_styles", ["floating_styles"])
      end
    end

    test "written out as a map stays unreadable", %{tmp_dir: dir} do
      body = ~s(floating_styles = %{color: "red"})
      assert styled(dir, body, "floating_styles", ["floating_styles"]) == [@dynamic]
    end

    test "written out for an assign is still checked", %{tmp_dir: dir} do
      body = ~s|assigns = assign(assigns, :floating_styles, "color: red")|
      assert styled(dir, body, "@floating_styles", ["@floating_styles"]) == [@color]
    end

    test "written out for a module attribute is still checked", %{tmp_dir: dir} do
      files = page("x = @fixed", "<div style={x} />", ~s(@fixed "color: red"))
      assert findings(dir, files, ["@fixed"]) == [@color]
    end

    test "written out in a table entry is still checked", %{tmp_dir: dir} do
      body = ~s|styles = %{popper: "color: red", arrow: Popper.compute()}|

      assert styled(dir, body, "styles.popper", ["styles.popper"]) == [@color]
      assert styled(dir, body, "styles.arrow", ["styles.arrow"]) == []
      assert styled(dir, body, "styles.arrow", ["unrelated"]) == [@dynamic]
    end

    test "a key the table does not have is no written-out value", %{tmp_dir: dir} do
      body = ~s(styles = %{popper: "color: red"})

      assert styled(dir, body, "styles.arrow", ["unrelated"]) == [@color]
      assert styled(dir, body, "styles.arrow", ["styles.arrow"]) == []
    end

    test "set by a library's call in an assign is exempt", %{tmp_dir: dir} do
      body = "assigns = assign(assigns, :floating_styles, Floating.compute(assigns.anchor))"

      assert styled(dir, body, "@floating_styles", ["@floating_styles"]) == []
      assert styled(dir, body, "@floating_styles", ["Floating.compute"]) == []
      assert styled(dir, body, "@floating_styles", ["unrelated"]) == [@dynamic]
    end

    test "a branch exempts what it reads, literals included, as upstream", %{tmp_dir: dir} do
      body = ~s[styles = if(assigns.open, do: "color: red", else: Floating.compute())]

      assert styled(dir, body, "styles", ["styles"]) == []
      assert Enum.sort(styled(dir, body, "styles", ["unrelated"])) == [@dynamic, @color]
    end

    test "an alias exempts what it reads, literals included, as upstream", %{tmp_dir: dir} do
      body = ~s(target = "color: red"\nstyles = target)

      assert styled(dir, body, "styles", ["styles"]) == []
      assert styled(dir, body, "styles", ["target"]) == [@color]
    end

    test "a name bound twice has no one value, so it is exempt", %{tmp_dir: dir} do
      body = ~s|styles = "color: red"\nstyles = Floating.compute(styles)|

      assert styled(dir, body, "styles", ["styles"]) == []
    end

    test "a name along the way exempts what it reads", %{tmp_dir: dir} do
      body = "inner = Floating.compute()\nouter = inner"

      assert styled(dir, body, "outer", ["inner"]) == []
      assert styled(dir, body, "outer", ["outer"]) == []
      assert styled(dir, body, "outer", ["Floating.compute"]) == []
      assert styled(dir, body, "outer", ["unrelated"]) == [@dynamic]
    end

    test "a name along a written-out value still counts", %{tmp_dir: dir} do
      body = ~s|inner = Floating.compute()\nouter = [inner, "color: red"]|

      assert styled(dir, body, "outer", ["inner"]) == [@color]
      assert Enum.sort(styled(dir, body, "outer", ["outer"])) == [@dynamic, @color]
    end

    test "a function's result is read under the names inside it", %{tmp_dir: dir} do
      extra = "defp styles, do: Floating.compute()"
      files = page("", "<div style={styles()} />", extra)

      assert findings(dir, files, ["Floating.compute"]) == []
      assert findings(dir, files, ["styles"]) == [@dynamic]
    end
  end

  describe "several routes" do
    @shared "x = Floating.compute()\ns = x\nt = x"

    for value <- ["if(assigns.on, do: s, else: t)", "if(assigns.on, do: t, else: s)"] do
      test "a value is reported while one route is not exempt: #{value}", %{tmp_dir: dir} do
        value = unquote(value)

        assert styled(dir, @shared, value, ["s"]) == [@dynamic]
        assert styled(dir, @shared, value, ["t"]) == [@dynamic]
        assert styled(dir, @shared, value, ["s", "t"]) == []
        assert styled(dir, @shared, value, ["x"]) == []
      end
    end

    test "a literal is checked while one route is not exempt", %{tmp_dir: dir} do
      body = ~s[x = if(assigns.on, do: "color: red", else: "margin: 0")\ns = x\nt = x]
      value = "if(assigns.on, do: s, else: t)"

      assert @color in styled(dir, body, value, ["s"])
      assert styled(dir, body, value, ["s", "t"]) == []
    end

    test "each branch and side is its own value", %{tmp_dir: dir} do
      value = ~s[if(assigns.on, do: @floating_styles, else: @other)]
      assert styled(dir, "", value, ["@floating_styles"]) == [@dynamic]
      assert styled(dir, "", value, ["@floating_styles", "@other"]) == []

      assert styled(dir, "", ~s(@floating_styles || "color: red"), ["@floating_styles"]) ==
               [@color]

      assert styled(dir, "", "assigns.on && @floating_styles", ["@floating_styles"]) == []
    end

    test "two names reported at one position each count", %{tmp_dir: dir} do
      files = %{
        "lib/app_web/page.ex" => """
        defmodule AppWeb.Page do
          use AppWeb, :html

          embed_templates "page_html/*"

          defp styles, do: [Floating.compute(), Popper.compute()]
        end
        """,
        "lib/app_web/page_html/index.html.heex" => "<div style={styles()} />\n"
      }

      assert findings(dir, files, ["Floating.compute"]) == [@dynamic]
      assert findings(dir, files, ["Popper.compute"]) == [@dynamic]
      assert findings(dir, files, ["Floating.compute", "Popper.compute"]) == []
    end

    test "names that read each other end", %{tmp_dir: dir} do
      body = "s = t\nt = s"

      assert styled(dir, body, "s", ["unrelated"]) == [@dynamic]
      assert styled(dir, body, "s", ["s"]) == []
      assert styled(dir, body, "s", ["t"]) == []
    end

    test "a written-out value that reads itself goes by its name there", %{tmp_dir: dir} do
      body = ~s(s = [s, "color: red"])

      assert styled(dir, body, "s", ["s"]) == [@color]
      assert Enum.sort(styled(dir, body, "s", ["unrelated"])) == [@dynamic, @color]
    end

    test "a written-out attribute that reads itself goes by its name there", %{tmp_dir: dir} do
      files = page("x = @s", "<div style={x} />", ~s(@s [@s, "color: red"]))

      assert findings(dir, files, ["@s"]) == [@color]
      assert Enum.sort(findings(dir, files, ["unrelated"])) == [@dynamic, @color]
    end

    test "a written-out entry that reads itself goes by its path there", %{tmp_dir: dir} do
      body = ~s(t = %{a: [t.a, "color: red"]})

      assert styled(dir, body, "t.a", ["t.a"]) == [@color]
      assert Enum.sort(styled(dir, body, "t.a", ["unrelated"])) == [@dynamic, @color]
    end

    test "a read past the limit on rereads keeps its name", %{tmp_dir: dir} do
      names = for i <- 0..11, do: "v#{i}"
      reads = Enum.reduce(names, "nil", &"if(assigns.on, do: #{&1}, else: #{&2})")
      body = Enum.map_join(names, "\n", &"#{&1} = #{reads}")
      value = "[v0, v1, v2, v3]"

      assert styled(dir, body, value, names) == []
      assert @dynamic in styled(dir, body, value, ["unrelated"])
    end

    test "a long chain stays linear", %{tmp_dir: dir} do
      links = for i <- 1..3000, do: "v#{i} = v#{i - 1}\n"
      body = "v0 = Floating.compute()\n" <> Enum.join(links)

      assert styled(dir, body, "v3000", ["v1500"]) == []
      assert styled(dir, body, "v3000", ["unrelated"]) == [@dynamic]
    end

    test "a branching chain stays linear", %{tmp_dir: dir} do
      links =
        for i <- 1..60 do
          "a#{i} = v#{i - 1}\nb#{i} = v#{i - 1}\nv#{i} = if(assigns.on, do: a#{i}, else: b#{i})\n"
        end

      body = "v0 = Floating.compute()\n" <> Enum.join(links)

      assert styled(dir, body, "v60", ["a30"]) == [@dynamic]
      assert styled(dir, body, "v60", ["a30", "b30"]) == []
    end
  end

  describe "a hole" do
    test "is looked through for raw colors, whatever it is called", %{tmp_dir: dir} do
      body = ~s(tone = "#ff0000")

      assert [message] = styled(dir, body, ~S("--tone: #{tone}"), ["tone"])
      assert message =~ "--tone hardcodes a color"
    end

    test "is not what a name exempts from a written-out value", %{tmp_dir: dir} do
      body = ~s(tone = "#ff0000"\nstyles = "--tone: \#{tone}")

      assert [message] = styled(dir, body, "styles", ["styles"])
      assert message =~ "--tone hardcodes a color"
    end
  end

  describe "a map or keyword list spread onto an element" do
    for root <- ["%{style: VALUE}", "[style: VALUE]", ~s(%{id: "x", style: VALUE})] do
      test "#{root} takes the same names", %{tmp_dir: dir} do
        root = unquote(root)
        spread = fn value -> "<div {#{String.replace(root, "VALUE", value)}} />" end

        files = page("", spread.("@floating_styles"))
        assert findings(dir, files, ["@floating_styles"]) == []
        assert findings(dir, files, ["unrelated"]) == [@dynamic]

        files = page("styles = Popper.compute()", spread.("styles.popper"))
        assert findings(dir, files, ["styles.popper"]) == []
        assert findings(dir, files, ["styles"]) == [@dynamic]

        files = page("", spread.("Floating.styles(@anchor)"))
        assert findings(dir, files, ["Floating.styles"]) == []

        files = page(~s(s = "color: red"), spread.("s"))
        assert findings(dir, files, ["s"]) == [@color]

        files = page("", spread.(~s([@floating_styles, "color: red"])))
        assert findings(dir, files, ["@floating_styles"]) == [@color]
      end
    end

    test "reports the rest at the same position as before", %{tmp_dir: dir} do
      files = page("", "<div {%{style: @other}} />")

      [d] =
        lint(dir, files,
          rules: [no_inline_styles: {:error, allow_dynamic_identifiers: ["@floating_styles"]}]
        )

      assert {d.line, d.column} == {7, 20}
    end
  end

  describe "a received style" do
    defp panel(attr) do
      %{
        @path => """
        defmodule AppWeb.Page do
          use AppWeb, :html

          attr :style, :string, default: #{attr}

          def panel(assigns) do
            ~H"<div style={@style} />"
          end
        end
        """
      }
    end

    test "has its default checked, whatever the name", %{tmp_dir: dir} do
      assert findings(dir, panel(~s("color: red")), ["@style"]) == [@color]
    end

    test "has an unreadable default reported under the default's name", %{tmp_dir: dir} do
      files = panel("Floating.compute()")

      assert findings(dir, files, ["@style"]) == [@dynamic]
      assert findings(dir, files, ["Floating.compute"]) == []
    end

    test "other props go by their name", %{tmp_dir: dir} do
      files =
        page("", "<div style={@floating_styles} />", "attr :floating_styles, :string")

      assert findings(dir, files, ["@floating_styles"]) == []
      assert findings(dir, files, ["unrelated"]) == [@dynamic]
    end
  end

  describe "other files and elements" do
    test "an embedded template reads the same names", %{tmp_dir: dir} do
      files = %{
        @path => """
        defmodule AppWeb.Page do
          use AppWeb, :html

          embed_templates "page_html/*"
        end
        """,
        "lib/app_web/page_html/index.html.heex" => ~s(<div style={@floating_styles} />\n)
      }

      assert findings(dir, files, ["@floating_styles"]) == []
      assert findings(dir, files, ["unrelated"]) == [@dynamic]
    end

    test "a LiveView's assigns read the same names", %{tmp_dir: dir} do
      files = %{"lib/app_web/live/page_live.ex" => live("<div style={@floating_styles} />")}

      assert findings(dir, files, ["@floating_styles"]) == []
      assert findings(dir, files, ["unrelated"]) == [@dynamic]
    end

    test "applies on components, where the contract's words stay", %{tmp_dir: dir} do
      options = [
        allow_dynamic_identifiers: ["@floating_styles"],
        contracts: [[pattern: "^card$", message: "On {{component}}: use a class."]]
      ]

      files =
        page("", ~s(<.card style={@floating_styles} /><.card style={@other} />))

      assert [%{message: "On .card: use a class."}] =
               lint(dir, files, rules: [no_inline_styles: {:error, options}])
    end

    test "property policies still apply to what is left", %{tmp_dir: dir} do
      options = [allow_dynamic_identifiers: ["@floating_styles"], allow: ["color"]]
      files = page("", ~s(<div style={[@floating_styles, "color: red; margin: 0"]} />))

      assert [%{message: "Inline style sets margin." <> _}] =
               lint(dir, files, rules: [no_inline_styles: {:error, options}])
    end

    test "other rules read the same site unchanged", %{tmp_dir: dir} do
      options = [allow_dynamic_identifiers: ["@tone"]]

      files = page("", ~s(<.button class={@tone}>x</.button><div style={@tone} />))

      assert [%{rule: :require_static_classes}] =
               lint(dir, files,
                 rules: [
                   no_inline_styles: {:error, options},
                   require_static_classes: :error
                 ]
               )
    end
  end

  describe "with the option, what no name reads" do
    test "a plain attribute is still checked", %{tmp_dir: dir} do
      assert findings(dir, page("", ~s(<div style="color: red" />)), ["x"]) == [@color]
    end

    test "a string written in the template is still checked", %{tmp_dir: dir} do
      assert styled(dir, "", ~s("color: red"), ["x"]) == [@color]
    end

    test "<style> elements are still reported", %{tmp_dir: dir} do
      [message] = findings(dir, page("", "<style>.a { color: red; }</style>"), ["x"])
      assert message =~ "A <style> element injects CSS"
    end
  end

  describe "without the option" do
    for options <- [[], [allow_dynamic_identifiers: []]] do
      test "nothing changes with #{inspect(options)}", %{tmp_dir: dir} do
        body = ~s|x = Floating.compute()\ns = x\nt = "color: red"|
        value = ~s|[s, t, @other, Floating.styles(@a)]|
        files = page(body, "<div style={#{value}} />")

        assert [_, _, _, _] =
                 found =
                 lint(dir, files, rules: [no_inline_styles: {:error, unquote(options)}])

        assert Enum.count(found, &(&1.message == @dynamic)) == 3
        assert Enum.count(found, &(&1.message == @color)) == 1
      end
    end
  end

  describe "configuration" do
    for {value, text} <- [
          {"floating_styles", "must be a list of strings"},
          {:floating_styles, "must be a list of strings"},
          {nil, "must be a list of strings"},
          {[:floating_styles], "must be a list of strings"},
          {[1], "must be a list of strings"},
          {["assigns[:floating_styles]"], "is not a name as written"},
          {["Floating.styles()"], "is not a name as written"},
          {["Floating.styles/1"], "is not a name as written"},
          {["Floating"], "is not a name as written"},
          {["Floating.Styles"], "is not a name as written"},
          {["@"], "is not a name as written"},
          {["@@floating_styles"], "is not a name as written"},
          {[""], "is not a name as written"},
          {["floating-styles"], "is not a name as written"},
          {["styles."], "is not a name as written"},
          {[".popper"], "is not a name as written"},
          {["color: red"], "is not a name as written"},
          {["bad\nname"], "is not a name as written"},
          {["floating_styles\n"], "is not a name as written"}
        ] do
      test "#{inspect(value)} is a configuration error", %{tmp_dir: dir} do
        value = unquote(Macro.escape(value))
        files = page("", ~s(<div style="color: red" />))

        assert [%{line: 1, column: 1, message: message} | _] =
                 lint(dir, files,
                   rules: [no_inline_styles: {:error, allow_dynamic_identifiers: value}]
                 )

        assert message =~ "no_inline_styles"
        assert message =~ unquote(text)
      end
    end

    for name <- [
          "floating_styles",
          "floatingStyles",
          "_styles",
          "@floating_styles",
          "assigns.floating_styles",
          "styles.popper",
          "@styles.popper.inner",
          "styles?",
          "styles!",
          "Floating.styles",
          "MyApp.Floating.styles",
          "Floating.styles!",
          "estilós"
        ] do
      test "#{name} is a name", %{tmp_dir: dir} do
        assert styled(dir, "", ~s("--gap: 4px"), [unquote(name)]) == []
      end
    end

    test "a name in a contract does nothing, as upstream has none there", %{tmp_dir: dir} do
      options = [
        contracts: [[pattern: "^card$", allow_dynamic_identifiers: ["@floating_styles"]]]
      ]

      files = page("", "<.card style={@floating_styles} />")

      assert [%{message: @dynamic}] =
               lint(dir, files, rules: [no_inline_styles: {:error, options}])
    end

    test "a file override can set it", %{tmp_dir: dir} do
      config = [
        rules: [no_inline_styles: :error],
        overrides: [
          [
            files: ["**/page.ex"],
            rules: [no_inline_styles: {:error, allow_dynamic_identifiers: ["@floating_styles"]}]
          ]
        ]
      ]

      files =
        Map.put(
          page("", "<div style={@floating_styles} />"),
          "lib/app_web/live/page_live.ex",
          live("<div style={@floating_styles} />")
        )

      assert [%{file: file, message: @dynamic}] = lint(dir, files, config)
      assert String.ends_with?(file, "page_live.ex")
    end

    test "prepare reports the error", %{tmp_dir: _dir} do
      assert {:error, message} = NoInlineStyles.prepare([allow_dynamic_identifiers: "x"], nil)
      assert message =~ "allow_dynamic_identifiers"
    end
  end

  describe "Collector.outside_names/2" do
    test "keeps what could not be parsed, which nothing names" do
      collected = Collector.attribute({:expr, "1 +", {4, 2}}, %{}, mode: :style)

      assert {[], [{4, 2}]} = Collector.outside_names(collected, MapSet.new(["x"]))
    end

    test "with no names returns the value as it is" do
      site = %{strings: [%{value: "a"}], unresolved: [{1, 1}], reads: nil}

      assert Collector.outside_names(site, MapSet.new()) == {[%{value: "a"}], [{1, 1}]}
    end
  end
end

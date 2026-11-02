defmodule HeexLint.VariableChainsTest do
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  @moduletag :tmp_dir
  # A walk that doubles with every link does not fail, it just never returns.
  @moduletag timeout: 30_000

  @rules [no_raw_colors: :error, require_static_classes: :error]
  @path "lib/app_web/page.ex"
  @class ~s(<.button class={@c}>x</.button>)

  # A function binding `body`, then rendering `template`.
  defp page(body, template \\ @class, extra \\ "") do
    %{
      @path => """
      defmodule AppWeb.Page do
        use AppWeb, :html
      #{extra}
        def page(assigns) do
      #{body}
          ~H"#{template}"
        end
      end
      """
    }
  end

  # `depth` variables, each read from the one before it the way `shape` reads A.
  defp chain(shape, depth, first \\ ~s("bg-pink-500")) do
    binds = for i <- 1..depth, do: "v#{i} = #{String.replace(shape, "A", "v#{i - 1}")}\n"
    Enum.join(["v0 = #{first}\n" | binds])
  end

  defp assigned(name), do: "assigns = assign(assigns, :c, #{name})"

  defp within_seconds(fun) do
    {microseconds, result} = :timer.tc(fun)
    assert microseconds < 5_000_000, "took #{div(microseconds, 1000)} ms"
    result
  end

  # What each finding points at: its rule and the source text there.
  defp found(diagnostics, dir) do
    lines = dir |> Path.join(@path) |> File.read!() |> String.split("\n")

    diagnostics
    |> Enum.map(fn d ->
      at = lines |> Enum.at(d.line - 1) |> String.slice((d.column - 1)..-1//1)
      {d.rule, Regex.run(~r/^[@\w-]+/, at) |> List.first()}
    end)
    |> Enum.sort()
  end

  # Where `text` starts in the page, as the first character after `before`.
  defp position(dir, before) do
    lines = dir |> Path.join(@path) |> File.read!() |> String.split("\n")
    index = Enum.find_index(lines, &String.contains?(&1, before))

    [{start, length}] =
      Regex.run(~r/#{Regex.escape(before)}/, Enum.at(lines, index), return: :index)

    {index + 1, start + length + 1}
  end

  defp at(diagnostics) do
    diagnostics |> Enum.map(&{&1.line, &1.column}) |> Enum.sort()
  end

  describe "a chain of variables" do
    test "is followed to the limit of 64 bindings", %{tmp_dir: dir} do
      files = page(chain("A", 63), "<.button class={v63}>x</.button>")
      assert found(lint(dir, files, rules: @rules), dir) == [{:no_raw_colors, "bg-pink-500"}]
    end

    test "is dynamic at the first read past the limit", %{tmp_dir: dir} do
      files = page(chain("A", 64), "<.button class={v64}>x</.button>")
      diagnostics = lint(dir, files, rules: @rules)

      assert [%{rule: :require_static_classes}] = diagnostics
      assert at(diagnostics) == [position(dir, "v1 = ")]
    end

    test "through an assign counts the assign", %{tmp_dir: dir} do
      assert found(
               lint(dir, page(chain("A", 62) <> assigned("v62")), rules: @rules),
               dir
             ) == [{:no_raw_colors, "bg-pink-500"}]

      assert found(
               lint(dir, page(chain("A", 63) <> assigned("v63")), rules: @rules),
               dir
             ) == [{:require_static_classes, "v0"}]
    end

    test "of 70 links is dynamic, not dropped", %{tmp_dir: dir} do
      assert [%{rule: :require_static_classes} = finding] =
               lint(dir, page(chain("A", 70) <> assigned("v70")), rules: @rules)

      assert finding.message ==
               "Dynamically built class on <.button> cannot be checked. Use static class strings."

      assert at([finding]) == [position(dir, "v8 = ")]
    end

    test "of 8 links reports its class on any element", %{tmp_dir: dir} do
      files = page(chain("A", 8) <> assigned("v8"), ~s(<div class={@c}></div>))

      assert found(lint(dir, files, rules: @rules), dir) == [{:no_raw_colors, "bg-pink-500"}]
    end

    for {shape, depth} <- [{"A", 5000}, {"cn(A)", 3000}] do
      test "too long to follow is not a crash: #{shape}", %{tmp_dir: dir} do
        last = "v#{unquote(depth)}"
        files = page(chain(unquote(shape), unquote(depth)) <> assigned(last))

        # no_raw_colors would also read each `cn` call on its own.
        rules = [no_restyle: :error, require_static_classes: :error]

        assert [%{rule: :require_static_classes}] =
                 within_seconds(fn -> lint(dir, files, rules: rules) end)
      end
    end

    test "cut on a long route is still read on a short one", %{tmp_dir: dir} do
      us = for i <- 1..10, do: "u#{i} = u#{i - 1}\n"
      ws = for i <- 1..60, do: "w#{i} = w#{i - 1}\n"

      body =
        ~s(u0 = "bg-pink-500"\n) <>
          Enum.join(us) <>
          "w0 = u10\n" <> Enum.join(ws) <> assigned("if(assigns.on, do: w60, else: u10)")

      assert found(lint(dir, page(body), rules: @rules), dir) == [
               {:no_raw_colors, "bg-pink-500"},
               {:require_static_classes, "u8"}
             ]
    end

    test "read in full is still cut past the limit", %{tmp_dir: dir} do
      us = for i <- 1..10, do: "u#{i} = u#{i - 1}\n"
      ws = for i <- 1..62, do: "w#{i} = w#{i - 1}\n"

      body =
        ~s(u0 = "bg-pink-500"\n) <>
          Enum.join(us) <>
          "w0 = u10\n" <> Enum.join(ws) <> assigned("if(assigns.on, do: u10, else: w62)")

      assert found(lint(dir, page(body), rules: @rules), dir) == [
               {:no_raw_colors, "bg-pink-500"},
               {:require_static_classes, "u10"}
             ]
    end

    test "cut in a read it skipped is still read on a short route", %{tmp_dir: dir} do
      us = for i <- 1..10, do: "u#{i} = u#{i - 1}\n"
      ws = for i <- 1..58, do: "w#{i} = w#{i - 1}\n"

      body =
        ~s(u0 = "bg-pink-500"\n) <>
          Enum.join(us) <>
          "p1 = u10\np2 = u10\nw0 = [p1, p2]\n" <>
          Enum.join(ws) <> assigned("[w58, p2]")

      assert found(lint(dir, page(body), rules: @rules), dir) == [
               {:no_raw_colors, "bg-pink-500"},
               {:require_static_classes, "u7"}
             ]
    end

    test "read by a merge call in code reports its class", %{tmp_dir: dir} do
      files = %{
        @path => """
        defmodule AppWeb.Page do
          use AppWeb, :html
          import Tails, only: [cn: 1]

          def classes(_on) do
        #{chain("A", 8)}
            cn(v8)
          end
        end
        """
      }

      assert found(lint(dir, files, rules: [no_raw_colors: :error]), dir) ==
               [{:no_raw_colors, "bg-pink-500"}]
    end
  end

  describe "a binding read twice at one site" do
    for shape <- [
          "if(assigns.on, do: A, else: A)",
          "[A, A]",
          "A || A",
          "cn(A, A)",
          ~S("#{A} #{A}")
        ] do
      test "is read once in a chain: #{shape}", %{tmp_dir: dir} do
        files = page(chain(unquote(shape), 40) <> assigned("v40"))

        assert found(within_seconds(fn -> lint(dir, files, rules: @rules) end), dir) ==
                 [{:no_raw_colors, "bg-pink-500"}]
      end
    end

    test "stays linear past the limit, reporting both reads at the end", %{tmp_dir: dir} do
      files = page(chain("if(assigns.on, do: A, else: A)", 70) <> assigned("v70"))

      assert found(within_seconds(fn -> lint(dir, files, rules: @rules) end), dir) ==
               [{:require_static_classes, "v7"}, {:require_static_classes, "v7"}]
    end

    test "stays linear when the branches differ in length", %{tmp_dir: dir} do
      binds = for i <- 2..40, do: "v#{i} = if(assigns.on, do: v#{i - 1}, else: v#{i - 2})\n"
      short = ~s(v0 = "bg-pink-500"\nv1 = "bg-sky-500"\n) <> Enum.join(binds)

      assert found(lint(dir, page(short <> assigned("v40")), rules: @rules), dir) ==
               [{:no_raw_colors, "bg-pink-500"}, {:no_raw_colors, "bg-sky-500"}]

      binds = for i <- 2..200, do: "v#{i} = if(assigns.on, do: v#{i - 1}, else: v#{i - 2})\n"
      long = ~s(v0 = "bg-pink-500"\nv1 = "bg-sky-500"\n) <> Enum.join(binds)

      diagnostics =
        within_seconds(fn -> lint(dir, page(long <> assigned("v200")), rules: @rules) end)

      assert diagnostics != []
      assert Enum.all?(diagnostics, &(&1.rule == :require_static_classes))
    end

    test "is one class, and no dynamic one, through both branches", %{tmp_dir: dir} do
      variable = ~s(a = "bg-pink-500"\n) <> assigned("if(assigns.on, do: a, else: a)")

      assert found(lint(dir, page(variable), rules: @rules), dir) == [
               {:no_raw_colors, "bg-pink-500"}
             ]

      attribute = page(assigned("if(assigns.on, do: @a, else: @a)"), @class, ~s(@a "bg-pink-500"))
      assert found(lint(dir, attribute, rules: @rules), dir) == [{:no_raw_colors, "bg-pink-500"}]

      function =
        page(
          assigned("if(assigns.on, do: f(), else: f())"),
          @class,
          ~s(defp f, do: "bg-pink-500")
        )

      assert found(lint(dir, function, rules: @rules), dir) == [{:no_raw_colors, "bg-pink-500"}]
    end

    test "is one unreadable value through both branches", %{tmp_dir: dir} do
      body = "c = assigns.d\n" <> assigned("if(assigns.on, do: c, else: c)")
      files = page(body, @class <> "")
      assert [%{rule: :require_static_classes}] = lint(dir, files, rules: @rules)
    end

    test "still leaves two literals of one class as two", %{tmp_dir: dir} do
      body = assigned(~s[if(assigns.on, do: "bg-pink-500", else: "bg-pink-500")])

      assert found(lint(dir, page(body), rules: @rules), dir) ==
               [{:no_raw_colors, "bg-pink-500"}, {:no_raw_colors, "bg-pink-500"}]
    end

    test "is linear through attributes and functions", %{tmp_dir: dir} do
      attributes = for i <- 1..40, do: "@a#{i} if(true, do: @a#{i - 1}, else: @a#{i - 1})\n"
      extra = ~s(@a0 "bg-pink-500"\n) <> Enum.join(attributes)

      assert found(
               within_seconds(fn ->
                 lint(dir, page(assigned("@a40"), @class, extra), rules: @rules)
               end),
               dir
             ) == [{:no_raw_colors, "bg-pink-500"}]

      functions =
        for i <- 1..40, do: "defp f#{i}, do: if(true, do: f#{i - 1}(), else: f#{i - 1}())\n"

      extra = ~s(defp f0, do: "bg-pink-500"\n) <> Enum.join(functions)

      assert found(
               within_seconds(fn ->
                 lint(dir, page(assigned("f40()"), @class, extra), rules: @rules)
               end),
               dir
             ) == [{:no_raw_colors, "bg-pink-500"}]
    end

    test "reports a map key once under scan_all_strings", %{tmp_dir: dir} do
      files = %{
        @path => """
        defmodule AppWeb.Page do
          use AppWeb, :html
          import Tails, only: [cn: 1]

          def classes(on) do
        #{chain("if(on, do: A, else: A)", 40, ~s(%{"bg-pink-500" => on}))}
            cn(v40)
          end
        end
        """
      }

      diagnostics =
        within_seconds(fn ->
          lint(dir, files, rules: [no_raw_colors: {:error, scan_all_strings: true}])
        end)

      assert found(diagnostics, dir) == [{:no_raw_colors, "bg-pink-500"}]
    end
  end

  describe "a cycle" do
    test "of a variable and itself is unresolved", %{tmp_dir: dir} do
      assert found(lint(dir, page("a = a\n" <> assigned("a")), rules: @rules), dir) ==
               [{:require_static_classes, "a"}]
    end

    test "of two variables is unresolved where it closes", %{tmp_dir: dir} do
      diagnostics = lint(dir, page("a = b\nb = a\n" <> assigned("a")), rules: @rules)

      assert [%{rule: :require_static_classes}] = diagnostics
      assert at(diagnostics) == [position(dir, "b = ")]
    end

    test "of attributes and functions is unresolved", %{tmp_dir: dir} do
      attributes = page(assigned("@a"), @class, "@a @b\n@b @a")
      assert [%{rule: :require_static_classes}] = lint(dir, attributes, rules: @rules)

      functions = page(assigned("f()"), @class, "defp f, do: g()\ndefp g, do: f()")
      assert [%{rule: :require_static_classes}] = lint(dir, functions, rules: @rules)
    end

    test "entered at two places is unresolved at each closing read", %{tmp_dir: dir} do
      body = "a = b\nb = a\n" <> assigned("if(assigns.on, do: a, else: b)")
      diagnostics = lint(dir, page(body), rules: @rules)

      assert at(diagnostics) |> Enum.sort() ==
               Enum.sort([position(dir, "a = "), position(dir, "b = ")])
    end

    test "keeps what it reads on the way", %{tmp_dir: dir} do
      body = ~s[a = if(assigns.on, do: b, else: "bg-pink-500")\nb = a\n] <> assigned("a")

      assert found(lint(dir, page(body), rules: @rules), dir) ==
               [{:no_raw_colors, "bg-pink-500"}, {:require_static_classes, "a"}]
    end

    test "at the end of a branching chain stays linear", %{tmp_dir: dir} do
      binds = for i <- 1..40, do: "v#{i} = if(assigns.on, do: v#{i - 1}, else: v#{i - 1})\n"
      first = ~s[v0 = if(assigns.on, do: v40, else: "bg-pink-500")\n]
      files = page(first <> Enum.join(binds) <> assigned("v40"))

      assert found(within_seconds(fn -> lint(dir, files, rules: @rules) end), dir) ==
               [{:no_raw_colors, "bg-pink-500"}, {:require_static_classes, "v40"}]
    end

    test "of bindings that all read each other finishes", %{tmp_dir: dir} do
      names = Enum.map_join(1..20, ", ", &"v#{&1}")
      binds = for i <- 1..20, do: "v#{i} = [#{names}]\n"
      files = page(Enum.join(binds) <> ~s(v21 = "bg-pink-500"\n) <> assigned("[v1, v21]"))

      diagnostics = within_seconds(fn -> lint(dir, files, rules: @rules) end)

      assert Enum.any?(diagnostics, &(&1.rule == :require_static_classes))
      assert Enum.count(diagnostics, &(&1.rule == :no_raw_colors)) == 1
    end
  end

  describe "variables of two functions" do
    test "with the same name are no cycle", %{tmp_dir: dir} do
      extra = """
      defp f do
        x = "bg-pink-500"
        x
      end
      """

      assert found(
               lint(dir, page("x = f()\n" <> assigned("x"), @class, extra), rules: @rules),
               dir
             ) ==
               [{:no_raw_colors, "bg-pink-500"}]
    end

    test "with the same name are each read", %{tmp_dir: dir} do
      extra = """
      defp f do
        x = "bg-pink-500"
        x
      end

      defp g do
        x = "bg-sky-500"
        x
      end
      """

      body = assigned("if(assigns.on, do: f(), else: g())")

      assert found(lint(dir, page(body, @class, extra), rules: @rules), dir) ==
               [{:no_raw_colors, "bg-pink-500"}, {:no_raw_colors, "bg-sky-500"}]
    end

    test "on one line are told apart", %{tmp_dir: dir} do
      extra = ~s[defp f, do: (y = g(); y); defp g, do: (y = "bg-pink-500"; y)]

      assert found(lint(dir, page(assigned("f()"), @class, extra), rules: @rules), dir) ==
               [{:no_raw_colors, "bg-pink-500"}]
    end
  end

  describe "a style" do
    @styles [no_inline_styles: :error]

    defp style(body), do: page(body, ~s(<div style={@s}></div>))
    defp styled(value), do: "assigns = assign(assigns, :s, #{value})"
    defp hole(name), do: ~s("--tone: \#{#{name}}")

    test "fills each hole, even with what another hole read", %{tmp_dir: dir} do
      body = ~s(c = "#ff0000"\n) <> styled(~S("--tone: #{c}; --other: #{c}"))

      assert [_, _] = diagnostics = lint(dir, style(body), rules: @styles)
      assert Enum.all?(diagnostics, &(&1.message =~ "hardcodes a color"))
    end

    test "fills a hole with what the style itself read", %{tmp_dir: dir} do
      body = ~s(c = "#ff0000"\n) <> styled(~S([c, "--tone: #{c}"]))

      assert [%{message: message}] = lint(dir, style(body), rules: @styles)
      assert message =~ "--tone hardcodes a color"
    end

    test "follows a branching chain through a hole", %{tmp_dir: dir} do
      body =
        chain("if(assigns.on, do: A, else: A)", 40, ~s("#ff0000")) <>
          styled(~S("--tone: #{v40}; --other: #{v40}"))

      assert [_, _] = within_seconds(fn -> lint(dir, style(body), rules: @styles) end)
    end

    for links <- [63, 64, 70, 200, 5000] do
      test "reads a raw color #{links} links from a hole", %{tmp_dir: dir} do
        body = chain("A", unquote(links), ~s("#ff0000")) <> styled(hole("v#{unquote(links)}"))

        assert [%{message: message}] =
                 within_seconds(fn -> lint(dir, style(body), rules: @styles) end)

        assert message =~ "--tone hardcodes a color"
      end
    end

    test "reads a raw color past the limit from a hole the template writes", %{tmp_dir: dir} do
      files = page(chain("A", 70, ~s("#ff0000")), ~S(<div style={\"--tone: #{v70}\"}></div>))

      assert [%{rule: :no_inline_styles, message: message}] = lint(dir, files, rules: @styles)
      assert message =~ "--tone hardcodes a color"
    end

    test "stays linear in a hole past the limit", %{tmp_dir: dir} do
      body = chain("if(assigns.on, do: A, else: A)", 70, ~s("#ff0000")) <> styled(hole("v70"))

      assert [%{message: message}] =
               within_seconds(fn -> lint(dir, style(body), rules: @styles) end)

      assert message =~ "--tone hardcodes a color"
    end

    test "stays linear in a hole past the limit that ends in a cycle", %{tmp_dir: dir} do
      first = ~s[if(assigns.on, do: v200, else: "#ff0000")]
      body = chain("if(assigns.on, do: A, else: A)", 200, first) <> styled(hole("v200"))

      assert [%{message: message}] =
               within_seconds(fn -> lint(dir, style(body), rules: @styles) end)

      assert message =~ "--tone hardcodes a color"
    end

    test "reads a lookup past the limit from a hole", %{tmp_dir: dir} do
      read = chain("A", 70, ~s(%{a: "#ff0000"})) <> styled(hole("v70[:a]"))
      assert [%{message: message}] = lint(dir, style(read), rules: @styles)
      assert message =~ "--tone hardcodes a color"

      table = ~s(t = %{a: "#ff0000"}\n) <> chain("A", 70, "t[:a]") <> styled(hole("v70"))
      assert [%{message: message}] = lint(dir, style(table), rules: @styles)
      assert message =~ "--tone hardcodes a color"
    end

    test "allows a hole past the limit that holds no raw color", %{tmp_dir: dir} do
      for first <- [~s["var(--tone)"], "unknown()", "assigns.tone"] do
        body = chain("A", 70, first) <> styled(hole("v70"))
        assert [] == lint(dir, style(body), rules: @styles)
      end
    end

    test "does not report a cycle in a hole as dynamic", %{tmp_dir: dir} do
      body = ~s[a = if(assigns.on, do: b, else: "#ff0000")\nb = a\n] <> styled(hole("a"))

      assert [%{message: message}] =
               within_seconds(fn -> lint(dir, style(body), rules: @styles) end)

      assert message =~ "--tone hardcodes a color"
    end

    test "read too far along a chain is dynamic", %{tmp_dir: dir} do
      assert [%{rule: :no_inline_styles} = finding] =
               lint(dir, style(chain("A", 70, ~s("color: red")) <> styled("v70")), rules: @styles)

      assert at([finding]) == [position(dir, "v8 = ")]
      assert finding.message =~ "cannot be checked"
    end

    test "reads a hole in full from a style read near the limit", %{tmp_dir: dir} do
      us = for i <- 1..10, do: "u#{i} = u#{i - 1}\n"
      ws = for i <- 1..60, do: "w#{i} = w#{i - 1}\n"

      body =
        "u0 = \"#ff0000\"\n" <>
          Enum.join(us) <>
          "w0 = #{hole("u10")}\n" <>
          Enum.join(ws) <> styled("w60")

      assert [%{message: message}] = lint(dir, style(body), rules: @styles)
      assert message =~ "--tone hardcodes a color"
    end

    test "a hole stopped on one route does not end the read on another", %{tmp_dir: dir} do
      body =
        ~s[x = if(assigns.on, do: t, else: "#ff0000")\nt = #{hole("x")}\n] <>
          styled("if(assigns.on, do: x, else: t)")

      assert [%{message: message}] = lint(dir, style(body), rules: @styles)
      assert message =~ "--tone hardcodes a color"
    end
  end

  describe "a lookup" do
    test "of a table that names itself is unresolved", %{tmp_dir: dir} do
      assert [%{rule: :require_static_classes}] =
               within_seconds(fn ->
                 lint(dir, page("t = t\n" <> assigned("t[:a]")), rules: @rules)
               end)

      assert [%{rule: :require_static_classes}] =
               within_seconds(fn ->
                 lint(dir, page("t = u\nu = t\n" <> assigned("t[:a]")), rules: @rules)
               end)
    end

    test "of an attribute that names itself is unresolved", %{tmp_dir: dir} do
      assert [%{rule: :require_static_classes}] =
               within_seconds(fn ->
                 lint(dir, page(assigned("@t[:a]"), @class, "@t @t"), rules: @rules)
               end)

      assert [%{rule: :require_static_classes}] =
               within_seconds(fn ->
                 lint(dir, page(assigned("@t[:a]"), @class, "@t @u\n@u @t"), rules: @rules)
               end)
    end

    test "inside its own table is unresolved", %{tmp_dir: dir} do
      assert [%{rule: :require_static_classes}] =
               within_seconds(fn ->
                 lint(dir, page("t = %{a: t[:a]}\n" <> assigned("t[:a]")), rules: @rules)
               end)
    end

    test "is followed through aliases, to the limit", %{tmp_dir: dir} do
      short = chain("A", 8, ~s(%{a: "bg-pink-500"})) <> assigned("v8[:a]")

      assert found(lint(dir, page(short), rules: @rules), dir) == [
               {:no_raw_colors, "bg-pink-500"}
             ]

      long = chain("A", 70, ~s(%{a: "bg-pink-500"})) <> assigned("v70[:a]")
      assert [%{rule: :require_static_classes}] = lint(dir, page(long), rules: @rules)
    end

    test "reads each entry a site asks for", %{tmp_dir: dir} do
      body =
        ~s(t = %{a: "bg-pink-500", b: "bg-sky-500"}\n) <>
          assigned("if(assigns.on, do: t[:a], else: t[:b])")

      assert found(lint(dir, page(body), rules: @rules), dir) ==
               [{:no_raw_colors, "bg-pink-500"}, {:no_raw_colors, "bg-sky-500"}]
    end

    test "is read once in a branching chain", %{tmp_dir: dir} do
      binds =
        for i <- 1..40,
            do: "t#{i} = %{a: if(assigns.on, do: t#{i - 1}[:a], else: t#{i - 1}[:a])}\n"

      body = ~s(t0 = %{a: "bg-pink-500"}\n) <> Enum.join(binds) <> assigned("t40[:a]")

      assert found(within_seconds(fn -> lint(dir, page(body), rules: @rules) end), dir) ==
               [{:no_raw_colors, "bg-pink-500"}]
    end
  end

  describe "a variable a template reads" do
    test "is reported where the function binds it", %{tmp_dir: dir} do
      files = page(~s(v = "bg-pink-500"), "<.button class={v}>x</.button>")
      diagnostics = lint(dir, files, rules: @rules)

      assert found(diagnostics, dir) == [{:no_raw_colors, "bg-pink-500"}]
      assert at(diagnostics) == [position(dir, ~s(v = "))]
    end

    test "is a function's code, where @name is a module attribute", %{tmp_dir: dir} do
      files = page("v = @tone", "<.button class={v}>x</.button>", ~s(@tone "bg-pink-500"))

      assert found(lint(dir, files, rules: @rules), dir) == [{:no_raw_colors, "bg-pink-500"}]
    end

    test "as a table reads the function's code", %{tmp_dir: dir} do
      files = page(~s(t = %{a: "bg-pink-500"}), "<.button class={t[:a]}>x</.button>")

      assert found(lint(dir, files, rules: @rules), dir) == [{:no_raw_colors, "bg-pink-500"}]
    end

    test "gets its fix where the function binds it", %{tmp_dir: dir} do
      files = page(~s(v = "flex p-[12px]"), "<.button class={v}>x</.button>")

      result = run(dir, files, rules: [no_arbitrary_values: :error])

      assert HeexLint.Fixer.apply(result.diagnostics) == 1
      assert File.read!(Path.join(dir, @path)) =~ ~s(v = "flex p-3")
    end
  end
end

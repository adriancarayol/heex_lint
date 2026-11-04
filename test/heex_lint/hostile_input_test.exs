defmodule HeexLint.HostileInputTest do
  # What a project writes decides how long a run takes and whether it ends. Class
  # tokens and theme files are read in one pass, and nothing in them stops a run.
  # Ported from @shadcn/lint's linear-patterns, suggest, package-map-containment and
  # deep-condition tests, with what the port itself got wrong beside them.
  #
  # Not async: these tests time themselves, and on CI's smaller machine, sharing it with
  # the other test files, some that take 2 s here passed the limit, a different one each run.
  use ExUnit.Case, async: false

  import HeexLint.TestProject

  alias HeexLint.Grammar.{Classes, Classifier, Colors, Lengths, Validators}
  alias HeexLint.Project.Source
  alias HeexLint.Rules.{NoArbitraryValues, NoInlineStyles}
  alias HeexLint.{Collector, Element, Suggest, Template, Theme}

  @moduletag :tmp_dir

  # Long enough that a read retrying from every bracket takes tens of seconds, where
  # one pass takes milliseconds.
  @n 200_000
  @limit_ms 8_000

  defp quick(fun) do
    task = Task.async(fun)

    case Task.yield(task, @limit_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> flunk("took more than #{@limit_ms} ms")
    end
  end

  defp repeat(text, times \\ @n), do: String.duplicate(text, times)

  defp page(template), do: %{"lib/app_web/live/page_live.ex" => live(template)}

  defp write(dir, path, contents \\ ".x {}") do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, contents)
    full
  end

  defp load(dir, css), do: Theme.load(write(dir, "app.css", css))

  # macOS reaches the temporary directory through a link.
  defp real(dir) do
    write(dir, "real.css")
    dir |> Theme.resolve_stylesheet("./real.css") |> Path.dirname()
  end

  describe "class tokens of unclosed brackets" do
    test "are not arbitrary values, and cost one pass" do
      refute quick(fn -> Classes.arbitrary_value?(repeat("a-[")) end)
      refute quick(fn -> Classes.arbitrary_value?("[" <> repeat("a:")) end)
      assert quick(fn -> NoArbitraryValues.split_arbitrary(repeat("a-[")) end) == nil
      assert quick(fn -> NoArbitraryValues.split_arbitrary("w-[" <> repeat("a-[")) end) == nil
    end

    for {token, expected} <- [
          {"hover:w-[13px]", true},
          {"-[13px]", true},
          {"a[b:c]", false},
          {"w-[]", true},
          {"a-[b]c-[d]", true},
          {"w-[13px", false},
          {"w-13px]", false},
          {"w]-[13px", false},
          {"[mask-type:luminance]", true},
          {"[:a:b]", true},
          {"[a:b:]", true},
          {"[:a]", false},
          {"[a:]", false},
          {"[a]", false},
          {"[:]", false},
          {"[::]", false},
          {"[]", false},
          {"[", false},
          {"[a:b]c]", false},
          {"[a:b", false},
          {"a:b]", false}
        ] do
      test "#{token} is #{if expected, do: "", else: "not "}an arbitrary value" do
        assert Classes.arbitrary_value?(unquote(token)) == unquote(expected)
      end
    end

    for {token, expected} <- [
          {"md:text-[13px]/5", %{utility: "text", inner: "13px", suffix: "/5"}},
          {"rounded-tl-[10px]", %{utility: "rounded-tl", inner: "10px", suffix: ""}},
          {"!-mt-[2px]", %{utility: "mt", inner: "2px", suffix: ""}},
          {"a-[b]c-[d]", %{utility: "a", inner: "b", suffix: "c-[d]"}},
          {"w-[]", %{utility: "w", inner: "", suffix: ""}},
          {"-[13px]", nil},
          {"--[13px]", nil},
          {"w-[13px", nil},
          {"w-13px", nil},
          {"", nil}
        ] do
      test "split_arbitrary reads #{inspect(token)}" do
        assert NoArbitraryValues.split_arbitrary(unquote(token)) ==
                 unquote(Macro.escape(expected))
      end
    end

    test "are no opacity modifier, and cost one pass" do
      for open <- ["/[", "/("] do
        token = "bg-red-500" <> repeat(open)
        assert quick(fn -> Regex.run(Classes.opacity_modifier(), token) end) == nil
        refute quick(fn -> Classes.palette_class?(token) end)
      end
    end

    test "a bracket or paren in a modifier holds no other" do
      modifier = &Regex.run(Classes.opacity_modifier(), &1)

      assert modifier.("bg-primary/[0.5]") == ["/[0.5]"]
      assert modifier.("bg-primary/(--alpha)") == ["/(--alpha)"]
      assert modifier.("bg-primary/50") == ["/50"]
      assert modifier.("bg-red-500/[calc(1/2)]") == ["/[calc(1/2)]"]
      assert modifier.("bg-red-500/(a(b))") == nil
      assert modifier.("bg-red-500/(a(b)") == nil
      assert modifier.("bg-red-500/[a[b]") == nil

      assert Classes.palette_class?("bg-red-500/[calc(1/2)]")
      refute Classes.palette_class?("bg-red-500/(a(b)")
      refute Classes.palette_class?("bg-red-500/[a[b]")
    end

    for {name, token} <- [
          {"a modifier", "bg-red-500" <> String.duplicate("/[", 200_000)},
          {"a property", "[" <> String.duplicate("a:", 200_000)},
          {"a length function", "text-[" <> String.duplicate("calc(", 200_000) <> "]"},
          {"a length", "text-[" <> String.duplicate("1", 200_000) <> "]"},
          {"a shadow", "shadow-[" <> String.duplicate("1", 200_000) <> "]"}
        ] do
      test "#{name} written that way is linted in one pass", %{tmp_dir: dir} do
        diagnostics =
          quick(fn ->
            lint(dir, page(~s(<.button class="#{unquote(token)}">x</.button>)),
              rules: [no_raw_colors: :error, no_arbitrary_values: :error, no_restyle: :error]
            )
          end)

        assert diagnostics != []
      end
    end

    test "a long class before a glued interpolation is read in one pass", %{tmp_dir: dir} do
      template = ~s(<div class={"#{repeat("a")} b\#{@x}"} />)
      quick(fn -> lint(dir, page(template), rules: [no_raw_colors: :error]) end)
    end
  end

  describe "bytes that are not UTF-8" do
    @latin1 <<"caf", 0xE9>>

    test "in a stylesheet cost it nothing", %{tmp_dir: dir} do
      theme =
        load(dir, """
        /* #{@latin1} */
        @theme { --color-kept: #123456; --font-x: "#{@latin1}"; --font-y: "\#{<<0xFF>>}"; }
        .#{@latin1} { color: red; }
        @utility kept { color: red; }
        """)

      assert MapSet.member?(theme.tokens, "kept")
      assert Map.has_key?(theme.colors, "kept")
      assert [{"kept", ["color"]}] = theme.utility_properties
    end

    test "a stylesheet that holds them does not stop a lint", %{tmp_dir: dir} do
      assert [%{rule: :no_raw_colors}] =
               lint(
                 dir,
                 page(~s(<div class="bg-pink-500" />))
                 |> Map.put(
                   "assets/css/app.css",
                   "@theme { --color-kept: #123456; } /* #{@latin1} */\n"
                 ),
                 rules: [no_raw_colors: :error]
               )
    end

    for {name, path, contents} <- [
          {"an Elixir file", "lib/app_web/bad.ex",
           "defmodule Bad do\n  def x, do: \"caf\xE9\"\nend\n"},
          {"a template", "lib/app_web/bad.html.heex", "<div class=\"caf\xE9\" />\n"}
        ] do
      test "in #{name} is a file that cannot be parsed, and the others are linted", %{
        tmp_dir: dir
      } do
        result =
          run(
            dir,
            page(~s(<div class="bg-pink-500" />))
            |> Map.put(unquote(path), unquote(contents)),
            rules: [no_raw_colors: :error]
          )

        assert [%{rule: :no_raw_colors}] = result.diagnostics
        assert [{file, message}] = result.failures
        assert String.ends_with?(file, unquote(path))
        assert message =~ "not valid UTF-8"
      end
    end
  end

  describe "an unclosed EEx tag" do
    for {name, template, closing, column} <- [
          {"in a class string", ~s(<div class="p-1<%x" />), "%>", 16},
          {"in a class expression", ~s(<div class={"p-1<%x"} />), "%>", 17},
          {"on its own", "<% x = 1", "%>", 1},
          {"of a comment", "<%!-- x", "--%>", 1}
        ] do
      test "#{name} of a .heex file is a file that cannot be parsed, and the others are linted",
           %{tmp_dir: dir} do
        result =
          run(
            dir,
            page(~s(<div class="bg-pink-500" />))
            |> Map.put("lib/app_web/bad.html.heex", unquote(template) <> "\n"),
            rules: [no_raw_colors: :error]
          )

        assert [%{rule: :no_raw_colors}] = result.diagnostics
        assert [{file, message}] = result.failures
        assert String.ends_with?(file, "lib/app_web/bad.html.heex")

        assert message =~
                 ":1:#{unquote(column)}: expected closing '#{unquote(closing)}' for EEx expression"

        refute message =~ "\n"
      end

      # The heredoc's text starts on line 6 of the file, indented by four.
      test "#{name} of a sigil is a file that cannot be parsed, and the others are linted", %{
        tmp_dir: dir
      } do
        result =
          run(
            dir,
            page(~s(<div class="bg-pink-500" />))
            |> Map.put("lib/app_web/live/bad_live.ex", live(unquote(template), "BadLive")),
            rules: [no_raw_colors: :error]
          )

        assert [%{rule: :no_raw_colors}] = result.diagnostics
        assert [{file, message}] = result.failures
        assert String.ends_with?(file, "lib/app_web/live/bad_live.ex")

        assert message =~
                 ":6:#{unquote(column) + 4}: expected closing '#{unquote(closing)}' for EEx expression"
      end
    end

    test "has no elements and no expressions" do
      template = %Template{file: "bad.heex", source: ~s(<div class={"p-1<%x"} />)}

      assert {:error, message} = Element.from_template(template)
      assert message =~ "bad.heex:1:17:"
      assert Template.elements(template) == {:error, message}
      assert Element.expressions(template) == []
    end

    test "is not what <%% writes, or a tag that closes" do
      for source <- [~s(<div class="p-1<%%x" />), ~s(<div class={"p-1"} /><%= @x %>)] do
        assert {:ok, [%{name: "div"}]} =
                 Element.from_template(%Template{file: "ok.heex", source: source})
      end
    end
  end

  describe "a double-quoted string in an expression" do
    test "is read in one pass, however long", %{tmp_dir: dir} do
      for value <- [repeat("a", 20_000), repeat("p-1 ", 5_000), "#{repeat("p-1 ", 5_000)}\#{@x}"] do
        quick(fn ->
          lint(dir, page(~s(<div class={"#{value}"} />)), rules: [no_raw_colors: :error])
        end)
      end
    end

    test "many on one line are read in one pass each", %{tmp_dir: dir} do
      list = Enum.map_join(1..2_000, ",", fn _ -> ~s("p-1") end)

      quick(fn ->
        lint(dir, page(~s(<div class={[#{list}]} />)), rules: [no_raw_colors: :error])
      end)
    end

    # Columns count graphemes, whatever comes before the string on its line.
    for before <- ["é", "日本", "😀"] do
      test "keeps its classes' positions after #{before}", %{tmp_dir: dir} do
        before = unquote(before)
        template = ~s(<div class={["#{before}", "flex p-[12px] é m-[8px]"]} />)
        source = live(template) |> String.split("\n")
        line = Enum.find_index(source, &String.contains?(&1, "flex"))

        column = fn class ->
          {at, _} = :binary.match(Enum.at(source, line), class)
          String.length(binary_part(Enum.at(source, line), 0, at)) + 1
        end

        assert [first, second] =
                 lint(dir, page(template), rules: [no_arbitrary_values: :error])
                 |> Enum.sort_by(& &1.column)

        assert {first.line, first.column} == {line + 1, column.("p-[12px]")}
        assert {second.line, second.column} == {line + 1, column.("m-[8px]")}
        assert [%{fix: %{new: "flex p-3 é m-[8px]"}}] = first.suggestions
      end
    end

    # The value would differ from the source, and a fix writes to the source.
    test "one line of many literals costs its length", %{tmp_dir: dir} do
      literals = Enum.map_join(1..60_000, ", ", &~s("p-#{&1}"))
      code = "defmodule AppWeb.Long do\n  def x, do: [#{literals}]\nend\n"
      template = "<div id={[#{literals}]} />"

      quick(fn ->
        lint(dir, %{"lib/app_web/long.ex" => code},
          rules: [no_raw_colors: {:error, scan_all_strings: true}]
        )
      end)

      quick(fn ->
        lint(dir, page(template), rules: [no_raw_colors: {:error, scan_all_strings: true}])
      end)
    end

    test "with an escape of its own offers no suggestion", %{tmp_dir: dir} do
      assert [%{suggestions: []}] =
               lint(dir, page(~S(<div class={"p-[12px] \\n"} />)),
                 rules: [no_arbitrary_values: :error]
               )
    end

    # A fix writes to its own literal, whatever is around it.
    for template <- [
          ~S(<div class={["\\n", "p-[12px]"]} />),
          ~S(<div class={["p-[12px]", "\\n"]} />)
        ] do
      test "beside another string's escape still offers one: #{template}", %{tmp_dir: dir} do
        assert [%{suggestions: [_]}] =
                 lint(dir, page(unquote(template)), rules: [no_arbitrary_values: :error])
      end
    end

    test "keeps its classes' positions across lines", %{tmp_dir: dir} do
      template = ~s(<div class={"flex\n  p-[12px]\n\n  é m-[8px]"} />)

      assert [%{line: first_line, column: first}, %{line: second_line, column: second}] =
               lint(dir, page(template), rules: [no_arbitrary_values: :error])
               |> Enum.sort_by(& &1.line)

      assert second_line == first_line + 2
      # In a string with a line break the indentation of the rest of the file counts.
      assert second - first == 2
    end

    for {name, value, expected} <- [
          {"an escaped quote stays inside", ~S(p-[12px] \" m-[8px]), ["m-[8px]", "p-[12px]"]},
          {"an escaped backslash does not escape the quote", ~S(p-[12px] \\\\), ["p-[12px]"]},
          {"an escaped line break parts classes", ~S(p-[12px]\nm-[8px]), ["m-[8px]", "p-[12px]"]},
          {"an escaped tab parts classes", ~S(p-[12px]\tm-[8px]), ["m-[8px]", "p-[12px]"]},
          {"a line break parts classes", "p-[12px]\nm-[8px]", ["m-[8px]", "p-[12px]"]},
          {"a lone # is a character", ~S(p-[12px] # m-[8px]), ["m-[8px]", "p-[12px]"]},
          {"an interpolation's nested braces are skipped",
           ~S(p-[12px] #{%{a: 1}[:a] <> "x"} m-[8px]), ["m-[8px]", "p-[12px]"]},
          {"a # glues to its class", ~S(p-[12px]# m-[8px]), ["m-[8px]", "p-[12px]#"]},
          {"an interpolation's braces and quotes are skipped",
           ~S(p-[12px] #{%{a: "}"}.a} m-[8px]), ["m-[8px]", "p-[12px]"]},
          {"an escape in an interpolation's string is skipped", ~S(p-[12px] #{"\"}"} m-[8px]),
           ["m-[8px]", "p-[12px]"]},
          {"an escaped # is no interpolation", ~S(p-[12px] \#{x} m-[8px]),
           ["m-[8px]", "p-[12px]"]}
        ] do
      test "#{name}", %{tmp_dir: dir} do
        module = """
        defmodule AppWeb.Strings do
          use AppWeb, :html

          def page(assigns) do
            classes = "#{unquote(value)}"
            ~H"<div class={classes}>x</div>"
          end
        end
        """

        found =
          lint(dir, %{"lib/app_web/strings.ex" => module}, rules: [no_arbitrary_values: :error])

        classes =
          found
          |> Enum.map(fn d -> d.message |> String.split(~s(")) |> Enum.at(1) end)
          |> Enum.sort()

        assert classes == unquote(expected)
      end
    end
  end

  describe "the validators" do
    test "take one pass over a long arbitrary value" do
      refute quick(fn -> Validators.check("isArbitraryLength", "[#{repeat("calc(")}]") end)
      refute quick(fn -> Validators.check("isArbitraryLength", "[#{repeat("1")}]") end)
      refute quick(fn -> Validators.check("isArbitraryShadow", "[#{repeat("1")}]") end)
      assert quick(fn -> Validators.check("isArbitraryLength", "[calc(#{repeat("1+")}1)]") end)
    end

    for {value, expected} <- [
          {"[calc()]", false},
          {"[calc(1px)]", true},
          {"[calc())]", true},
          {"[min(]", false},
          {"[x_clamp(1)]", false},
          {"[xcalc(1)]", false},
          {"[x-calc(1)]", true},
          {"[12345]", false},
          {"[10vh]", true},
          {"[1px)]", true},
          {"[0]", true},
          {"[00]", false},
          {"[rgb(0,0,0)]", false},
          {"[length:var(--x)]", true}
        ] do
      test "#{value} is #{if expected, do: "", else: "not "}a length" do
        assert Validators.check("isArbitraryLength", unquote(value)) == unquote(expected)
      end
    end

    for {value, expected} <- [
          {"[0_0_1px_red]", true},
          {"[.5px_1.5px_red]", true},
          {"[inset_12px_-0_red]", true},
          {"[1.2.3px_1px]", false},
          {"[12_1px]", false},
          {"[shadow:var(--x)]", true},
          {"[1px]", false}
        ] do
      test "#{value} is #{if expected, do: "", else: "not "}a shadow" do
        assert Validators.check("isArbitraryShadow", unquote(value)) == unquote(expected)
      end
    end

    test "read a run of digits in one pass" do
      assert quick(fn -> Validators.js_number(repeat("1") <> "x") end) == :nan
      assert Validators.js_number("1.") == 1.0
      assert Validators.js_number("1.5e1") == 15.0
      assert Validators.js_number(".5") == 0.5
      assert Validators.js_number("1.2.3") == :nan
      assert Validators.js_number(".") == :nan
    end
  end

  describe "numbers past the float range" do
    for number <- [
          "1e999",
          "-1e999",
          "1E400",
          String.duplicate("1", 400),
          "-" <> String.duplicate("2", 400),
          String.duplicate("3", 400) <> ".5",
          "0x" <> String.duplicate("f", 300),
          "0o" <> String.duplicate("7", 400),
          "0b" <> String.duplicate("1", 1100)
        ] do
      test "#{String.slice(number, 0, 12)} reads as Infinity, like JavaScript's Number()" do
        number = unquote(number)

        assert Validators.js_number(number) == :infinity
        assert Validators.check("isNumber", number)
        refute Validators.check("isInteger", number)
      end
    end

    test "a value that fits still reads" do
      assert Validators.js_number("1e308") == 1.0e308
      assert Validators.js_number("1e-999") == 0.0
      assert Validators.js_number(String.duplicate("0", 400) <> "1") == 1.0
      assert Validators.js_number("0xff") == 255.0

      # Past the VM's largest integer, and not only past the float range.
      for {prefix, digit, length} <- [
            {"0x", "f", 1_048_561},
            {"0o", "7", 1_398_081},
            {"0b", "1", 4_194_241}
          ] do
        assert Validators.js_number(prefix <> String.duplicate(digit, length)) == :infinity
      end

      assert Validators.check("isInteger", "1e300")
    end

    test "a class of one no longer ends the run", %{tmp_dir: dir} do
      for class <- [
            "p-1e999",
            "z-1e999",
            "w-1e999/2",
            "p-" <> repeat("1", 400),
            "z-" <> repeat("1", 400),
            "opacity-" <> repeat("1", 400),
            "w-" <> repeat("1", 400) <> "/2",
            "p-0x" <> repeat("f", 300),
            "rounded-[1e999px]",
            "rounded-[" <> repeat("1", 400) <> "px]",
            "p-[" <> repeat("1", 400) <> "px]",
            "p-[" <> repeat("1", 400) <> ".5px]",
            "text-[" <> repeat("1", 400) <> "px]",
            "text-[1e308rem]",
            "bg-[rgb(1e999,0,0)]",
            "bg-[rgb(1e300,0,0)]",
            "bg-[rgb(" <> repeat("1", 400) <> ",0,0)]",
            "bg-[oklch(" <> repeat("1", 400) <> "_0_0)]",
            "bg-[oklch(1e308_1e308_0)]",
            "bg-[hsl(1e308,0%,0%)]",
            "w-[" <> repeat("1", 308) <> "px]"
          ] do
        assert lint(dir, page(~s(<.button class="#{class}">x</.button>)),
                 rules: [no_raw_colors: :error, no_arbitrary_values: :error, no_restyle: :error]
               ) != []
      end
    end

    test "a class of one still classifies" do
      assert Classifier.group_of("p-1e999") == "p"
      assert Classifier.group_of("p-" <> repeat("1", 400)) == "p"
      assert Classifier.group_of("z-1e999") == nil
    end

    test "a theme of them loads", %{tmp_dir: dir} do
      theme =
        load(dir, """
        @theme {
          --radius-huge: 1e999px;
          --radius-long: #{repeat("1", 400)}px;
          --radius-longer: #{repeat("1", 400)}.5rem;
          --radius-neg: -1e999px;
          --radius-rem: 1e308rem;
          --radius-unitless: 1e999;
          --radius-sum: calc(1e308px + 1e308px);
          --radius-ok: 9px;
          --text-huge: 1e308rem;
          --text-long: #{repeat("1", 400)}px;
          --spacing: 1e999px;
          --color-unreadable: rgb(1e999 0 0);
          --color-far: oklab(1e200 0 0);
          --color-farther: oklch(1e308 1e308 0);
          --color-overflows: rgb(1e300 0 0);
          --color-long: rgb(#{repeat("1", 400)} 0 0);
          --color-long-var: var(--long-rgb);
          --long-rgb: rgb(#{repeat("1", 400)} 0 0);
          --color-near: #111111;
        }
        """)

      radius = Map.new(Theme.scale(theme, :radius))
      assert radius["huge"] == 1.0e307
      assert radius["long"] == 1.0e307
      assert radius["longer"] == 1.0e307
      assert radius["neg"] == -1.0e307
      assert radius["rem"] == 1.0e307
      assert radius["sum"] == 1.0e307
      assert radius["ok"] == 9.0
      refute Map.has_key?(radius, "unitless")

      refute Map.has_key?(theme.colors, "unreadable")
      refute Map.has_key?(theme.colors, "long")
      refute Map.has_key?(theme.colors, "long-var")
      assert Colors.distance(theme.colors["far"], theme.colors["near"]) > 1.0e100
      assert Colors.distance(theme.colors["farther"], theme.colors["near"]) > 1.0e100
      assert Colors.distance(theme.colors["overflows"], theme.colors["near"]) > 1.0e100
    end

    test "a spacing of them loads", %{tmp_dir: dir} do
      assert %Theme{} = load(dir, "@theme { --spacing: #{repeat("1", 400)}px; }")
    end

    test "parse_float has one answer past the range" do
      assert Validators.parse_float("1.5rem") == {1.5, "rem"}
      assert Validators.parse_float("x") == :error
      assert Validators.parse_float("1e999") == :error
      assert Validators.parse_float(repeat("1", 400)) == :error
      assert Validators.parse_float(repeat("1", 400) <> ".5") == :error
    end

    for {name, color} <- [
          {"lightness", "oklab(1e200 0 0)"},
          {"a", "oklab(0 1e200 0)"},
          {"b", "oklab(0 0 1e200)"}
        ] do
      test "a color past it on #{name} can be compared" do
        assert Colors.distance(Colors.parse(unquote(color)), Colors.parse("#111111")) > 1.0e100
      end
    end

    test "steps at either end can be compared" do
      steps = [{"neg", Lengths.px("-1e999px")}, {"huge", Lengths.px("1e999px")}, {"ok", 8.0}]

      assert [%{name: "ok"}, %{name: "neg"}] = Suggest.nearest_steps(0.0, steps)
      assert [%{name: "huge"} | _] = Suggest.nearest_steps(Lengths.px("1e999px"), steps)

      # These fit in a float, and the distance between them does not.
      steps = [{"neg", Lengths.px("-1.7e308px")}, {"huge", Lengths.px("1.7e308px")}]
      assert [%{name: "huge"} | _] = Suggest.nearest_steps(Lengths.px("1.7e308px"), steps)
      assert [%{name: "neg"} | _] = Suggest.nearest_steps(Lengths.px("-1.7e308px"), steps)
    end

    test "a step no scale has is not named for one" do
      long = repeat("9", 308)
      assert NoArbitraryValues.scale_equivalent("w-[#{repeat("9", 400)}px]", 0.25) == nil
      assert NoArbitraryValues.scale_equivalent("w-[#{long}px]", 0.25) == nil
      assert NoArbitraryValues.scale_equivalent("w-[#{long}px]", 1.0) == nil
      assert NoArbitraryValues.scale_equivalent("w-[12px]", 4.0) == "w-3"
    end
  end

  describe "replace_class" do
    test "takes a class too long to be a regex" do
      token = repeat("a", 100_000)

      assert Classes.replace_class("flex #{token} p-1", token, "b") == "flex b p-1"
    end

    test "a long class with a suggestion no longer ends the run", %{tmp_dir: dir} do
      for class <- [
            "bg-[var(--x)]/" <> repeat("a", 100_000),
            repeat("a", 100_000) <> ":p-[13px]",
            repeat("a", 100_000) <> ":bg-[#fff]"
          ] do
        diagnostics =
          lint(dir, page(~s(<div class="#{class}" />)), rules: [no_arbitrary_values: :error])

        assert [%{suggestions: [_ | _]}] = diagnostics
      end
    end

    # Regex.replace read "\\1" followed by a replacement's first digit as group 12.
    test "keeps a replacement that starts with a digit" do
      assert Classes.replace_class("flex 2xl:p-[8px]", "2xl:p-[8px]", "2xl:p-2") == "flex 2xl:p-2"
      assert Classes.replace_class("2xl:p-[8px]", "2xl:p-[8px]", "2xl:p-2") == "2xl:p-2"
    end

    test "a replacement is plain text" do
      assert Classes.replace_class("a b", "a", ~S(\1$&\\)) == ~S(\1$&\\ b)
    end

    for {value, token, expected} <- [
          {"a a", "a", "x a"},
          {"aa a", "a", "aa x"},
          {"a-b a", "a", "a-b x"},
          {"b-a a", "a", "b-a x"},
          {"a", "a", "x"},
          {"", "a", ""},
          {" a ", "a", " x "},
          {"\ta\n", "a", "\tx\n"},
          {"b\fa\vb\ra", "a", "b\fx\vb\ra"},
          {"a\rb a", "a", "x\rb a"},
          {"xa\ra", "a", "xa\rx"},
          {"aaa aa", "aa", "aaa x"},
          {"aa.a a", "a.a", "aa.a a"},
          {"é a", "a", "é x"},
          {"[a] a", "[a]", "x a"},
          {"a", "", "a"}
        ] do
      test "in #{inspect(value)} replaces #{inspect(token)}" do
        assert Classes.replace_class(unquote(value), unquote(token), "x") == unquote(expected)
      end
    end

    test "a value of near matches takes one pass" do
      token = repeat("a", 100_000)
      value = repeat("a", @n)

      assert quick(fn -> Classes.replace_class(value, token, "x") end) == value
      assert quick(fn -> Classes.replace_class(repeat("ab ", @n) <> "x", "x", "y") end) =~ ~r/ y$/
    end
  end

  describe "theme variables that fan out" do
    defp fan_out(k, levels, bottom) do
      for level <- 0..(levels - 1), into: %{"v#{levels}" => bottom} do
        {"v#{level}", "var(--v#{level + 1}) " |> String.duplicate(k) |> String.trim()}
      end
    end

    test "give up rather than build megabytes" do
      for {k, bottom} <- [{10, "1px"}, {16, "1px"}, {40, "1px"}, {1000, " "}] do
        assert quick(fn -> Theme.resolve_variables("var(--v0)", fan_out(k, 6, bottom)) end) == nil
      end
    end

    test "a value that stays small still resolves" do
      assert Theme.resolve_variables("var(--v0)", fan_out(10, 3, "1px")) ==
               List.duplicate("1px", 1000) |> Enum.join(" ")
    end

    # One literal: it spends its length and one more.
    test "spends its length and one more from a shared budget" do
      values = fn size -> %{"a" => repeat("x", size)} end

      assert Theme.resolve_variables("var(--a)", values.(99_999)) == repeat("x", 99_999)
      assert Theme.resolve_variables("var(--a)", values.(100_000)) == nil

      # Spent across two references, and through a level.
      assert Theme.resolve_variables("var(--a)var(--a)", values.(49_999)) == repeat("x", 99_998)
      assert Theme.resolve_variables("var(--a)var(--a)", values.(50_000)) == nil

      deep = fn size -> %{"b" => "var(--a)", "a" => repeat("x", size)} end
      assert Theme.resolve_variables("var(--b)", deep.(49_999)) == repeat("x", 49_999)
      assert Theme.resolve_variables("var(--b)", deep.(50_000)) == nil
    end

    # JavaScript's `.length` of the text Node reads, where a run of bytes it cannot decode
    # is one U+FFFD. Each pair is what upstream's resolveVariables charges it.
    test "spends UTF-16 units, not characters or bytes" do
      for {text, units} <- [
            {<<0x301::utf8>>, 1},
            {<<"e", 0x301::utf8>>, 2},
            {"\r\n", 2},
            {<<0xE9::utf8>>, 1},
            {<<0x20AC::utf8>>, 1},
            {<<0x1F600::utf8>>, 2},
            {<<0x80>>, 1},
            {<<0xE2, 0x82>>, 1},
            {<<0xF0, 0x9F, 0x98>>, 1},
            {<<0xC0, 0x80>>, 2},
            {<<0xED, 0xA0, 0x80>>, 3}
          ] do
        # A letter at each end, so that none of it trims away.
        leaf = fn size ->
          times = div(size - 2, units)
          "x" <> repeat(text, times) <> repeat("y", size - 2 - times * units) <> "x"
        end

        assert Theme.resolve_variables("var(--a)", %{"a" => leaf.(99_999)}) == leaf.(99_999)
        assert Theme.resolve_variables("var(--a)", %{"a" => leaf.(100_000)}) == nil
      end
    end

    test "a value can take three bytes for each unit and still fit" do
      for text <- [<<0x20AC::utf8>>, <<0xF0, 0x9F, 0x98>>] do
        assert Theme.resolve_variables("var(--a)", %{"a" => repeat(text, 99_999)}) ==
                 repeat(text, 99_999)

        assert Theme.resolve_variables("var(--a)", %{"a" => repeat(text, 100_000)}) == nil
      end
    end

    # One character to a count of characters, however many copies are made of its marks.
    test "a letter with thousands of combining marks gives up like any other value" do
      bottom = "a" <> repeat(<<0x301::utf8>>, 20_000)

      assert quick(fn -> Theme.resolve_variables("var(--v0)", fan_out(10, 6, bottom)) end) == nil
    end

    test "a theme of those letters loads, with those values unresolved", %{tmp_dir: dir} do
      levels =
        Enum.map_join(0..5, " ", fn level ->
          "--l#{level}: #{repeat("var(--l#{level + 1}) ", 10)};"
        end)

      theme =
        quick(fn ->
          load(dir, """
          @theme {
            --color-fan: var(--l0);
            --color-ok: #111111;
            --radius-fan: var(--l0);
            --spacing: var(--l0);
          }
          :root { #{levels} --l6: a#{repeat(<<0x301::utf8>>, 20_000)}; }
          """)
        end)

      refute Map.has_key?(theme.colors, "fan")
      assert Map.has_key?(theme.colors, "ok")
      refute Map.has_key?(Map.new(Theme.scale(theme, :radius)), "fan")
      assert theme.spacing == nil
    end

    # Each token pays for it, and past the budget nothing needs to read it.
    test "a value far past the budget costs what names it nothing", %{tmp_dir: dir} do
      tokens = Enum.map_join(1..1000, " ", &"--color-t#{&1}: var(--big);")

      for big <- [
            repeat(<<0x20AC::utf8>>, 333_333),
            "a" <> repeat(<<0x301::utf8>>, 500_000),
            repeat(<<0x80>>, 1_000_000)
          ] do
        theme = quick(fn -> load(dir, "@theme { #{tokens} } :root { --big: #{big}; }") end)

        assert MapSet.member?(theme.tokens, "t1000")
        assert theme.colors == %{}
      end
    end

    # Bytes a reference cuts apart stay apart, as Node decoded the file before reading it:
    # <<0xE2>> and <<0x82, 0xAC>> are three units, not the euro sign they join into.
    test "spends what each piece of a value is, not what the pieces join into" do
      values = fn times ->
        %{"a" => <<0x82, 0xAC>>, "b" => repeat(<<0xE2>> <> "var(--a)", times)}
      end

      assert Theme.resolve_variables("var(--b)", values.(16_666)) ==
               repeat(<<0xE2, 0x82, 0xAC>>, 16_666)

      assert Theme.resolve_variables("var(--b)", values.(16_667)) == nil
    end

    test "a variable named again spends what it spent the first time" do
      values = fn size -> %{"b" => "var(--a)", "a" => repeat("x", size)} end

      # 1 + size to read --a, and 1 + size for the reference to --b, twice.
      assert Theme.resolve_variables("var(--b)var(--b)", values.(24_999)) == repeat("x", 49_998)
      assert Theme.resolve_variables("var(--b)var(--b)", values.(25_000)) == nil

      # What surrounds a reference counts when the value holding it is substituted.
      around = fn size -> %{"b" => "y var(--a) z", "a" => repeat("x", size)} end
      assert byte_size(Theme.resolve_variables("var(--b)", around.(49_997))) == 50_001
      assert Theme.resolve_variables("var(--b)", around.(49_998)) == nil
    end

    test "a fallback belongs to the reference that holds it" do
      values = %{"a" => "1px"}

      assert Theme.resolve_variables("var(--missing, 1px) var(--missing, 2px)", values) ==
               "1px 2px"

      assert Theme.resolve_variables("var(--a, 2px) var(--a, 3px)", values) == "1px 1px"
      assert Theme.resolve_variables("var(--missing, 1px) var(--missing)", values) == nil
    end

    # --shared is read at the seventh level through the chain, where a value with a
    # reference left in it is too deep, and at the first level on its own.
    test "a variable too deep on one route is not on another" do
      values =
        fan_out(1, 5, "var(--shared)") |> Map.merge(%{"shared" => "var(--leaf)", "leaf" => "1px"})

      assert Theme.resolve_variables("var(--shared)", values) == "1px"
      assert Theme.resolve_variables("var(--v0)", values) == nil
      assert Theme.resolve_variables("var(--shared) var(--v0)", values) == nil
      assert Theme.resolve_variables("var(--v0) var(--shared)", values) == nil
    end

    test "a theme's tokens read a variable by their own route, in either order", %{tmp_dir: dir} do
      chain = fn prefix, shared ->
        Enum.map_join(0..5, " ", fn level ->
          next = if level == 5, do: shared, else: "#{prefix}#{level + 1}"
          "--#{prefix}#{level}: var(--#{next});"
        end)
      end

      theme =
        load(dir, """
        @theme {
          --color-a-shallow: var(--first-shared);
          --color-b-deep: var(--first0);
          --color-c-deep: var(--last0);
          --color-d-shallow: var(--last-shared);
          --radius-shallow: var(--size-shared);
          --radius-deep: var(--size0);
          --radius-deep-first: var(--other0);
          --radius-shallow-after: var(--other-shared);
        }
        :root {
          #{chain.("first", "first-shared")}
          #{chain.("last", "last-shared")}
          #{chain.("size", "size-shared")}
          #{chain.("other", "other-shared")}
          --first-shared: var(--leaf);
          --last-shared: var(--leaf);
          --size-shared: var(--size-leaf);
          --other-shared: var(--size-leaf);
          --leaf: #123456;
          --size-leaf: 3px;
        }
        """)

      assert theme.colors |> Map.keys() |> Enum.sort() == ["a-shallow", "d-shallow"]

      radius = Map.new(Theme.scale(theme, :radius))
      assert radius["shallow"] == 3.0
      assert radius["shallow-after"] == 3.0
      refute Map.has_key?(radius, "deep")
      refute Map.has_key?(radius, "deep-first")
    end

    # A reference spends what it yields, 4 units each here, while a read of --pad scans
    # 100 KB. Reading it again at each reference took 3 s per token.
    defp long_fallback(references) do
      """
      --k: 1;
      --pad: var(--k, #{repeat("a", 100_000)});
      --top: #{repeat("var(--pad) ", references)};
      """
    end

    test "a long fallback costs one read, whatever names it and however often", %{tmp_dir: dir} do
      names = fn prefix -> Enum.map_join(1..5000, " ", &"--#{prefix}-t#{&1}: var(--top);") end

      theme =
        quick(fn ->
          load(dir, """
          @theme {
            #{names.("color")}
            #{names.("radius")}
            #{names.("text")}
            --color-ok: #111111;
            --radius-ok: 9px;
          }
          :root { #{long_fallback(20_000)} }
          """)
        end)

      assert MapSet.member?(theme.tokens, "t5000")
      assert Map.keys(theme.colors) == ["ok"]
      refute Map.has_key?(Map.new(Theme.scale(theme, :radius)), "t5000")
      assert Map.new(Theme.scale(theme, :radius))["ok"] == 9.0
    end

    # Each token has the whole budget, and spends 48,000 reading --pad.
    test "a long fallback that fits resolves for every token that names it", %{tmp_dir: dir} do
      values =
        %{"k" => "1px", "pad" => "var(--k, #{repeat("a", 100_000)})"}
        |> Map.put("top", "calc(#{repeat("var(--pad) + ", 6000)}0px)")

      resolved = quick(fn -> Theme.resolve_variables("var(--top)", values) end)
      assert resolved == "calc(#{repeat("1px + ", 6000)}0px)"

      names = Enum.map_join(1..100, " ", &"--radius-t#{&1}: var(--top);")

      theme =
        quick(fn ->
          load(dir, """
          @theme { #{names} --spacing: var(--top); }
          :root {
            --k: 1px;
            --pad: #{values["pad"]};
            --top: #{values["top"]};
          }
          """)
        end)

      radius = Map.new(Theme.scale(theme, :radius))
      assert for(i <- 1..100, do: radius["t#{i}"]) == List.duplicate(6000.0, 100)
      assert theme.spacing == 6000.0
    end

    test "a value with no reference spends nothing" do
      long = repeat("x", 200_000)
      assert Theme.resolve_variables(long, %{}) == long
    end

    test "what surrounds a reference stays, and each reference resolves" do
      values = %{"a" => "1px", "b" => "var(--a) var(--a)", "c" => " 2px "}

      assert Theme.resolve_variables("calc(var(--a) + var(--c))", values) == "calc(1px + 2px)"
      assert Theme.resolve_variables("x var(--b) y", values) == "x 1px 1px y"
      assert Theme.resolve_variables("var(--missing, var(--a))", values) == "1px"
      assert Theme.resolve_variables("var(--missing,)", values) == ""
      assert Theme.resolve_variables("var(--a) var(--missing)", values) == nil
      assert Theme.resolve_variables("var(--missing) var(--a)", values) == nil
      assert Theme.resolve_variables("var(--a", values) == "var(--a"
    end

    test "a chain past six levels stays unresolved" do
      chain = fn levels -> fan_out(1, levels, "1px") end

      assert Theme.resolve_variables("var(--v0)", chain.(6)) == "1px"
      assert Theme.resolve_variables("var(--v0)", chain.(7)) == nil
    end

    test "a theme of them loads, with those values unresolved", %{tmp_dir: dir} do
      levels =
        Enum.map_join(0..5, " ", fn level ->
          "--l#{level}: #{repeat("var(--l#{level + 1}) ", 16)};"
        end)

      theme =
        quick(fn ->
          load(dir, """
          @theme {
            --color-fan: var(--l0);
            --color-ok: #111111;
            --radius-fan: var(--l0);
            --radius-ok: 9px;
            --spacing: var(--l0);
          }
          :root { #{levels} --l6: red; }
          """)
        end)

      refute Map.has_key?(theme.colors, "fan")
      assert Map.has_key?(theme.colors, "ok")
      refute Map.has_key?(Map.new(Theme.scale(theme, :radius)), "fan")
      assert Map.new(Theme.scale(theme, :radius))["ok"] == 9.0
      assert theme.spacing == nil
    end
  end

  describe "an @import with no `;`" do
    @unterminated String.duplicate("@import 'a' ", 421_000)
    @tailwind String.duplicate(~S|@import "tailwindcss" |, 230_000)

    # Ported from upstream. Its 20,000 repeats do not show here: the regex engine
    # looks for the `;` first in a file under 5 MB, so these are past that.
    test "costs one scan" do
      assert quick(fn -> Theme.parse_imports(@unterminated) end) == []
      assert quick(fn -> Theme.parse_tailwind_prefix(@unterminated) end) == nil
      assert quick(fn -> Theme.parse_imports(@tailwind) end) == []
      assert quick(fn -> Theme.parse_tailwind_prefix(@tailwind) end) == nil
    end

    test "a stylesheet of them loads", %{tmp_dir: dir} do
      assert load(dir, @unterminated).missing_imports == []
    end

    test "those that end are still read" do
      css = ~S"""
      @import "tailwindcss" prefix(tw);
      @import url("./a.css") layer(base);
      @import './b;c.css' supports(display: grid);
      """

      assert Theme.parse_imports(css) == ["tailwindcss", "./a.css", "./b;c.css"]
      assert Theme.parse_imports(~S|@import "./a.css" @import "./b.css";|) == ["./a.css"]
      assert Theme.parse_imports(~S|@import "./a.css"; @import "./b.css"|) == ["./a.css"]
      assert Theme.parse_imports(~S|/* @import "./a.css"; */ .x { top: 0; }|) == []
    end
  end

  describe "the code a project keeps" do
    # :persistent_term copies without sharing, so a term kept twice costs twice, and
    # the VM aborts on a project at about 1 GB.
    test "holds a module's code once beside its functions" do
      functions =
        Enum.map_join(1..200, "\n", fn n ->
          "def f#{n}(a), do: {Enum.map(a.items, & &1.id), %{b: \"#{n}\"}, a.other}"
        end)

      source = Source.parse("a.ex", "defmodule A do\n#{functions}\nend\n")

      assert :erts_debug.flat_size(source.modules) < 1.5 * :erts_debug.flat_size(source.ast)
    end

    test "holds a value bound through many names once", %{tmp_dir: dir} do
      names = Enum.map_join(1..300, " = ", &"a#{&1}")
      code = "defmodule A do\n  def f, do: (#{names} = \"p-1\")\nend\n"
      source = Source.parse("a.ex", code)

      assert :erts_debug.flat_size(source.modules) < 3 * :erts_debug.flat_size(source.ast)

      # 3,000 of these asked for over 1 GB, past what the VM has for this, which aborted it.
      names = Enum.map_join(1..3000, " = ", &"a#{&1}")
      code = "defmodule A do\n  def f, do: (#{names} = \"p-1\")\nend\n"
      assert lint(dir, %{"lib/app_web/a.ex" => code}, rules: [no_raw_colors: :error]) == []
    end

    test "tells a clause from one parsed again at the same place" do
      id = fn ->
        %{modules: [%{functions: %{{"f", 0} => [clause]}}]} =
          Source.parse("a.ex", "defmodule A do\n  def f, do: 1\nend\n")

        clause.id
      end

      assert id.() != id.()
    end

    test "still answers for each module of a file" do
      source =
        Source.parse("a.ex", """
        defmodule A do
          @a 1

          defmodule B do
            @b 2
          end
        end

        defmodule C do
          @c 3
        end
        """)

      bodies = Enum.zip(Enum.map(source.modules, & &1.name), Source.module_bodies(source.ast))

      for {name, attribute} <- [{"A", :a}, {"A.B", :b}, {"C", :c}] do
        {^name, body} = List.keyfind!(bodies, name, 0)
        {_, found} = Macro.prewalk(body, false, &{&1, &2 or match?({^attribute, _, _}, &1)})
        assert found, name
      end
    end
  end

  describe "parse_declarations" do
    defp values(css), do: css |> Theme.parse_declarations() |> elem(0)

    test "keeps a value with a long run of spaces inside" do
      assert values(":root { --a: x#{repeat(" ")}y; }")["a"] == "x#{repeat(" ")}y"
    end

    test "trims what follows a value, however long" do
      assert values(":root { --a: x#{repeat(" ")}; }")["a"] == "x"
      assert values(":root { --a:#{repeat(" ")}x; }")["a"] == "x"
    end

    test "a value of only whitespace keeps its one character" do
      assert values(":root { --a:  red  \n ; --b: ; --c:\n ; }") == %{
               "a" => "red",
               "b" => " ",
               "c" => " "
             }
    end

    test "a statement with no value is no declaration" do
      assert values(":root { --a:; --b; c: d; }") == %{}
    end
  end

  describe "a theme of thousands of declarations" do
    @many 40_000

    defp each(template, times \\ @many) do
      Enum.map_join(1..times, &String.replace(template, "#", Integer.to_string(&1)))
    end

    test "of one scale loads in one pass", %{tmp_dir: dir} do
      theme = quick(fn -> load(dir, "@theme {#{each("--radius-r#: 1px;")}}") end)

      scale = Theme.scale(theme, :radius)
      assert length(scale) == @many + length(Theme.default_scales().radius)
      assert List.last(scale) == {"r#{@many}", 1.0}
    end

    test "of another scale adds its names in one pass", %{tmp_dir: dir} do
      many = 2 * @many
      theme = quick(fn -> load(dir, "@theme {#{each("--shadow-s#: 0 0 red;", many)}}") end)

      assert Classifier.group_of("shadow-s#{many}", Theme.grammar(theme)) == "shadow"
    end

    test "resets the names of a scale in declared order", %{tmp_dir: dir} do
      theme =
        load(dir, """
        @theme {
          --shadow-a: 0 0 red;
          --shadow-b: 0 0 red;
          --shadow-a: 1px 0 red;
          --shadow-c: 0 0 red;
          --shadow-b: initial;
          --shadow-b: 0 0 red;
          --shadow-d: 0 0 red;
          --shadow-e: 0 0 red;
          --shadow-d: 1px 0 red;
        }
        """)

      assert HeexLint.Grammar.ThemeScales.of(theme.declarations).extend["shadow"] ==
               ~w(a c b d e)
    end

    test "of utilities loads in one pass", %{tmp_dir: dir} do
      theme = quick(fn -> load(dir, each("@utility u# { color: red; }")) end)

      assert length(theme.utility_properties) == @many
      assert List.last(theme.utility_properties) == {"u#{@many}", ["color"]}
    end

    test "a step replaced keeps its place, one removed and declared again goes last", %{
      tmp_dir: dir
    } do
      theme =
        load(dir, """
        @theme {
          --radius-*: initial;
          --radius-a: 1px;
          --radius-b: 2px;
          --radius-c: 3px;
          --radius-a: 9px;
          --radius-b: initial;
          --radius-b: 4px;
          --radius-unreadable: 1px;
          --radius-unreadable: clamp(1px, 2px, 3px);
        }
        """)

      assert Theme.scale(theme, :radius) == [{"a", 9.0}, {"c", 3.0}, {"b", 4.0}]
    end

    test "a utility declared again takes the new body and keeps its place", %{tmp_dir: dir} do
      theme =
        load(dir, """
        @utility a { color: red; }
        @utility b { display: block; }
        @utility a { margin: 0; }
        @utility c { top: 0; }
        @utility c { left: 0; }
        """)

      assert theme.utility_properties ==
               [{"a", ["margin"]}, {"b", ["display"]}, {"c", ["left"]}]
    end
  end

  describe "@utility bodies left open or nested" do
    test "a file of them takes a few passes", %{tmp_dir: dir} do
      theme = quick(fn -> load(dir, each("@utility u# { b: c;", 40_000)) end)

      assert length(theme.utility_properties) == 40_000
      assert List.first(theme.utility_properties) == {"u1", ["b"]}
      # Past the passes a body that holds another sets nothing a category can be read from.
      assert Enum.at(theme.utility_properties, 39_998) == {"u39999", []}
      # A body with none inside it costs no pass.
      assert List.last(theme.utility_properties) == {"u40000", ["b"]}
    end

    test "those past the passes leave a body with none inside it alone" do
      braces = Enum.map_join(1..40, "\n", &~s|@utility brace-#{&1} { content: "{"; color: red; }|)
      healthy = Enum.map_join(1..200, "\n", &"@utility h#{&1} { color: red; top: 0; }")

      utilities = Theme.parse_utilities(braces <> "\n" <> healthy)

      assert Enum.all?(
               1..200,
               &(List.keyfind(utilities, "h#{&1}", 0) == {"h#{&1}", ["color", "top"]})
             )
    end

    test "nesting of a real size reads every body" do
      assert Theme.parse_utilities("""
             @utility a { color: red; @utility b { display: block; } top: 0; }
             @utility c { left: 0; }
             @utility d { right: 0;
             """) == [
               {"a", ["color", "display", "top"]},
               {"b", ["display"]},
               {"c", ["left"]},
               {"d", ["right"]}
             ]
    end
  end

  describe "style values" do
    test "are split in one pass", %{tmp_dir: dir} do
      template = ~s(<div style="color: #{repeat("#fff ", 40_000)}" />)

      assert [%{rule: :no_inline_styles}] =
               quick(fn -> lint(dir, page(template), rules: [no_inline_styles: :error]) end)
    end

    for value <- ["#fff ", "var(--a) ", "url(a) "] do
      test "of a custom property, #{value}repeated, are read in one pass", %{tmp_dir: dir} do
        style = ~s(--x: #{repeat(unquote(value), div(800_000, byte_size(unquote(value))))})

        quick(fn ->
          lint(dir, page(~s(<div style="#{style}" />)), rules: [no_inline_styles: :error])
        end)
      end
    end

    test "url( is one word in any case, and only at a word's start" do
      assert NoInlineStyles.raw_color?("URL(#fff)") == false
      assert NoInlineStyles.raw_color?("Url(#fff)") == false
      assert NoInlineStyles.raw_color?("xurl(#fff)") == true
      assert NoInlineStyles.raw_color?("url(#fff) #fff") == true
    end

    test "var() holds no color, in any case, up to its first )" do
      assert NoInlineStyles.raw_color?("var(--a, red)") == false
      assert NoInlineStyles.raw_color?("VAR(--a, red) Var(--b, blue)") == false
      assert NoInlineStyles.raw_color?("var(--a) red") == true
      assert NoInlineStyles.raw_color?("var(--a, var(--b)) red") == true
      assert NoInlineStyles.raw_color?("var(--a, red") == true
      assert NoInlineStyles.raw_color?("var(--a) var(--b, red") == true
    end

    test "a value of many declarations reports each", %{tmp_dir: dir} do
      assert [_, _, _] =
               lint(dir, page(~s(<div style="color: red; top: 0;; left: 0;" />)),
                 rules: [no_inline_styles: :error]
               )
    end

    test "a run of dashes is read in one pass", %{tmp_dir: dir} do
      template = ~s(<div style="#{repeat("-", 400_000)}" />)
      quick(fn -> lint(dir, page(template), rules: [no_unknown_variables: :error]) end)
    end

    test "keep their declarations in order" do
      string = %{items: Collector.chars("a: 1; b: 2 ; c: 3", {1, 1}, 0)}

      assert ["a", "b", "c"] =
               string
               |> HeexLint.Rules.NoInlineStyles.__declarations__()
               |> Enum.map(&elem(&1, 0))
    end

    for {style, variable, defined} <- [
          {"--a: 1", "--a", true},
          {"--a  : 1", "--a", true},
          {"a--b: 1", "--b", true},
          {"---a: 1", "---a", true},
          {"--a--b: 1", "--a--b", true},
          {"--a-: 1", "--a-", true},
          {"--a--b: 1", "--b", false},
          {"--a", "--a", false},
          {"--a b: 1", "--a", false},
          {"x: --a", "--a", false},
          {"--a--: 1", "--a--", true},
          {"--a: 1; --b: 2", "--b", true}
        ] do
      test "#{inspect(style)} #{if defined, do: "sets", else: "does not set"} #{variable}", %{
        tmp_dir: dir
      } do
        template = ~s[<div style="#{unquote(style)}" class="bg-(#{unquote(variable)})" />]
        found = lint(dir, page(template), rules: [no_unknown_variables: :error])
        assert found == [] == unquote(defined)
      end
    end

    test "a color function's digits are read in one pass" do
      value = "rgb(var(--x) / #{repeat("1")}x)"

      assert quick(fn -> Colors.without_variable_channel_colors(value) end) == value

      assert Colors.without_variable_channel_colors("rgb(var(--x) / 1.5)") == " "
      assert Colors.without_variable_channel_colors("rgb(var(--x) / 1.)") == " "
      assert Colors.without_variable_channel_colors("rgb(var(--x) / .5e1%)") == " "

      assert Colors.without_variable_channel_colors("rgb(var(--x) / 1.2.3)") ==
               "rgb(var(--x) / 1.2.3)"
    end
  end

  describe "package targets, in the theme read" do
    setup %{tmp_dir: dir} do
      root = real(dir)
      app = Path.join(root, "app")
      secret = write(root, "secret/x.css", "@theme { --color-secret: #123456; }")
      write(root, "app/node_modules/secret/x.css", ".nested {}")
      write(root, "app/package.json", ~s({"name":"app"}))
      %{root: root, app: app, secret: secret}
    end

    defp manifest(root, dir, json), do: write(root, Path.join(dir, "package.json"), json)

    test "one that walks out of the package falls back to the next", ctx do
      fallback = write(ctx.root, "app/node_modules/pkg/dist/x.css")

      manifest(ctx.root, "app/node_modules/pkg", ~s({"exports":{
        "./x.css": ["../../../secret/x.css", "./dist/x.css"],
        "./y.css": {"style": "../../../secret/x.css", "default": "./dist/x.css"}
      }}))

      assert Theme.resolve_stylesheet(ctx.app, "pkg/x.css") == fallback
      assert Theme.resolve_stylesheet(ctx.app, "pkg/y.css") == fallback
    end

    test "one that walks out alone resolves nothing", ctx do
      manifest(
        ctx.root,
        "app/node_modules/pkg",
        ~s({"exports":{"./x.css":"../../../secret/x.css","./abs.css":"#{ctx.secret}","./up.css":"../../outside.css"}})
      )

      write(ctx.root, "app/outside.css")

      for spec <- ["pkg/x.css", "pkg/abs.css", "pkg/up.css"] do
        assert Theme.resolve_stylesheet(ctx.app, spec) == nil
      end
    end

    test "a node_modules segment or an encoded separator is refused", ctx do
      write(ctx.root, "app/node_modules/pkg/node_modules/dep/x.css")
      write(ctx.root, "app/node_modules/pkg/a%2fb.css")
      write(ctx.root, "app/node_modules/pkg/a%5cb.css")

      manifest(ctx.root, "app/node_modules/pkg", ~s({"exports":{
        "./dep.css": "./node_modules/dep/x.css",
        "./enc.css": "./a%2fb.css",
        "./enc2.css": "./a%5Cb.css",
        "./up.css": "./%2e%2e/x.css"
      }}))

      for spec <- ["pkg/dep.css", "pkg/enc.css", "pkg/enc2.css", "pkg/up.css"] do
        assert Theme.resolve_stylesheet(ctx.app, spec) == nil
      end
    end

    test "a wildcard capture cannot walk out", ctx do
      manifest(ctx.root, "app/node_modules/pkg", ~s({"exports":{"./*":"./dist/*"}}))

      assert Theme.resolve_stylesheet(ctx.app, "pkg/../../../secret/x.css") == nil
      assert Theme.resolve_stylesheet(ctx.app, "pkg/a/%2e%2e/%2e%2e/x.css") == nil
      assert Theme.resolve_stylesheet(ctx.app, "pkg/a%2f..%2f..%2fx.css") == nil
    end

    test "a package's own files stay inside it", ctx do
      write(ctx.root, "app/node_modules/pkg/index.css")

      assert Theme.resolve_stylesheet(ctx.app, "pkg/../../../secret/x.css") == nil
      assert Theme.resolve_stylesheet(ctx.app, "pkg/../secret/x.css") == nil
    end

    test "a ./ target inside the package still resolves", ctx do
      file = write(ctx.root, "app/node_modules/pkg/dist/x.css")
      themed = write(ctx.root, "app/node_modules/pkg/dist/themes/dark.css")

      manifest(
        ctx.root,
        "app/node_modules/pkg",
        ~s({"exports":{"./x.css":"./dist/x.css","./themes/*":"./dist/themes/*"}})
      )

      assert Theme.resolve_stylesheet(ctx.app, "pkg/x.css") == file
      assert Theme.resolve_stylesheet(ctx.app, "pkg/themes/dark.css") == themed
    end

    test "style and main stay inside the package", ctx do
      index = write(ctx.root, "app/node_modules/pkg/index.css")

      manifest(
        ctx.root,
        "app/node_modules/pkg",
        ~s({"style":"../../../secret/x.css","main":"../../../secret/x.css"})
      )

      assert Theme.resolve_stylesheet(ctx.app, "pkg") == index
      File.rm!(index)
      assert Theme.resolve_stylesheet(ctx.app, "pkg") == nil
    end

    test "an imports target stays inside the project", ctx do
      fallback = write(ctx.root, "app/src/x.css")
      write(ctx.root, "app/src/styles/a.css")

      manifest(ctx.root, "app", ~s({"name":"app","imports":{
        "#x": ["../secret/x.css", "./src/x.css"],
        "#abs": "#{ctx.secret}",
        "#up": "../secret/x.css",
        "#styles/*": "./src/styles/*"
      }}))

      assert Theme.resolve_stylesheet(ctx.app, "#x") == fallback
      assert Theme.resolve_stylesheet(ctx.app, "#abs") == nil
      assert Theme.resolve_stylesheet(ctx.app, "#up") == nil
      assert Theme.resolve_stylesheet(ctx.app, "#styles/a.css") =~ "app/src/styles/a.css"
      assert Theme.resolve_stylesheet(ctx.app, "#styles/../../../secret/x.css") == nil
    end

    test "a bare imports target resolves as a package, not a path", ctx do
      file = write(ctx.root, "app/node_modules/theme/dist/x.css")
      manifest(ctx.root, "app/node_modules/theme", ~s({"exports":{"./x.css":"./dist/x.css"}}))
      write(ctx.root, "app/secret/x.css")

      manifest(ctx.root, "app", ~s({"name":"app","imports":{
        "#theme": "theme/x.css",
        "#secret": "secret/x.css",
        "#deep/*": "theme/*"
      }}))

      assert Theme.resolve_stylesheet(ctx.app, "#theme") == file
      assert Theme.resolve_stylesheet(ctx.app, "#secret") =~ "app/node_modules/secret/x.css"
      assert Theme.resolve_stylesheet(ctx.app, "#deep/../../../secret/x.css") == nil
    end

    # The package's own link is followed, as upstream and Node do: containment reads
    # the path as written.
    test "a link the package holds is followed", ctx do
      write(ctx.root, "app/node_modules/pkg/index.css")
      link = Path.join(ctx.root, "app/node_modules/pkg/link.css")
      File.ln_s!(ctx.secret, link)
      manifest(ctx.root, "app/node_modules/pkg", ~s({"exports":{"./l.css":"./link.css"}}))

      assert Theme.resolve_stylesheet(ctx.app, "pkg/l.css") == ctx.secret
    end

    test "a package reached through a link is read where it lives", ctx do
      file = write(ctx.root, "workspace/linked/dist/x.css")
      write(ctx.root, "workspace/outside.css")

      manifest(
        ctx.root,
        "workspace/linked",
        ~s({"name":"linked","exports":{"./x.css":"./dist/x.css","./up.css":"../outside.css"}})
      )

      File.mkdir_p!(Path.join(ctx.root, "app/node_modules"))

      File.ln_s!(
        Path.join(ctx.root, "workspace/linked"),
        Path.join(ctx.root, "app/node_modules/linked")
      )

      assert Theme.resolve_stylesheet(ctx.app, "linked/x.css") == file
      assert Theme.resolve_stylesheet(ctx.app, "linked/up.css") == nil
    end

    test "an escaping target adds no tokens to a theme", ctx do
      manifest(
        ctx.root,
        "app/node_modules/pkg",
        ~s({"exports":{"./x.css":"../../../secret/x.css"}})
      )

      entry = write(ctx.root, "app/app.css", ~s(@import "pkg/x.css";\n))

      theme = Theme.load(entry, ["^pkg"])

      assert MapSet.size(theme.tokens) == 0
      assert theme.missing_imports == ["pkg/x.css"]
    end
  end

  describe "UNC paths, in the theme read" do
    setup %{tmp_dir: dir} do
      root = real(dir)
      %{root: root, app: Path.join(root, "app"), secret: write(root, "secret/x.css")}
    end

    test "outside the project are never read", ctx do
      write(ctx.root, "app/src/x.css")
      write(ctx.root, "app/package.json", ~s({"name":"app"}))

      for slashes <- ["//", "/\\", "\\\\", "\\/"] do
        assert Theme.resolve_stylesheet(ctx.app, slashes <> String.trim_leading(ctx.secret, "/")) ==
                 nil
      end

      assert Theme.resolve_stylesheet(ctx.app, "//host/share/x.css") == nil
      assert Theme.resolve_stylesheet(ctx.app, "\\\\host\\share\\x.css") == nil
    end

    for {file, within, stray} <- [
          {"//host/share/x.css", ["/home/app"], true},
          {"\\\\host\\share\\x.css", ["/home/app"], true},
          {"/\\host/share", ["/home/app"], true},
          {"\\/host/share", ["/home/app"], true},
          {"/home/app/x.css", ["/home/app"], false},
          {"/home/x.css", ["/home/app"], false},
          {"C:\\x.css", ["/home/app"], false},
          {"//host/share/app/x.css", ["//host/share/app"], false},
          {"//other/share/x.css", ["//host/share/app"], true},
          {"//host/share/app/x.css", ["/home/app", "//host/share/app"], false}
        ] do
      test "#{inspect(file)} from #{inspect(within)} is #{if stray, do: "", else: "not "}stray" do
        assert Theme.stray_unc?(unquote(file), unquote(within)) == unquote(stray)
      end
    end

    test "a path written with one slash still reads", ctx do
      assert Theme.resolve_stylesheet(ctx.app, ctx.secret) == ctx.secret
    end

    test "inside the project still read", ctx do
      file = write(ctx.root, "app/src/x.css")
      write(ctx.root, "app/package.json", ~s({"name":"app"}))

      assert Theme.resolve_stylesheet(ctx.app, "/" <> file) == file
    end

    test "as an exports target are skipped", ctx do
      fallback = write(ctx.root, "app/node_modules/pkg/dist/x.css")

      write(ctx.root, "app/node_modules/pkg/package.json", ~S({"exports":{"./x.css":[
        "//host/share/x.css",
        "\\\\host\\share\\x.css",
        "./dist/x.css"
      ]}}))

      assert Theme.resolve_stylesheet(ctx.app, "pkg/x.css") == fallback
    end
  end

  describe "conditions nested deeper than any manifest needs" do
    defp nested(depth, key, target),
      do: repeat(~s({"#{key}":), depth) <> inspect(target) <> repeat("}", depth)

    setup %{tmp_dir: dir} do
      root = real(dir)
      write(root, "node_modules/deep/dist/theme.css")
      write(root, "node_modules/deep/index.css")
      %{root: root}
    end

    for key <- ["import", "default", "style", "zzz"] do
      test "a #{key} chain 20,000 deep has no target, and 32 still does", ctx do
        key = unquote(key)

        manifest = fn depth, target ->
          inner = nested(depth, key, target)

          write(
            ctx.root,
            "node_modules/deep/package.json",
            ~s({"exports":{".":#{inner},"./theme.css":#{inner}}})
          )
        end

        target = Path.join(ctx.root, "node_modules/deep/dist/theme.css")
        index = Path.join(ctx.root, "node_modules/deep/index.css")

        manifest.(32, "./dist/theme.css")
        assert Theme.resolve_stylesheet(ctx.root, "deep") == target
        assert Theme.resolve_stylesheet(ctx.root, "deep/theme.css") == target

        manifest.(33, "./dist/theme.css")
        assert Theme.resolve_stylesheet(ctx.root, "deep") == index
        assert Theme.resolve_stylesheet(ctx.root, "deep/theme.css") == nil

        manifest.(20_000, "./dist/theme.css")
        assert Theme.resolve_stylesheet(ctx.root, "deep") == index
        assert Theme.resolve_stylesheet(ctx.root, "deep/theme.css") == nil
      end
    end

    test "fallback arrays 20,000 deep have no target", ctx do
      inner = repeat("[", 20_000) <> ~s("./dist/theme.css") <> repeat("]", 20_000)
      write(ctx.root, "node_modules/deep/package.json", ~s({"exports":{"./theme.css":#{inner}}}))

      assert Theme.resolve_stylesheet(ctx.root, "deep/theme.css") == nil
    end

    test "a chain of conditions with no target does not double the walk", ctx do
      # Every level names import twice over: tried again among the rest, 2^32.
      inner = repeat(~s({"import":), 32) <> "1" <> repeat("}", 32)
      write(ctx.root, "node_modules/deep/package.json", ~s({"exports":{"./theme.css":#{inner}}}))

      assert quick(fn -> Theme.resolve_stylesheet(ctx.root, "deep/theme.css") end) == nil
    end
  end

  describe "package targets, in the Tailwind build" do
    defp link_tailwind(dir) do
      source = Path.expand("../fixtures/node/node_modules", __DIR__)
      target = Path.join(dir, "node_modules")
      File.mkdir_p!(target)

      for entry <- File.ls!(source), not String.starts_with?(entry, ".") do
        File.ln_s!(Path.join(source, entry), Path.join(target, entry))
      end

      dir
    end

    # A package whose every way to the stylesheet outside must be refused, each with a
    # way to its own stylesheet behind it. Tailwind answers `kitN-inside`, and would
    # answer `outside` only by reading the file outside.
    @kits %{
      "array" => ~s({"exports":{"./t.css":["../../outside.css","./dist/t.css"]}}),
      "condition" =>
        ~s({"exports":{"./t.css":{"style":"../../outside.css","default":"./dist/t.css"}}}),
      "root_condition" =>
        ~s({"exports":{".":{"style":"../../outside.css","default":"./dist/t.css"}}}),
      "root_string" => ~s({"exports":"../../outside.css"}),
      "style" => ~s({"style":"../../outside.css"}),
      "main" => ~s({"main":"../../outside.css"}),
      "capture" => ~s({"exports":{"./*":"./dist/*"}}),
      "unc" => ~s({"exports":{"./t.css":["//host/share/x.css","./dist/t.css"]}})
    }

    @imports [
      "array/t.css",
      "condition/t.css",
      "root_condition",
      "root_string",
      "style",
      "main",
      "capture/t.css",
      "unc/t.css"
    ]

    defp kit_files do
      Enum.reduce(@kits, %{"outside.css" => "@utility outside { color: red; }\n"}, fn {name, json},
                                                                                      files ->
        Map.merge(files, %{
          "node_modules/#{name}/package.json" => json,
          "node_modules/#{name}/index.css" => "@utility #{name}-index { color: red; }\n",
          "node_modules/#{name}/dist/t.css" => "@utility #{name}-inside { color: red; }\n"
        })
      end)
    end

    defp app_css do
      imports = Enum.map_join(@imports, &~s(@import "#{&1}";\n))
      ~s(@import "tailwindcss";\n#{imports})
    end

    @tag :tailwind
    test "never read a file outside the package", %{tmp_dir: dir} do
      link_tailwind(dir)

      result =
        run(
          dir,
          kit_files()
          |> Map.put("assets/css/app.css", app_css())
          |> Map.merge(
            page(
              ~s(<div class="outside array-inside root_string-index style-index main-index capture-inside unc-inside condition-inside root_condition-inside" />)
            )
          ),
          rules: [no_unknown_classes: :error],
          settings: [theme: "assets/css/app.css"]
        )

      assert result.warnings == []
      assert [%{message: message}] = result.diagnostics
      assert message =~ ~s("outside")
    end

    @tag :tailwind
    test "an escaping target alone cannot be built", %{tmp_dir: dir} do
      link_tailwind(dir)

      result =
        run(
          dir,
          page(~s(<div class="flex zorblax" />))
          |> Map.merge(%{
            "outside.css" => "@utility outside { color: red; }\n",
            "node_modules/kit/package.json" => ~s({"exports":{"./t.css":"../../outside.css"}}),
            "assets/css/app.css" => ~s(@import "tailwindcss";\n@import "kit/t.css";\n)
          }),
          rules: [no_unknown_classes: :error],
          settings: [theme: "assets/css/app.css"]
        )

      assert Enum.any?(result.warnings, &(&1 =~ ~s(@import "kit/t.css" could not be resolved)))
    end

    @tag :tailwind
    test "conditions 20,000 deep have no target", %{tmp_dir: dir} do
      link_tailwind(dir)

      deep = fn key, target ->
        repeat(~s({"#{key}":), 20_000) <> inspect(target) <> repeat("}", 20_000)
      end

      result =
        run(
          dir,
          page(~s(<div class="deep_style-index deep_style-inside flx" />))
          |> Map.merge(%{
            "node_modules/deep_style/package.json" =>
              ~s({"exports":{".":#{deep.("style", "./dist/t.css")}}}),
            "node_modules/deep_style/index.css" => "@utility deep_style-index { color: red; }\n",
            "node_modules/deep_style/dist/t.css" =>
              "@utility deep_style-inside { color: red; }\n",
            "assets/css/app.css" => ~s(@import "tailwindcss";\n@import "deep_style";\n)
          }),
          rules: [no_unknown_classes: :error],
          settings: [theme: "assets/css/app.css"]
        )

      assert result.warnings == []

      assert Enum.map(result.diagnostics, & &1.message) |> Enum.map(&hd(String.split(&1, ~s(" )))) ==
               [~s("deep_style-inside), ~s("flx)]
    end
  end
end

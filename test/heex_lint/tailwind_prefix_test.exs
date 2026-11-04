defmodule HeexLint.TailwindPrefixTest do
  # Under `@import "tailwindcss" prefix(tw)`, only tw:flex is a Tailwind class:
  # no_raw_colors leaves an unprefixed text-muted alone, and whether it exists is
  # no_unknown_classes' question.
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  alias HeexLint.{Project, Theme}

  @moduletag :tmp_dir

  @prefixed """
  @import "tailwindcss" prefix(tw);

  @theme {
    --color-primary: #171717;
    --color-muted: #f5f5f5;
  }
  """

  @both_rules [no_unknown_classes: :error, no_raw_colors: :error]

  # Findings on the page alone: the test project's own components are written
  # without the prefix.
  defp page(dir, template, rules, extra \\ %{}, settings \\ []) do
    files =
      Map.merge(
        %{"assets/css/app.css" => @prefixed, "lib/app_web/live/page_live.ex" => live(template)},
        extra
      )

    dir
    |> lint(files, rules: rules, settings: settings)
    |> Enum.filter(&String.ends_with?(&1.file, "page_live.ex"))
  end

  defp standalone(dir, template, rules \\ @both_rules, extra \\ %{}),
    do: page(dir, template, rules, extra, tailwind_bin: standalone_bin())

  defp classes(findings), do: Enum.map(findings, &hd(Regex.run(~r/"[^"]+"/, &1.message)))

  defp by_rule(findings, rule), do: findings |> Enum.filter(&(&1.rule == rule)) |> classes()

  defp write(dir, files) do
    for {path, css} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, css)
    end
  end

  defp load(dir, files, entry \\ "app.css") do
    write(dir, files)
    Theme.load(Path.join(dir, entry))
  end

  describe "parse_tailwind_prefix/1" do
    # Called at run time, so this file compiles against a Theme without it.
    defp parse_tailwind_prefix(css), do: apply(Theme, :parse_tailwind_prefix, [css])

    test "reads the prefix of a Tailwind import" do
      assert parse_tailwind_prefix(~S|@import "tailwindcss" prefix(tw);|) == "tw"
      assert parse_tailwind_prefix(~S|@import 'tailwindcss' prefix(tw);|) == "tw"
      assert parse_tailwind_prefix(~S|@import url("tailwindcss") prefix(tw);|) == "tw"

      assert parse_tailwind_prefix(~S|@import "tailwindcss/theme.css" layer(theme) prefix(tw);|) ==
               "tw"

      assert parse_tailwind_prefix(~S|@import "tailwindcss" source(none) prefix(tw);|) == "tw"
    end

    test "reads it across lines, spaces and an import with no `;`" do
      assert parse_tailwind_prefix(~s|@import "./a.css";\n@import "tailwindcss"\n  prefix(tw);|) ==
               "tw"

      assert parse_tailwind_prefix(~S|@import url('tailwindcss/theme') prefix( tw )|) == "tw"
    end

    test "reads no further than the `;` that ends the import" do
      assert parse_tailwind_prefix(~S|@import "tailwindcss"; .x { a: prefix(tw) }|) == nil
    end

    test "reads a later Tailwind import when the first has none" do
      css = ~S"""
      @import "tailwindcss/theme.css" layer(theme);
      @import "tailwindcss/utilities.css" layer(utilities) prefix(tw);
      """

      assert parse_tailwind_prefix(css) == "tw"
    end

    test "reads only Tailwind's imports" do
      assert parse_tailwind_prefix(~S|@import "tailwind" prefix(tw);|) == nil
      assert parse_tailwind_prefix(~S|@import "tailwindcss-animate" prefix(tw);|) == nil
      assert parse_tailwind_prefix(~S|@import "./tailwindcss" prefix(tw);|) == nil
      assert parse_tailwind_prefix(~S|@import "./a.css" prefix(aa); .x { color: red; }|) == nil

      assert parse_tailwind_prefix(~S|@import "./a.css" prefix(aa); @import "tailwindcss";|) ==
               nil
    end

    test "reads past comments" do
      assert parse_tailwind_prefix(~S|/* @import "tailwindcss" prefix(tw); */|) == nil
      assert parse_tailwind_prefix(~S|@import "tailwindcss" /* prefix(aa) */;|) == nil
      assert parse_tailwind_prefix(~S|@import "tailwindcss" /* prefix(aa) */ prefix(tw);|) == "tw"
    end

    test "takes prefix( at a word boundary, with a name" do
      assert parse_tailwind_prefix(~S|@import "tailwindcss" xprefix(tw);|) == nil
      assert parse_tailwind_prefix(~S|@import "tailwindcss" prefix();|) == nil
      assert parse_tailwind_prefix(~S|@import "tailwindcss" prefix(t-w);|) == "t-w"
    end

    test "an @import with no `;` costs one scan" do
      plain = String.duplicate("@import 'a' ", 20_000)
      tailwind = String.duplicate(~S|@import "tailwindcss" |, 20_000)

      {micros, answers} =
        :timer.tc(fn -> {parse_tailwind_prefix(plain), parse_tailwind_prefix(tailwind)} end)

      assert answers == {nil, nil}
      assert micros < 1_000_000
    end
  end

  describe "parse_imports/1 with a prefix in the statement" do
    test "reads the id, and the rule ends at its `;`" do
      css = ~S"""
      @import "tailwindcss" prefix(tw);
      @import url("./a.css") layer(base);
      @import './b;c.css' supports(display: grid);
      @import "./open.css"
      """

      assert Theme.parse_imports(css) == ["tailwindcss", "./a.css", "./b;c.css"]
      assert Theme.parse_imports(~S|@import "./a.css" @import "./b.css";|) == ["./a.css"]
    end
  end

  describe "Theme.load/1" do
    test "has no prefix without one", %{tmp_dir: dir} do
      assert load(dir, %{"app.css" => ~S|@import "tailwindcss";|}).prefix == nil
    end

    test "reads the prefix of the stylesheet, and still sees Tailwind", %{tmp_dir: dir} do
      theme = load(dir, %{"app.css" => @prefixed})
      assert theme.prefix == "tw"
      assert theme.tailwind
      assert theme.files == [Path.join(dir, "app.css")]
    end

    test "reads the prefix of an imported stylesheet", %{tmp_dir: dir} do
      theme =
        load(dir, %{
          "app.css" => ~S|@import "./base.css";|,
          "base.css" => ~S|@import "tailwindcss" prefix(tw);|
        })

      assert theme.prefix == "tw"
    end

    test "the first one read wins, and a file comes before its imports", %{tmp_dir: dir} do
      assert load(dir, %{
               "app.css" => ~S|@import "./one.css"; @import "tailwindcss" prefix(bb);|,
               "one.css" => ~S|@import "tailwindcss/theme.css" prefix(aa);|
             }).prefix == "bb"

      assert load(dir, %{
               "app.css" => ~S|@import "./one.css"; @import "./two.css";|,
               "one.css" => ~S|@import "tailwindcss/theme.css" prefix(aa);|,
               "two.css" => ~S|@import "tailwindcss/utilities.css" prefix(bb);|
             }).prefix == "aa"
    end

    test "a package's prefix is not the project's", %{tmp_dir: dir} do
      kit = %{
        "node_modules/kit/package.json" => ~S|{"name":"kit","style":"index.css"}|,
        "node_modules/kit/index.css" => ~S|@import "tailwindcss" prefix(tw);|
      }

      theme = load(dir, Map.put(kit, "app.css", ~S|@import "kit";|))
      assert theme.prefix == nil
      # It imports Tailwind all the same.
      assert theme.tailwind
      assert Path.join(dir, "node_modules/kit/index.css") in theme.files

      assert load(
               dir,
               Map.put(kit, "app.css", ~S|@import "kit"; @import "tailwindcss" prefix(aa);|)
             ).prefix ==
               "aa"
    end

    test "a stylesheet imported only from a package is a package's too", %{tmp_dir: dir} do
      theme =
        load(dir, %{
          "app.css" => ~S|@import "kit";|,
          "node_modules/kit/package.json" => ~S|{"name":"kit","style":"index.css"}|,
          "node_modules/kit/index.css" => ~S|@import "./base.css";|,
          "node_modules/kit/base.css" => ~S|@import "tailwindcss" prefix(tw);|
        })

      assert theme.prefix == nil
    end

    test "a workspace package linked into node_modules is the project's", %{tmp_dir: dir} do
      write(dir, %{
        "packages/kit/package.json" => ~S|{"name":"kit","style":"index.css"}|,
        "packages/kit/index.css" => ~S|@import "tailwindcss" prefix(tw);|
      })

      File.mkdir_p!(Path.join(dir, "node_modules"))
      File.ln_s!(Path.join(dir, "packages/kit"), Path.join(dir, "node_modules/kit"))

      assert load(dir, %{"app.css" => ~S|@import "kit";|}).prefix == "tw"
    end

    test "editing the prefix changes the signature", %{tmp_dir: dir} do
      plain = load(dir, %{"app.css" => ~S|@import "tailwindcss";|})
      prefixed = load(dir, %{"app.css" => ~S|@import "tailwindcss" prefix(tw);|})
      again = load(dir, %{"app.css" => ~S|@import "tailwindcss" prefix(tw);|})

      assert Theme.signature(prefixed) != Theme.signature(plain)
      assert Theme.signature(prefixed) == Theme.signature(again)
    end
  end

  describe "the stylesheet Tailwind builds gives the prefix" do
    defp project(dir, files, settings \\ []) do
      write(dir, files)
      Project.load(dir, [], settings)
    end

    test "with the theme itself", %{tmp_dir: dir} do
      project = project(dir, %{"assets/css/app.css" => @prefixed})
      assert project.tailwind_prefix == "tw"
      assert Project.tailwind_class?(project, "tw:flex")
      assert Project.tailwind_class?(project, "tw:hover:flex")
      refute Project.tailwind_class?(project, "flex")
      refute Project.tailwind_class?(project, "hover:tw:flex")
      refute Project.tailwind_class?(project, "!tw:flex")
      refute Project.tailwind_class?(project, "tw-flex")
    end

    test "every class is Tailwind's without one", %{tmp_dir: dir} do
      project = project(dir, %{"assets/css/app.css" => ~S|@import "tailwindcss";|})
      assert project.tailwind_prefix == nil
      assert Project.tailwind_class?(project, "flex")
      assert Project.tailwind_class?(project, "tw:flex")
    end

    test "a partial asks the stylesheet discovered for Tailwind", %{tmp_dir: dir} do
      project =
        project(
          dir,
          %{
            "assets/css/tokens.css" => "@theme { --color-primary: #111; }",
            "assets/css/app.css" => ~S|@import "tailwindcss" prefix(tw);|
          },
          theme: "assets/css/tokens.css"
        )

      assert project.theme.prefix == nil
      assert project.entry == Path.join(dir, "assets/css/app.css")
      assert project.tailwind_prefix == "tw"
    end

    test "a partial's own text is not a build Tailwind runs", %{tmp_dir: dir} do
      # With no `;` this import reads as no import, so the build is elsewhere.
      unterminated = ~S|@theme { --color-primary: #111; } @import "tailwindcss" prefix(tw)|

      project =
        project(
          dir,
          %{
            "assets/css/tokens.css" => unterminated,
            "assets/css/app.css" => ~S|@import "tailwindcss";|
          },
          theme: "assets/css/tokens.css"
        )

      assert project.theme.prefix == "tw"
      assert project.tailwind_prefix == nil
    end

    test "no build has no prefix", %{tmp_dir: dir} do
      unterminated = ~S|@theme { --color-primary: #111; } @import "tailwindcss" prefix(tw)|

      project =
        project(dir, %{"assets/css/tokens.css" => unterminated}, theme: "assets/css/tokens.css")

      assert project.entry == nil
      assert project.tailwind_prefix == nil
    end
  end

  describe "no_raw_colors" do
    @no_raw_colors [no_raw_colors: :error]

    test "leaves an unprefixed class alone", %{tmp_dir: dir} do
      assert page(
               dir,
               ~s(<div class="tw:text-primary text-muted text-red-500 flex text-whatever" />),
               @no_raw_colors
             ) == []
    end

    test "still judges a prefixed class", %{tmp_dir: dir} do
      [undeclared, palette] =
        page(dir, ~s(<div class="tw:text-nope tw:bg-red-500" />), @no_raw_colors)

      assert undeclared.message ==
               ~s|"tw:text-nope" is not a declared theme color. Use one of: muted, primary. To add a color, declare --color-<name> in assets/css/app.css first.|

      assert palette.message =~ ~s("tw:bg-red-500" uses the raw Tailwind palette)
    end

    test "reads the class behind the prefix", %{tmp_dir: dir} do
      assert page(
               dir,
               ~s(<div class="tw:bg-primary tw:hover:bg-muted/50 tw:bg-transparent tw:fill-none" />),
               @no_raw_colors
             ) == []

      assert classes(
               page(
                 dir,
                 ~s(<div class="tw:hover:bg-red-500 tw:!bg-red-500 tw:bg-red-500/50 tw:md:hover:text-nope" />),
                 @no_raw_colors
               )
             ) == [
               ~s("tw:hover:bg-red-500"),
               ~s("tw:!bg-red-500"),
               ~s("tw:bg-red-500/50"),
               ~s("tw:md:hover:text-nope")
             ]
    end

    test "the prefix comes first, as Tailwind reads it", %{tmp_dir: dir} do
      assert page(dir, ~s(<div class="hover:tw:bg-red-500 !tw:bg-red-500" />), @no_raw_colors) ==
               []
    end

    test "only the project's prefix counts", %{tmp_dir: dir} do
      assert page(dir, ~s(<div class="aa:bg-red-500 tw-bg-red-500" />), @no_raw_colors) == []
    end

    test "a suggestion keeps the prefix", %{tmp_dir: dir} do
      css = ~S|@import "tailwindcss" prefix(tw); @theme { --color-ink: #18181b; }|

      [finding] =
        page(dir, ~s(<div class="tw:hover:bg-zinc-900/50" />), @no_raw_colors, %{
          "assets/css/app.css" => css
        })

      assert [%{replacement: "tw:hover:bg-ink/50"}] = finding.suggestions
    end

    test "deny reaches white and black only behind the prefix", %{tmp_dir: dir} do
      rules = [no_raw_colors: {:error, deny: ["*-white", "*-black"]}]

      assert classes(page(dir, ~s(<div class="text-white bg-black tw:text-white" />), rules)) ==
               [~s("tw:text-white")]
    end

    test "scan_all_strings leaves an unprefixed string alone", %{tmp_dir: dir} do
      module = """
      defmodule AppWeb.Tones do
        def tones, do: ["bg-red-500", "tw:bg-red-500"]
      end
      """

      files = %{"assets/css/app.css" => @prefixed, "lib/app_web/tones.ex" => module}

      findings = lint(dir, files, rules: [no_raw_colors: {:error, scan_all_strings: true}])

      assert classes(Enum.filter(findings, &String.ends_with?(&1.file, "tones.ex"))) ==
               [~s("tw:bg-red-500")]
    end

    test "needs no Tailwind to ask, and judges every class without a prefix", %{tmp_dir: dir} do
      plain = ~S|@import "tailwindcss"; @theme { --color-primary: #171717; }|

      assert classes(
               page(dir, ~s(<div class="text-red-500 tw:text-red-500" />), @no_raw_colors, %{
                 "assets/css/app.css" => plain
               })
             ) == [~s("text-red-500"), ~s("tw:text-red-500")]
    end

    test "a partial theme takes the prefix of the build", %{tmp_dir: dir} do
      files = %{
        "assets/css/tokens.css" => "@theme { --color-primary: #171717; }",
        "assets/css/app.css" => ~S|@import "tailwindcss" prefix(tw);|
      }

      assert classes(
               page(
                 dir,
                 ~s(<div class="text-red-500 tw:text-red-500 tw:bg-primary" />),
                 @no_raw_colors,
                 files,
                 theme: "assets/css/tokens.css"
               )
             ) == [~s("tw:text-red-500")]
    end

    test "each app of an umbrella has its own prefix", %{tmp_dir: dir} do
      app = fn name, import ->
        %{
          "apps/#{name}/mix.exs" => "defmodule #{Macro.camelize(name)}.MixProject do\nend\n",
          "apps/#{name}/assets/css/app.css" => import <> "\n@theme { --color-primary: #123; }\n",
          "apps/#{name}/lib/#{name}_web/live/page_live.ex" =>
            live(~s(<div class="bg-red-500" />), Macro.camelize(name) <> "Live")
        }
      end

      files =
        Map.merge(
          app.("shop", ~S|@import "tailwindcss" prefix(tw);|),
          app.("admin", ~S|@import "tailwindcss";|)
        )
        |> Map.put("mix.exs", "defmodule Umbrella.MixProject do\nend\n")
        |> Map.put("assets/css/app.css", nil)

      result =
        run(dir, files, rules: @no_raw_colors, inputs: ["apps/*/lib/**/*.{ex,heex}"])

      assert Enum.map(
               result.diagnostics,
               &(&1.file |> Path.relative_to(dir) |> Path.split() |> Enum.at(1))
             ) ==
               ["admin"]
    end
  end

  describe "no_unknown_classes with the project's Tailwind" do
    @describetag :tailwind

    test "reports an unprefixed color class as unknown", %{tmp_dir: dir} do
      with_tailwind(dir)

      findings =
        page(dir, ~s(<div class="tw:text-primary text-muted text-red-500 flex" />),
          no_unknown_classes: :error
        )

      expected =
        for class <- ~w(text-muted text-red-500 flex) do
          ~s|"#{class}" is not a class this project's Tailwind knows, so no CSS is generated for it. Fix the spelling, or declare it with @utility in assets/css/app.css.|
        end

      assert Enum.map(findings, & &1.message) == expected
    end

    test "one rule reports each class", %{tmp_dir: dir} do
      with_tailwind(dir)

      findings =
        page(
          dir,
          ~s(<div class="text-muted bg-red-500 tw:text-nope tw:bg-red-500 tw:bg-primry tw:flex" />),
          @both_rules
        )

      assert by_rule(findings, :no_unknown_classes) == [~s("text-muted"), ~s("bg-red-500")]

      assert by_rule(findings, :no_raw_colors) == [
               ~s("tw:text-nope"),
               ~s("tw:bg-red-500"),
               ~s("tw:bg-primry")
             ]
    end

    test "a variant no theme knows stands on the bare utility, with no prefix", %{tmp_dir: dir} do
      findings =
        standalone(
          dir,
          ~s(<div class="hovr:focus:bg-primary" />),
          [no_unknown_classes: :error],
          %{
            "assets/css/app.css" => String.replace(@prefixed, " prefix(tw)", "")
          }
        )

      assert [finding] = findings
      assert finding.message =~ "uses a variant this project's Tailwind does not know"
    end

    test "a prefixed color still belongs to no_raw_colors", %{tmp_dir: dir} do
      with_tailwind(dir)

      assert page(dir, ~s(<div class="tw:text-nope tw:bg-primry" />), no_unknown_classes: :error) ==
               []
    end

    test "the prefix is kept when the bare utility is checked", %{tmp_dir: dir} do
      with_tailwind(dir)

      [color, variant, flex] =
        page(
          dir,
          ~s(<div class="tw:hovr:bg-primary tw:bogus:text-primary tw:hovr:flex tw:bg-primary" />),
          no_unknown_classes: :error
        )

      assert color.message =~ ~s(Did you mean "tw:hover:bg-primary"?)
      assert [%{replacement: "tw:hover:bg-primary"}] = color.suggestions
      assert variant.message =~ ~s("tw:bogus:text-primary" uses a variant)
      assert flex.message =~ ~s(Did you mean "tw:hover:flex"?)
    end

    test "without a prefix, the same color stays with no_raw_colors", %{tmp_dir: dir} do
      with_tailwind(dir)
      plain = ~S|@import "tailwindcss"; @theme { --color-primary: #171717; }|

      assert page(dir, ~s(<div class="text-nope" />), [no_unknown_classes: :error], %{
               "assets/css/app.css" => plain
             }) == []
    end
  end

  describe "no_unknown_classes with the standalone Tailwind binary" do
    @describetag :standalone

    test "reports an unprefixed color class as unknown", %{tmp_dir: dir} do
      findings =
        standalone(dir, ~s(<div class="tw:text-primary text-muted text-red-500 flex" />),
          no_unknown_classes: :error
        )

      assert classes(findings) == [~s("text-muted"), ~s("text-red-500"), ~s("flex")]
    end

    test "knows prefixed classes, however Tailwind escapes them", %{tmp_dir: dir} do
      assert standalone(
               dir,
               ~s(<div class="tw:flex tw:hover:flex tw:flex! tw:-mt-4 tw:bg-primary/50 tw:p-0.5 tw:2xl:flex tw:w-1/2" />),
               no_unknown_classes: :error
             ) == []
    end

    test "a known utility behind the prefix marks a variant problem", %{tmp_dir: dir} do
      findings =
        standalone(
          dir,
          ~s(<div class="tw:hovr:flex tw:hovr:bg-primary tw:bogus:text-primary tw:hover:hovr:flex" />),
          no_unknown_classes: :error
        )

      assert classes(findings) == [
               ~s("tw:hovr:flex"),
               ~s("tw:hovr:bg-primary"),
               ~s("tw:bogus:text-primary"),
               ~s("tw:hover:hovr:flex")
             ]

      for finding <- findings,
          do: assert(finding.message =~ "uses a variant this project's Tailwind does not know")
    end

    test "an unknown utility behind the prefix is no variant problem", %{tmp_dir: dir} do
      findings =
        standalone(dir, ~s(<div class="tw:nope tw:hover:nope hovr:flex hover:hovr:flex" />),
          no_unknown_classes: :error
        )

      assert classes(findings) == [
               ~s("tw:nope"),
               ~s("tw:hover:nope"),
               ~s("hovr:flex"),
               ~s("hover:hovr:flex")
             ]

      for finding <- findings,
          do: assert(finding.message =~ "Fix the spelling, or declare it with @utility")
    end

    test "a prefixed color still belongs to no_raw_colors", %{tmp_dir: dir} do
      findings = standalone(dir, ~s(<div class="tw:text-nope text-nope tw:flex" />))
      assert by_rule(findings, :no_raw_colors) == [~s("tw:text-nope")]
      assert by_rule(findings, :no_unknown_classes) == [~s("text-nope")]
    end

    test "a package's prefix is read from the build", %{tmp_dir: dir} do
      findings =
        standalone(dir, ~s(<div class="tw:flex tw:hovr:flex" />), [no_unknown_classes: :error], %{
          "assets/css/app.css" => ~S|@import "kit";|,
          "node_modules/kit/package.json" => ~S|{"name":"kit","style":"index.css"}|,
          "node_modules/kit/index.css" => ~S|@import "tailwindcss" prefix(tw);|
        })

      assert [finding] = findings
      assert finding.message =~ ~s("tw:hovr:flex" uses a variant)
    end
  end

  describe "the standalone binary reads whole selectors" do
    @describetag :standalone

    test "a class is not known because a longer one is built", %{tmp_dir: dir} do
      assert classes(
               standalone(dir, ~s(<div class="tw:fle tw:flex tw:flex-col tw:flex!" />),
                 no_unknown_classes: :error
               )
             ) == [~s("tw:fle")]
    end

    test "without a prefix too", %{tmp_dir: dir} do
      plain = ~S|@import "tailwindcss"; @theme { --color-primary: #171717; }|

      assert classes(
               standalone(
                 dir,
                 ~s(<div class="fle flex flex-col bg-primary/50 hover:flex" />),
                 [no_unknown_classes: :error],
                 %{"assets/css/app.css" => plain}
               )
             ) == [~s("fle")]
    end

    test "a selector that only starts with the class does not count", %{tmp_dir: dir} do
      assert classes(
               standalone(
                 dir,
                 ~s(<div class="tw tw:flex hover tw:hover:flex tw:text tw:text-lg" />),
                 no_unknown_classes: :error
               )
             ) == [~s("tw"), ~s("hover"), ~s("tw:text")]
    end

    test "a variant's selector still counts", %{tmp_dir: dir} do
      plain = ~S|@import "tailwindcss"; @theme { --color-primary: #171717; }|

      assert standalone(
               dir,
               ~s(<div class="hover:flex md:flex group-hover:flex dark:flex [&_svg]:size-4 2xl:flex *:flex" />),
               [no_unknown_classes: :error],
               %{"assets/css/app.css" => plain}
             ) == []
    end
  end

  describe "Tailwind.selector?/2" do
    # Called at run time, so this file compiles against a Tailwind without it.
    defp selector?(css, class), do: apply(HeexLint.Tailwind, :selector?, [css, class])

    test "finds a class however its selector goes on" do
      for css <- [
            ".ledger",
            ".ledger {",
            ".ledger{",
            ".ledger:hover {",
            ".ledger::before {",
            ".ledger, .x {",
            ".ledger > .x {",
            ".ledger.x {",
            ".x .ledger {",
            ":is(.ledger) {",
            ".ledger[data-x] {"
          ] do
        assert selector?(css, "ledger"), css
      end
    end

    test "every character that continues a name makes it another class" do
      for rest <- ["_row", "-row", "Row", "row", "9", "é", "\\:row"] do
        refute selector?(".ledger#{rest} {", "ledger"), rest
      end
    end

    test "finds it past a longer one" do
      assert selector?(".flex-col { } .flex { }", "flex")
    end

    test "escapes the class the way Tailwind does" do
      assert selector?(".tw\\:hover\\:flex:hover {", "tw:hover:flex")
      assert selector?(".tw\\:p-0\\.5 {", "tw:p-0.5")
      assert selector?(".\\32 xl\\:flex {", "2xl:flex")
      refute selector?(".tw\\:flex {", "flex")
      refute selector?(".tw\\:flex {", "tw")
      refute selector?(".tw\\:flex\\! {", "tw:flex")
    end
  end

  describe "no_unknown_classes without a Tailwind to ask" do
    test "the grammar answers, and it knows no prefix", %{tmp_dir: dir} do
      findings =
        page(dir, ~s(<div class="flex text-red-500 tw:flex zorblax tw:zorblax" />),
          no_unknown_classes: :error
        )

      assert classes(findings) == [~s("zorblax"), ~s("tw:zorblax")]
    end
  end

  test "each app's files get that app's prefix", %{tmp_dir: dir} do
    write(dir, %{
      "mix.exs" => "",
      "apps/web/mix.exs" => "",
      "apps/web/assets/css/app.css" => @prefixed,
      "apps/admin/mix.exs" => "",
      "apps/admin/assets/css/app.css" => ~s(@import "tailwindcss";\n)
    })

    web = Path.join(dir, "apps/web/lib/page.ex")
    admin = Path.join(dir, "apps/admin/lib/page.ex")

    for file <- [web, admin] do
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "defmodule Page do\nend\n")
    end

    found = Project.load(dir, [web, admin], [])

    assert Project.for_file(found, web).tailwind_prefix == "tw"
    assert Project.for_file(found, admin).tailwind_prefix == nil
  end
end

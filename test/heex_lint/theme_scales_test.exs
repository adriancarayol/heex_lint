defmodule HeexLint.ThemeScalesTest do
  # The scales a theme declares reach the grammar the way `cn build` registers
  # them: --radius-card makes rounded-card a radius, and --radius-*: initial
  # replaces the default names with the declared ones.
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  alias HeexLint.Grammar.{Classifier, ProjectClassifier, ThemeScales}
  alias HeexLint.Theme

  doctest ThemeScales

  @moduletag :tmp_dir

  @scales """
  @import "tailwindcss";
  @theme inline {
    --color-primary: #111;
    --text-stat-label: 13px;
    --shadow-card-glow: 0 0 24px #000;
    --drop-shadow-lift: 0 4px 8px #000;
    --background-image-stripes: none;
    --radius-card: 12px;
    --spacing-gutter: 1.5rem;
    --tracking-display: -0.02em;
    --leading-display: 1.1;
    --breakpoint-wide: 96rem;
    --container-prose: 65ch;
    --ease-snappy: linear;
    --blur-glass: 12px;
    --perspective-stage: 1200px;
    --aspect-poster: 2 / 3;
    --font-weight-chunky: 800;
    --inset-shadow-deep: inset 0 0 1px #000;
    --text-shadow-crisp: 0 0 1px #000;
    --animate-wiggle: wiggle 1s;
  }
  :root { --radius-panel: 8px; }
  .compact { --radius-scoped: 8px; }
  """

  defp theme(dir, css, files \\ %{}) do
    for {path, contents} <- Map.put(files, "app.css", css) do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, contents)
    end

    Theme.load(Path.join(dir, "app.css"))
  end

  defp declarations(pairs) do
    for {name, value} <- pairs, do: %{name: name, value: value, theme: true}
  end

  defp lint_classes(dir, css, template, rules) do
    lint(
      dir,
      %{"assets/css/app.css" => css, "lib/app_web/live/page_live.ex" => live(template)},
      rules: rules
    )
  end

  describe "ThemeScales.of" do
    test "declared names extend a scale" do
      assert ThemeScales.of(declarations([{"radius-card", "1px"}, {"radius-pill", "9px"}])) ==
               %{extend: %{"radius" => ["card", "pill"]}, override: %{}}
    end

    test "only @theme declarations count" do
      assert ThemeScales.of([%{name: "radius-card", value: "1px", theme: false}]) ==
               %{extend: %{}, override: %{}}
    end

    test "the longest namespace wins" do
      scales =
        ThemeScales.of(
          declarations([
            {"text-shadow-crisp", "x"},
            {"inset-shadow-deep", "x"},
            {"drop-shadow-lift", "x"},
            {"text-color-x", "x"},
            {"font-weight-chunky", "1"}
          ])
        )

      assert scales.extend == %{
               "text-shadow" => ["crisp"],
               "inset-shadow" => ["deep"],
               "drop-shadow" => ["lift"],
               "text" => ["color-x"],
               "font-weight" => ["chunky"]
             }
    end

    test "colors, fonts and other namespaces are left out" do
      assert ThemeScales.of(
               declarations([{"color-primary", "x"}, {"font-sans", "x"}, {"other-x", "x"}])
             ) == %{extend: %{}, override: %{}}
    end

    test "a sub-property is not a name, and neither is an empty one" do
      assert ThemeScales.of(
               declarations([
                 {"text-display", "1px"},
                 {"text-display--line-height", "1"},
                 {"text-", "1px"}
               ])
             ) == %{extend: %{"text" => ["display"]}, override: %{}}
    end

    test "a name set to initial is dropped, and declared again goes last" do
      assert ThemeScales.of(
               declarations([
                 {"radius-a", "1px"},
                 {"radius-b", "1px"},
                 {"radius-a", "initial"},
                 {"radius-gone", "initial"},
                 {"radius-b", "2px"},
                 {"radius-a", "1px"}
               ])
             ) == %{extend: %{"radius" => ["b", "a"]}, override: %{}}
    end

    test "a namespace reset drops what came before and overrides with what follows" do
      assert ThemeScales.of(
               declarations([
                 {"radius-old", "1px"},
                 {"radius-*", "initial"},
                 {"radius-fresh", "1px"},
                 {"text-*", "initial"}
               ])
             ) == %{extend: %{}, override: %{"radius" => ["fresh"], "text" => []}}
    end

    test "a reset needs the value initial" do
      assert ThemeScales.of(declarations([{"radius-*", "0"}, {"*", "0"}])) ==
               %{extend: %{}, override: %{}}
    end

    test "a full reset covers every scale but leaves colors and fonts alone" do
      %{extend: extend, override: override} =
        ThemeScales.of(
          declarations([{"radius-old", "1px"}, {"*", "initial"}, {"radius-fresh", "1px"}])
        )

      assert extend == %{}
      assert override["radius"] == ["fresh"]
      assert override["spacing"] == []
      assert map_size(override) == 17
      refute Map.has_key?(override, "color")
      refute Map.has_key?(override, "font")
    end

    test "--spacing after a reset brings the spacing scale back" do
      for reset <- ["*", "spacing-*"] do
        %{extend: extend, override: override} =
          ThemeScales.of(
            declarations([
              {reset, "initial"},
              {"spacing-old", "1px"},
              {"spacing", "0.25rem"},
              {"spacing-sidebar", "1px"}
            ])
          )

        assert extend["spacing"] == ["old", "sidebar"]
        refute Map.has_key?(override, "spacing")
      end
    end

    test "--spacing before a reset, or set to initial, does not" do
      assert ThemeScales.of(declarations([{"spacing", "1px"}, {"spacing-*", "initial"}])).override ==
               %{"spacing" => []}

      assert ThemeScales.of(declarations([{"spacing-*", "initial"}, {"spacing", "initial"}])).override ==
               %{"spacing" => []}
    end
  end

  describe "classifying declared scales" do
    for {custom, standard} <- [
          {"rounded-card", "rounded-lg"},
          {"hover:rounded-card", "hover:rounded-lg"},
          {"p-gutter", "p-4"},
          {"tracking-display", "tracking-tight"},
          {"leading-display", "leading-tight"},
          {"max-w-screen-wide", "max-w-screen-md"},
          {"columns-prose", "columns-3"},
          {"ease-snappy", "ease-in"},
          {"blur-glass", "blur-sm"},
          {"perspective-stage", "perspective-near"},
          {"aspect-poster", "aspect-video"},
          {"text-stat-label", "text-sm"},
          {"shadow-card-glow", "shadow-lg"},
          {"drop-shadow-lift", "drop-shadow-lg"},
          {"inset-shadow-deep", "inset-shadow-sm"},
          {"text-shadow-crisp", "text-shadow-sm"},
          {"font-chunky", "font-bold"},
          {"animate-wiggle", "animate-spin"}
        ] do
      test "#{custom} classifies with #{standard}", %{tmp_dir: dir} do
        read = theme(dir, @scales)
        group = ProjectClassifier.group_of(read, unquote(custom))

        assert group != nil
        assert group == ProjectClassifier.group_of(read, unquote(standard))
      end
    end

    test "what the theme does not declare stays unclassified", %{tmp_dir: dir} do
      read = theme(dir, @scales)

      # :root and scoped variables are not scales.
      for token <- ["rounded-nope", "rounded-panel", "rounded-scoped", "p-nope"] do
        assert {token, ProjectClassifier.group_of(read, token)} == {token, nil}
      end
    end

    test "without a theme there is nothing to read" do
      assert ProjectClassifier.group_of(nil, "rounded-card") == nil
      assert ProjectClassifier.group_of(Theme.load(nil), "rounded-card") == nil
      assert ProjectClassifier.group_of(nil, "rounded-lg") == "rounded"
    end

    test "a theme with no scales shares cn's own grammar", %{tmp_dir: dir} do
      read = theme(dir, ~s(@import "tailwindcss";\n@theme { --color-primary: #111; }))

      assert Theme.grammar(read) == nil
      assert ProjectClassifier.group_of(read, "rounded-lg") == "rounded"
    end

    test "cn's default grammar is unchanged by a theme", %{tmp_dir: dir} do
      theme(dir, @scales)

      assert Classifier.group_of("rounded-card") == nil
      assert Classifier.group_of("rounded-lg") == "rounded"
    end

    test "a later group still wins the same path", %{tmp_dir: dir} do
      read =
        theme(dir, """
        @theme {
          --radius-s: 1px;
          --radius-t-card: 1px;
          --text-center: 1px;
          --spacing-auto: 1px;
        }
        """)

      assert ProjectClassifier.group_of(read, "rounded-s") == "rounded-s"
      assert ProjectClassifier.group_of(read, "rounded-t-card") == "rounded"
      assert ProjectClassifier.group_of(read, "text-center") == "text-alignment"
      assert ProjectClassifier.group_of(read, "m-auto") == "m"
    end

    test "a line-height modifier keeps the declared size", %{tmp_dir: dir} do
      read = theme(dir, @scales)

      assert ProjectClassifier.group_of(read, "text-stat-label/6") == "font-size"
    end

    test "a sub-property does not name a class", %{tmp_dir: dir} do
      read = theme(dir, "@theme { --text-stat: 1px; --text-stat--line-height: 1; }")

      assert ProjectClassifier.group_of(read, "text-stat") == "font-size"
      assert ProjectClassifier.group_of(read, "text-stat--line-height") == "text-color"
    end

    test "a scale in an imported stylesheet counts, in cascade order", %{tmp_dir: dir} do
      read =
        theme(
          dir,
          ~s(@import "./scales.css";\n@theme { --radius-card: 1px; --radius-*: initial; --radius-pill: 1px; }),
          %{"scales.css" => "@theme { --radius-card: 1px; --text-kicker: 11px; }"}
        )

      assert ProjectClassifier.group_of(read, "text-kicker") == "font-size"
      assert ProjectClassifier.group_of(read, "rounded-card") == nil
      assert ProjectClassifier.group_of(read, "rounded-pill") == "rounded"
    end

    test "a declaration after a nested @keyframes counts", %{tmp_dir: dir} do
      read =
        theme(dir, """
        @theme {
          --animate-wiggle: wiggle 1s infinite;
          @keyframes wiggle { from { rotate: -3deg; } to { rotate: 3deg; } }
          --text-kicker: 11px;
          --radius-card: 8px;
        }
        """)

      assert ProjectClassifier.group_of(read, "text-kicker") == "font-size"
      assert ProjectClassifier.group_of(read, "rounded-card") == "rounded"
    end

    test "a missing import leaves the scales declared beside it", %{tmp_dir: dir} do
      read = theme(dir, ~s(@import "./missing.css";\n@theme { --radius-card: 8px; }))

      assert ProjectClassifier.group_of(read, "rounded-card") == "rounded"
      assert ProjectClassifier.group_of(read, "rounded-lg") == "rounded"
    end

    test "a package's scales do not count, its animations do", %{tmp_dir: dir} do
      read =
        theme(dir, ~s(@import "kit";\n@theme { --color-primary: #111; }), %{
          "node_modules/kit/package.json" => ~s({"name":"kit","style":"kit.css"}),
          "node_modules/kit/kit.css" => "@theme { --radius-kit: 1px; --animate-kit: kit 1s; }"
        })

      assert ProjectClassifier.group_of(read, "rounded-kit") == nil
      assert ProjectClassifier.group_of(read, "animate-kit") == "animate"
    end
  end

  describe "resets" do
    @reset """
    @import "tailwindcss";
    @theme inline {
      --radius-old: 4px;
      --radius-*: initial;
      --radius-fresh: 1rem;
      --text-old: 14px;
      --text-*: initial;
      --text-sm: 2rem;
      --color-primary: black;
    }
    """

    test "a reset replaces the default names with the declared ones", %{tmp_dir: dir} do
      read = theme(dir, @reset)

      assert ProjectClassifier.group_of(read, "rounded-lg") == nil
      assert ProjectClassifier.group_of(read, "rounded-old") == nil
      assert ProjectClassifier.group_of(read, "rounded-fresh") == "rounded"
      assert ProjectClassifier.group_of(read, "text-sm") == "font-size"
      assert ProjectClassifier.group_of(read, "text-lg") == "text-color"
      # Untouched scales keep their defaults.
      assert ProjectClassifier.group_of(read, "p-4") == "p"
    end

    test "a name set to initial on a default validator scale stays", %{tmp_dir: dir} do
      read = theme(dir, "@theme { --radius-lg: initial; --radius-card: 1px; }")

      assert ProjectClassifier.group_of(read, "rounded-lg") == "rounded"
    end

    test "--spacing after a full reset keeps the numeric scale", %{tmp_dir: dir} do
      read =
        theme(dir, """
        @theme static { --*: initial; }
        @theme static { --spacing: 0.25rem; --spacing-sidebar: 15.5rem; }
        """)

      assert ProjectClassifier.group_of(read, "p-4") == "p"
      assert ProjectClassifier.group_of(read, "border-spacing-0") == "border-spacing"
      assert ProjectClassifier.group_of(read, "w-sidebar") == "w"
      assert ProjectClassifier.group_of(read, "rounded-lg") == nil
    end

    test "--spacing after a spacing reset keeps the numeric scale", %{tmp_dir: dir} do
      read =
        theme(
          dir,
          "@theme { --spacing-*: initial; --spacing: 0.25rem; --spacing-sidebar: 15.5rem; }"
        )

      assert ProjectClassifier.group_of(read, "p-4") == "p"
      assert ProjectClassifier.group_of(read, "border-spacing-0") == "border-spacing"
      assert ProjectClassifier.group_of(read, "w-sidebar") == "w"
    end

    test "--spacing before a reset does not survive it", %{tmp_dir: dir} do
      read =
        theme(dir, "@theme { --spacing: 0.25rem; --*: initial; --spacing-sidebar: 15.5rem; }")

      assert ProjectClassifier.group_of(read, "p-4") == nil
      assert ProjectClassifier.group_of(read, "p-sidebar") == "p"
    end

    test "Tailwind's own --animate-* do not survive a reset", %{tmp_dir: dir} do
      read =
        theme(
          dir,
          ~s(@import "tailwindcss";\n@theme { --animate-*: initial; --animate-mine: x; }),
          %{
            "node_modules/tailwindcss/package.json" =>
              ~s({"name":"tailwindcss","style":"index.css"}),
            "node_modules/tailwindcss/index.css" => ~s(@theme { --animate-spin: spin 1s; })
          }
        )

      assert ProjectClassifier.group_of(read, "animate-spin") == nil
      assert ProjectClassifier.group_of(read, "animate-mine") == "animate"
    end

    @tailwind %{
      "node_modules/tailwindcss/package.json" => ~s({"name":"tailwindcss","style":"index.css"}),
      "node_modules/tailwindcss/index.css" => ~s(@import "./theme.css";),
      "node_modules/tailwindcss/theme.css" => ~s(@theme default { --animate-spin: spin 1s; })
    }

    for {name, imports} <- [
          {"theme.css", ~s(@import "tailwindcss/theme.css";)},
          {"theme", ~s(@import "tailwindcss/theme";)},
          {"index.css", ~s(@import "tailwindcss/index.css";)},
          {"theme.css after the bare import",
           ~s(@import "tailwindcss";\n@import "tailwindcss/theme.css";)},
          {"theme.css before the bare import",
           ~s(@import "tailwindcss/theme.css";\n@import "tailwindcss";)}
        ] do
      test "an explicit #{name} keeps Tailwind's --animate-* after a reset", %{tmp_dir: dir} do
        read = theme(dir, unquote(imports) <> "\n@theme { --animate-*: initial; }", @tailwind)

        assert ProjectClassifier.group_of(read, "animate-spin") == "animate"
        assert read.files == Enum.uniq(read.files)
      end
    end

    test "a bare import inside a package drops Tailwind's --animate-* too", %{tmp_dir: dir} do
      read =
        theme(
          dir,
          ~s(@import "kit";\n@theme { --animate-*: initial; }),
          Map.merge(@tailwind, %{
            "node_modules/kit/package.json" => ~s({"name":"kit","style":"kit.css"}),
            "node_modules/kit/kit.css" => ~s(@import "tailwindcss";)
          })
        )

      assert ProjectClassifier.group_of(read, "animate-spin") == nil
    end
  end

  describe "the namespaces cn does not read" do
    test "bg-* reads --background-image-*", %{tmp_dir: dir} do
      read = theme(dir, @scales)

      assert ProjectClassifier.group_of(read, "bg-stripes") == "bg-image"
      assert ProjectClassifier.group_of(read, "hover:bg-stripes/50") == "bg-image"
      assert ProjectClassifier.group_of(read, "bg-other") == "bg-color"
    end

    test "a color token of the same name wins", %{tmp_dir: dir} do
      read = theme(dir, "@theme { --background-image-stripes: none; --color-stripes: #111; }")

      assert ProjectClassifier.group_of(read, "bg-stripes") == "bg-color"
    end

    test "a scale wins over a color token of the same name, as in cn's grammar", %{tmp_dir: dir} do
      read =
        theme(dir, """
        @theme { --color-primary: #111; --text-primary: 1rem; --shadow-primary: 0 0 1px #000; }
        """)

      assert ProjectClassifier.group_of(read, "text-primary") == "font-size"
      assert ProjectClassifier.group_of(read, "shadow-primary") == "shadow"
    end
  end

  describe "memos" do
    test "an edited theme is read again in the same process", %{tmp_dir: dir} do
      before = theme(dir, "@theme { --radius-card: 8px; }")
      assert ProjectClassifier.group_of(before, "rounded-card") == "rounded"
      assert ProjectClassifier.group_of(before, "rounded-panel") == nil

      edited = theme(dir, "@theme { --radius-panel: 8px; }")
      assert edited.file == before.file
      assert ProjectClassifier.group_of(edited, "rounded-card") == nil
      assert ProjectClassifier.group_of(edited, "rounded-panel") == "rounded"

      # The older read keeps its own answers.
      assert ProjectClassifier.group_of(before, "rounded-card") == "rounded"
    end

    test "an unchanged theme keeps its signature", %{tmp_dir: dir} do
      assert theme(dir, @scales).signature == theme(dir, @scales).signature
    end

    test "an edited theme is judged again by no_raw_colors", %{tmp_dir: dir} do
      css =
        ~s(@import "tailwindcss";\n@theme { --color-primary: #111; --shadow-soft: 0 0 1px #000; })

      template = ~s(<div class="shadow-soft" />)
      rules = [no_raw_colors: :error]

      assert lint_classes(dir, css, template, rules) == []

      # shadow-soft is now an undeclared color.
      edited = ~s(@import "tailwindcss";\n@theme { --color-primary: #111; })
      assert [finding] = lint_classes(dir, edited, template, rules)
      assert finding.message =~ "not a declared theme color"
    end

    test "a theme's trie stays out of inspect", %{tmp_dir: dir} do
      read = theme(dir, @scales)

      assert is_map(Theme.grammar(read))
      refute inspect(read, limit: :infinity) =~ "isTshirtSize"
    end
  end

  describe "the rules" do
    @button ~s(<.button class="rounded-card">x</.button>)

    test "a declared radius is shape under a contract", %{tmp_dir: dir} do
      assert lint_classes(dir, @scales, @button, no_restyle: {:error, allow: ["shape"]}) == []

      assert [finding] =
               lint_classes(dir, @scales, @button, no_restyle: {:error, allow: ["layout"]})

      assert finding.message =~ "<.button> owns its shape."
    end

    test "a declared font size is typography", %{tmp_dir: dir} do
      template = ~s(<.button class="text-stat-label">x</.button>)

      assert lint_classes(dir, @scales, template, no_restyle: {:error, allow: ["typography"]}) ==
               []

      assert [finding] =
               lint_classes(dir, @scales, template, no_restyle: {:error, allow: ["layout"]})

      assert finding.message =~ "<.button> owns its typography."
    end

    test "after a radius reset, rounded-lg is reported as unrecognized", %{tmp_dir: dir} do
      css = ~s(@import "tailwindcss";\n@theme { --radius-*: initial; --radius-card: 12px; })
      template = ~s(<.button class="rounded-lg rounded-card">x</.button>)

      assert [finding] = lint_classes(dir, css, template, no_restyle: {:error, allow: ["shape"]})
      assert finding.message =~ ~s("rounded-lg")
      assert finding.message =~ "the grammar does not recognize it"
    end

    test "a declared scale is not an undeclared color", %{tmp_dir: dir} do
      template = ~s(<p class="text-stat-label md:text-stat-label shadow-card-glow bg-stripes" />)

      assert lint_classes(dir, @scales, template, no_raw_colors: :error) == []
    end

    test "after a shadow reset, shadow-lg is an undeclared color", %{tmp_dir: dir} do
      css = ~s(@import "tailwindcss";\n@theme { --color-primary: #111; --shadow-*: initial; })
      template = ~s(<div class="shadow-lg" />)

      assert [finding] = lint_classes(dir, css, template, no_raw_colors: :error)
      assert finding.message =~ "not a declared theme color"
    end

    test "--spacing after a reset keeps border-spacing-0 a spacing", %{tmp_dir: dir} do
      css = """
      @import "tailwindcss";
      @theme static { --*: initial; }
      @theme static {
        --color-primary: #111;
        --spacing: 0.25rem;
        --spacing-sidebar: 15.5rem;
      }
      """

      template = ~s(<table class="border-spacing-0 p-4 w-sidebar" />)

      assert lint_classes(dir, css, template, no_raw_colors: :error) == []
    end

    test "a contract can name a declared class", %{tmp_dir: dir} do
      template = ~s(<.button class="rounded-card rounded-lg">x</.button>)

      assert [finding] =
               lint_classes(dir, @scales, template, no_restyle: {:error, deny: ["rounded-card"]})

      assert finding.message =~ ~s("rounded-card")
    end
  end
end

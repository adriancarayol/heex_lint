defmodule HeexLint.UtilityClassesTest do
  # A class the project's CSS declares with @utility is one Tailwind
  # generates, and its body says what it changes: a utility that sets
  # min-height is layout, one that sets font-size is typography. A package
  # the theme imports counts too, so tw-animate-css's classes are motion.
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  alias HeexLint.Grammar.{Categories, Classifier, ProjectClassifier}
  alias HeexLint.Theme

  @moduletag :tmp_dir

  @package Path.expand("../fixtures/tw_animate_css", __DIR__)

  @utilities """
  @import "tailwindcss";
  @theme { --color-primary: #111; --text-stat: 2rem; --animate-mine: spin 1s; }
  @utility tap-target { min-height: 44px; }
  @utility max-w-chat { max-width: 48rem; }
  @utility heading-2xs { font-size: 0.75rem; line-height: 1rem; font-weight: 600; }
  @utility text-md-regular { font-size: 1rem; font-weight: 400; }
  @utility bg-primary { padding: 1px; }
  @utility text-stat { color: red; }
  @utility tab-* { tab-size: --value(integer); }
  @utility gutter-* { gap: --value(integer); }
  @utility paintbox { display: block; font-size: 1px; color: red; }
  @utility hover-paint { display: block; &:hover { color: red; } }
  @utility media-gap { @media (min-width: 1px) { padding: 1px; } }
  @utility shadow-tint { --tw-shadow-color: red; }
  @utility shouted { COLOR: red; }
  @utility quiet { /* color: red; */ display: grid; }
  @utility no-body { }
  @utility animate-util { animation: spin 1s; }
  /* @utility commented-out { color: red; } */
  .legacy-card { border: 1px solid var(--border); }
  """

  defp theme(dir, css, files \\ %{}) do
    for {path, contents} <- Map.put(files, "app.css", css) do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, contents)
    end

    Theme.load(Path.join(dir, "app.css"))
  end

  defp with_package(dir) do
    theme(dir, ~s(@import "tailwindcss";\n@import "tw-animate-css";\n), %{
      "node_modules/tw-animate-css/package.json" => File.read!(@package <> "/package.json"),
      "node_modules/tw-animate-css/tw-animate.css" => File.read!(@package <> "/tw-animate.css")
    })
  end

  defp restyle(dir, css, template, options) do
    lint(
      dir,
      %{"assets/css/app.css" => css, "lib/app_web/live/page_live.ex" => live(template)},
      rules: [no_restyle: {:error, options}]
    )
  end

  describe "parse_utilities" do
    test "reads the properties a body sets, nesting included" do
      assert Theme.parse_utilities("""
             @utility a { color: red; font-size: 1px; }
             @utility b-* { display: flex; &:hover { color: red; } @media (min-width: 1px) { padding: 1px; } }
             """) == [
               {"a", ["color", "font-size"]},
               {"b-*", ["display", "color", "padding"]}
             ]
    end

    test "keeps custom properties and reads no selector or prelude as a property" do
      assert Theme.parse_utilities("""
             @utility a {
               --tw-shadow-color: red;
               &:hover { --tw-enter-opacity: 0; }
               &:dir(ltr) { top: 0; }
             }
             """) == [{"a", ["--tw-shadow-color", "--tw-enter-opacity", "top"]}]
    end

    test "strips comments first, so a commented body or utility counts for nothing" do
      assert Theme.parse_utilities("""
             /* @utility gone { color: red; } */
             @utility a { /* color: red; */ display: grid; /* } */ top: 0 }
             """) == [{"a", ["display", "top"]}]
    end

    test "lowercases and de-duplicates" do
      assert Theme.parse_utilities("@utility a { COLOR: red; color: blue; Top: 0 }") ==
               [{"a", ["color", "top"]}]
    end

    test "an empty body sets nothing, and an unclosed one runs to the end" do
      assert Theme.parse_utilities("@utility a { } @utility b { color: red;") ==
               [{"a", []}, {"b", ["color"]}]
    end

    test "an unclosed body reads to its last byte" do
      assert Theme.parse_utilities("@utility a { top: 0; color:") == [{"a", ["top", "color"]}]
    end

    test "a brace in a string counts, as in @shadcn/lint" do
      assert Theme.parse_utilities("""
             @utility a { content: "{"; color: red; }
             @utility b { top: 0; }
             """) == [{"a", ["content", "color", "top"]}, {"b", ["top"]}]
    end

    test "a utility declared again takes the new body and keeps its place" do
      assert Theme.parse_utilities("""
             @utility a { color: red; }
             @utility b { top: 0; }
             @utility a { display: grid; }
             """) == [{"a", ["display"]}, {"b", ["top"]}]
    end
  end

  describe "the theme" do
    test "keeps utilities as a set of names beside their properties", %{tmp_dir: dir} do
      read = theme(dir, "@utility a { color: red; }\n@utility b-* { top: 0; }")

      assert MapSet.equal?(read.utilities, MapSet.new(["a", "b-*"]))
      assert read.utility_properties == [{"a", ["color"]}, {"b-*", ["top"]}]
    end

    test "an imported file's utility replaces the importing file's", %{tmp_dir: dir} do
      read =
        theme(
          dir,
          ~s(@import "./more.css";\n@utility a { color: red; }\n@utility b { top: 0; }),
          %{
            "more.css" => "@utility a { display: grid; }\n@utility c { left: 0; }"
          }
        )

      assert read.utility_properties ==
               [{"a", ["display"]}, {"b", ["top"]}, {"c", ["left"]}]
    end

    test "an exact name wins over a prefix", %{tmp_dir: dir} do
      read = theme(dir, "@utility tab-* { color: red; }\n@utility tab-4 { top: 0; }")

      assert Theme.utility_properties_of(read, "tab-4") == ["top"]
      assert Theme.utility_properties_of(read, "tab-5") == ["color"]
    end

    test "the first prefix declared wins, however long", %{tmp_dir: dir} do
      read =
        theme(dir, """
        @utility pri-* { color: red; }
        @utility pri-in-* { top: 0; }
        @utility sec-in-* { top: 0; }
        @utility sec-* { color: red; }
        """)

      assert Theme.utility_properties_of(read, "pri-in-4") == ["color"]
      assert Theme.utility_properties_of(read, "sec-in-4") == ["top"]
      assert Theme.utility_properties_of(read, "sec-4") == ["color"]
    end

    test "the order of prefixes holds past Elixir's small maps", %{tmp_dir: dir} do
      fillers = Enum.map_join(1..40, "\n", &"@utility filler-#{&1} { top: 0; }")

      read =
        theme(dir, """
        @utility zz-* { color: red; }
        #{fillers}
        @utility zz-in-* { top: 0; }
        """)

      assert Theme.utility_properties_of(read, "zz-in-4") == ["color"]
    end

    test "reads through variants and modifiers; nil when no @utility declares it", %{tmp_dir: dir} do
      read = theme(dir, "@utility a { color: red; }\n@utility b { }\n.c { top: 0 }")

      assert Theme.utility_properties_of(read, "hover:a/50") == ["color"]
      assert Theme.utility_properties_of(read, "b") == []
      assert Theme.utility_properties_of(read, "c") == nil
      assert Theme.declares_utility?(read, "b")
      refute Theme.declares_utility?(read, "c")
    end

    test "a commented-out @utility is not declared", %{tmp_dir: dir} do
      read = theme(dir, "/* @utility gone { color: red; } */\n.gone-not { top: 0 }")

      refute Theme.declares_utility?(read, "gone")
      refute Theme.declares_class?(read, "gone")
      assert MapSet.size(read.utilities) == 0
    end
  end

  describe "the group an @utility gives its class" do
    setup %{tmp_dir: dir} do
      %{read: theme(dir, @utilities)}
    end

    test "reads the body, not the name", %{read: read} do
      for {token, group} <- [
            {"tap-target", "arbitrary..min-height"},
            {"max-w-chat", "arbitrary..max-width"},
            {"heading-2xs", "arbitrary..font-size"},
            # text-* is a color to the grammar; the body says otherwise.
            {"text-md-regular", "arbitrary..font-size"},
            # A variant or a modifier does not change what it sets.
            {"hover:heading-2xs", "arbitrary..font-size"},
            {"text-md-regular/50", "arbitrary..font-size"},
            # A prefix utility takes the body of its @utility gutter-*.
            {"gutter-4", "arbitrary..gap"},
            # The grammar knows tab-size, and answers first.
            {"tab-4", "tab-size"},
            {"shadow-tint", "arbitrary..--tw-shadow-color"},
            {"shouted", "arbitrary..color"}
          ] do
        assert {token, ProjectClassifier.group_of(read, token)} == {token, group}
      end
    end

    test "a body that changes several things is the first appearance it carries", %{read: read} do
      assert ProjectClassifier.category_of(read, "paintbox") == "color"
      assert ProjectClassifier.category_of(read, "hover-paint") == "color"
      assert ProjectClassifier.category_of(read, "media-gap") == "spacing"
      # Equal ranks take the first declared.
      assert ProjectClassifier.group_of(read, "heading-2xs") == "arbitrary..font-size"
    end

    test "layout is what a body with nothing else leaves", %{read: read} do
      assert ProjectClassifier.group_of(read, "quiet") == "arbitrary..display"
      assert ProjectClassifier.category_of(read, "quiet") == nil
    end

    test "nothing is read from a plain selector, an empty body or a comment", %{read: read} do
      for token <- ~w(legacy-card no-body commented-out flex-cols) do
        assert {token, ProjectClassifier.group_of(read, token)} == {token, nil}
      end
    end

    test "the grammar's color yields to the theme, then the body", %{read: read} do
      # An @utility over a token the grammar calls a color.
      assert ProjectClassifier.group_of(read, "bg-primary") == "arbitrary..padding"
      # --text-stat answers before the body does.
      assert ProjectClassifier.group_of(read, "text-stat") == "font-size"
      # With nothing declaring it, the grammar's answer stands.
      assert ProjectClassifier.group_of(read, "bg-pink-500") == "bg-color"
    end

    test "a grammar answer other than a color is not read from the body", %{tmp_dir: dir} do
      read = theme(dir, "@utility mt-4 { color: red; }\n@utility rounded-x { color: red; }")

      assert ProjectClassifier.group_of(read, "mt-4") == "mt"
      assert Classifier.group_of("rounded-x") == nil
      assert ProjectClassifier.group_of(read, "rounded-x") == "arbitrary..color"
    end

    test "an animation declared in @theme or with @utility keeps the animate group", %{read: read} do
      assert ProjectClassifier.group_of(read, "animate-mine") == "animate"
      assert ProjectClassifier.group_of(read, "animate-util") == "animate"
    end

    test "no theme answers nothing" do
      assert ProjectClassifier.group_of(nil, "tap-target") == nil
      assert ProjectClassifier.group_of(%Theme{}, "tap-target") == nil
    end
  end

  describe "arbitrary property categories" do
    test "tw-animate-css's custom properties are motion" do
      for property <- ~w(--tw-enter-opacity --tw-exit-translate-y --tw-animation-duration),
          group = Categories.property_group(property) do
        assert {property, Categories.category_of(group)} == {property, "motion"}
      end
    end

    test "other custom properties keep their categories" do
      assert Categories.category_of("arbitrary..--tw-enter") == nil
      assert Categories.category_of("arbitrary..--tw-enter-color") == "color"
      assert Categories.category_of("arbitrary..--tw-duration") == "motion"
    end

    test "the grammar classifies an arbitrary property with the same group" do
      assert Classifier.group_of("[font-size:1rem]") == Categories.property_group("font-size")
    end
  end

  describe "tw-animate-css" do
    test "its classes are motion", %{tmp_dir: dir} do
      read = with_package(dir)

      for token <- ~w(
            animate-in animate-out data-[state=open]:animate-in fade-in fade-in-50 fade-out
            blur-in zoom-in-95 spin-in slide-in-from-top slide-in-from-top-1
            slide-in-from-start slide-out-to-bottom-2 animation-duration-200 repeat-2
          ) do
        assert {token, ProjectClassifier.category_of(read, token)} == {token, "motion"}
      end
    end

    test "an animation the package does not declare is still unknown", %{tmp_dir: dir} do
      read = with_package(dir)

      assert ProjectClassifier.group_of(read, "animate-wiggle") == nil
      assert ProjectClassifier.group_of(read, "slide-in-sideways") == nil
    end

    test "a package contributes only its --animate-* names from @theme", %{tmp_dir: dir} do
      read =
        theme(dir, ~s(@import "./node_modules/pkg/pkg.css";\n), %{
          "node_modules/pkg/pkg.css" => """
          @theme { --animate-wave: spin 1s; --color-brand: #f00; --text-huge: 9rem; }
          .dark { --animate-night: spin 1s; }
          :root { --animate-plain: spin 1s; }
          """
        })

      assert MapSet.equal?(read.theme_names, MapSet.new(["animate-wave"]))
      assert ProjectClassifier.group_of(read, "animate-wave") == "animate"
      # Still not the project's tokens or scales.
      assert read.tokens == MapSet.new()
      refute List.keymember?(Theme.scale(read, :text), "huge", 0)
      assert ProjectClassifier.group_of(read, "text-huge") == "text-color"
    end

    test "a project's own file is read as it always was", %{tmp_dir: dir} do
      read = theme(dir, "@theme { --animate-mine: spin 1s; --color-brand: #f00; }")

      assert MapSet.equal?(read.theme_names, MapSet.new(["animate-mine", "color-brand"]))
    end
  end

  describe "no_restyle" do
    test "allows a declared utility the contract's categories cover", %{tmp_dir: dir} do
      assert restyle(dir, @utilities, ~s(<.button class="tap-target max-w-chat">x</.button>),
               allow: ["layout"]
             ) == []

      assert restyle(dir, @utilities, ~s(<.button class="heading-2xs">x</.button>),
               allow: ["layout", "typography"]
             ) == []

      # Allowing it by name stays the way through.
      assert restyle(dir, @utilities, ~s(<.button class="heading-2xs">x</.button>),
               allow: ["layout", "heading-2xs"]
             ) == []
    end

    test "bodies a string's brace leaves open do not cost another its category", %{tmp_dir: dir} do
      braces = Enum.map_join(1..17, "\n", &~s|@utility brace-#{&1} { content: "{"; color: red; }|)

      rules =
        Enum.map_join(1..300, "\n", &".r#{&1} { margin: 1px; padding: 2px; border: 0; top: 0; }")

      css = ~s(@import "tailwindcss";\n#{braces}\n@utility paintbox { color: red; }\n#{rules})

      assert restyle(dir, css, ~s(<.button class="paintbox">x</.button>), allow: ["color"]) == []
    end

    test "reports a utility's category, in the words for that category", %{tmp_dir: dir} do
      [text, box] =
        restyle(dir, @utilities, ~s(<.button class="text-md-regular paintbox">x</.button>),
          allow: ["layout"]
        )

      assert text.message =~
               ~s("text-md-regular" is not allowed on <.button>: <.button> owns its typography. Use a variant: default, destructive, outline.)

      assert box.message =~ "<.button> owns its color."
    end

    test "a layout utility is reported as layout on a closed contract", %{tmp_dir: dir} do
      [finding] = restyle(dir, @utilities, ~s(<.button class="tap-target">x</.button>), allow: [])

      assert finding.message =~ "its contract allows no classes."
    end

    test "deny and a category contract now reach a utility", %{tmp_dir: dir} do
      [denied] =
        restyle(dir, @utilities, ~s(<.button class="heading-2xs">x</.button>),
          allow: ["layout", "typography"],
          deny: ["typography"]
        )

      assert denied.message =~ "its contract denies typography."

      # text-* was a color to the grammar; what it sets decides now.
      [not_color] =
        restyle(dir, @utilities, ~s(<.button class="text-md-regular">x</.button>),
          allow: ["layout", "color"]
        )

      assert not_color.message =~ "<.button> owns its typography."
    end

    test "still does not call a declared class a misspelling", %{tmp_dir: dir} do
      [plain, empty] =
        restyle(dir, @utilities, ~s(<.button class="legacy-card no-body">x</.button>),
          allow: ["layout"]
        )

      assert plain.message =~ "your CSS declares it, and the grammar cannot tell what it changes."
      assert empty.message =~ "your CSS declares it, and the grammar cannot tell what it changes."
    end

    test "a commented-out @utility is an unrecognized class", %{tmp_dir: dir} do
      [finding] =
        restyle(dir, @utilities, ~s(<.button class="commented-out">x</.button>),
          allow: ["layout"]
        )

      assert finding.message =~ "the grammar does not recognize it."
    end

    test "tw-animate-css's classes fall under motion", %{tmp_dir: dir} do
      classes = "animate-in fade-in slide-in-from-top-1 animation-duration-200"
      css = ~s(@import "tailwindcss";\n@import "tw-animate-css";\n)

      files = %{
        "assets/css/app.css" => css,
        "node_modules/tw-animate-css/package.json" => File.read!(@package <> "/package.json"),
        "node_modules/tw-animate-css/tw-animate.css" => File.read!(@package <> "/tw-animate.css"),
        "lib/app_web/live/page_live.ex" => live(~s(<.button class="#{classes}">x</.button>))
      }

      assert lint(dir, files, rules: [no_restyle: {:error, allow: ["layout", "motion"]}]) == []

      findings = lint(dir, files, rules: [no_restyle: {:error, allow: ["layout"]}])

      assert length(findings) == 4
      assert Enum.all?(findings, &(&1.message =~ "<.button> owns its motion."))
    end
  end

  test "a declared utility stays out of no_raw_colors", %{tmp_dir: dir} do
    findings =
      lint(
        dir,
        %{
          "assets/css/app.css" => @utilities,
          "lib/app_web/live/page_live.ex" =>
            live(~s(<div class="paintbox text-md-regular bg-primary">x</div>))
        },
        rules: [no_raw_colors: :error]
      )

    assert findings == []
  end
end

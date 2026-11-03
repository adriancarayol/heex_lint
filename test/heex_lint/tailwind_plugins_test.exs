defmodule HeexLint.TailwindPluginsTest do
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  alias HeexLint.Grammar.ProjectClassifier
  alias HeexLint.{Tailwind, Theme}

  @moduletag :tmp_dir

  @plugin """
  module.exports = function ({ addComponents }) {
    addComponents({ ".prose": { "max-width": "65ch" }, ".spacin": { color: "red" } })
  }
  """

  # A type scale from JavaScript: nothing in the CSS names text-body.
  @config """
  module.exports = {
    theme: {
      extend: {
        fontSize: { body: ["0.875rem", "1.25rem"] },
        colors: { brand: "#0f172a" },
      },
    },
  }
  """

  @theme """
  @import "tailwindcss";
  @plugin "./plugin.js";
  @config "./tailwind.config.js";

  @theme inline {
    --color-primary: #123456;
  }
  """

  @modules %{
    "assets/css/app.css" => @theme,
    "assets/css/plugin.js" => @plugin,
    "assets/css/tailwind.config.js" => @config
  }

  defp page(template) do
    Map.merge(@modules, %{"lib/app_web/live/page_live.ex" => live(template)})
  end

  defp button(classes), do: ~s|<.button class="#{classes}">x</.button>|

  # Both ways of asking Tailwind.
  defp project(:node, dir), do: {with_tailwind(dir), []}
  defp project(:standalone, dir), do: {dir, [tailwind_bin: standalone_bin()]}

  defp lint_with(way, dir, files, rules) do
    {dir, settings} = project(way, dir)
    run(dir, files, rules: rules, settings: settings)
  end

  defp found_on(result, token) do
    result.diagnostics
    |> Enum.filter(&String.starts_with?(&1.message, ~s("#{token}")))
    |> Enum.map(& &1.message)
  end

  for {way, tag} <- [node: :tailwind, standalone: :standalone] do
    describe "a contract entry, through #{way}" do
      @describetag tag
      @way way

      test "the theme's build generates is known without a word", %{tmp_dir: dir} do
        for rule <- [:no_restyle, :no_raw_colors, :no_arbitrary_values] do
          sub = Path.join(dir, Atom.to_string(rule))
          File.mkdir_p!(sub)

          result =
            lint_with(@way, sub, page(button("prose")), [
              {rule, {:error, allow: ["layout", "prose"], deny: ["prose"]}}
            ])

          refute Enum.any?(result.warnings, &(&1 =~ "Contract entry"))
        end
      end

      test "it does not generate still warns", %{tmp_dir: dir} do
        result =
          lint_with(@way, dir, page(button("prose")),
            no_restyle: {:error, allow: ["layout", "prose", "prose-undeclared"]}
          )

        assert [warning] = Enum.filter(result.warnings, &(&1 =~ "Contract entry"))
        assert warning =~ ~s("prose-undeclared")
      end

      test "in a contract is read the same", %{tmp_dir: dir} do
        result =
          lint_with(@way, dir, page(button("prose")),
            no_restyle:
              {:error,
               contracts: [
                 %{pattern: "^button$", allow: ["layout", "prose"]},
                 %{pattern: "^x$", deny: ["nope-nope"]}
               ]}
          )

        assert [warning] = Enum.filter(result.warnings, &(&1 =~ "Contract entry"))
        assert warning =~ ~s("nope-nope")
      end

      test "one slip from a category is no error when it is generated", %{tmp_dir: dir} do
        result =
          lint_with(@way, dir, page(button("spacin")),
            no_restyle: {:error, allow: ["layout", "spacin"]}
          )

        assert Enum.filter(result.diagnostics, &(&1.message =~ "Did you mean")) == []
        refute Enum.any?(result.warnings, &(&1 =~ "Contract entry"))
      end

      test "one slip from a category is an error when it is not", %{tmp_dir: dir} do
        result =
          lint_with(@way, dir, page(button("prose")),
            no_restyle: {:error, allow: ["layout", "spacig"]}
          )

        assert [finding | _] = result.diagnostics
        assert finding.message =~ ~s(Contract entry "spacig")
        assert finding.message =~ ~s(Did you mean "spacing"?)
      end

      test "still warns when the theme's build fails", %{tmp_dir: dir} do
        files =
          Map.put(
            page(button("prose")),
            "assets/css/app.css",
            ~s(@import "tailwindcss";\n@plugin "./does-not-exist.js";\n)
          )

        result =
          lint_with(@way, dir, files, no_restyle: {:error, allow: ["layout", "prose"]})

        assert Enum.any?(result.warnings, &(&1 =~ ~s(Contract entry "prose")))
        assert Enum.any?(result.warnings, &(&1 =~ "could not be built"))
      end
    end

    describe "a font size from JavaScript, through #{way}" do
      @describetag tag
      @way way

      test "is typography, not color", %{tmp_dir: dir} do
        result =
          lint_with(@way, dir, page(button("text-body md:text-body/6 font-semibold")),
            no_restyle: {:error, allow: ["layout", "typography"]}
          )

        assert found_on(result, "text-body") == []
        assert found_on(result, "md:text-body/6") == []
      end

      test "is reported as typography where that is not allowed", %{tmp_dir: dir} do
        result =
          lint_with(@way, dir, page(button("text-body")), no_restyle: {:error, allow: ["layout"]})

        assert [message] = found_on(result, "text-body")
        assert message =~ "owns its typography"
      end

      test "deny reaches it by category", %{tmp_dir: dir} do
        result =
          lint_with(@way, dir, page(button("text-body")),
            no_restyle: {:error, deny: ["typography"]}
          )

        assert [message] = found_on(result, "text-body")
        assert message =~ "its contract denies"
      end

      test "a color from the same config is still a color", %{tmp_dir: dir} do
        result =
          lint_with(@way, dir, page(button("text-brand")),
            no_restyle: {:error, allow: ["layout", "typography"]}
          )

        assert [message] = found_on(result, "text-brand")
        assert message =~ "owns its color"
      end

      test "is not a raw color", %{tmp_dir: dir} do
        result =
          lint_with(@way, dir, page(~s|<p class="text-body md:text-body/6 text-brand" />|),
            no_raw_colors: :error
          )

        assert found_on(result, "text-body") == []
        assert found_on(result, "md:text-body/6") == []
        # Tailwind's config can name a color, and that names no token of the CSS.
        assert [message] = found_on(result, "text-brand")
        assert message =~ "not a declared theme color"
      end

      test "stays a color when the theme's build fails", %{tmp_dir: dir} do
        files =
          Map.put(
            page(~s|<p class="text-body" />|),
            "assets/css/app.css",
            ~s(@import "tailwindcss";\n@plugin "./does-not-exist.js";\n@theme { --color-primary: #123; }\n)
          )

        result = lint_with(@way, dir, files, no_raw_colors: :error)

        assert [message] = found_on(result, "text-body")
        assert message =~ "not a declared theme color"
        assert Enum.any?(result.warnings, &(&1 =~ "rules use the class grammar"))
      end

      test "comes from an @plugin as well", %{tmp_dir: dir} do
        files =
          Map.merge(page(~s|<p class="text-huge" />|), %{
            "assets/css/app.css" =>
              ~s(@import "tailwindcss";\n@plugin "./sizes.js";\n@theme { --color-primary: #123; }\n),
            "assets/css/sizes.js" => """
            module.exports = function ({ addUtilities }) {
              addUtilities({ ".text-huge": { "font-size": "9rem" } })
            }
            """
          })

        result = lint_with(@way, dir, files, no_raw_colors: :error)

        assert found_on(result, "text-huge") == []
      end

      test "is read from a plugin loaded by an imported stylesheet", %{tmp_dir: dir} do
        files =
          Map.merge(page(~s|<p class="text-body" />|), %{
            "assets/css/app.css" =>
              ~s(@import "tailwindcss";\n@import "./kit.css";\n@theme { --color-primary: #123; }\n),
            "assets/css/kit.css" => ~s(@config "./tailwind.config.js";\n)
          })

        result = lint_with(@way, dir, files, no_raw_colors: :error)

        assert found_on(result, "text-body") == []
      end

      test "is read through the stylesheet Tailwind builds, for a partial theme", %{tmp_dir: dir} do
        files =
          Map.merge(page(~s|<p class="text-body" />|), %{
            "assets/css/app.css" => @theme,
            "assets/css/tokens.css" => "@theme inline { --color-primary: #123456; }\n"
          })

        {root, settings} = project(@way, dir)

        result =
          run(root, files,
            rules: [no_raw_colors: :error],
            settings: Keyword.put(settings, :theme, "assets/css/tokens.css")
          )

        assert found_on(result, "text-body") == []
      end
    end
  end

  describe "without a Tailwind to ask" do
    test "a font size stays a color and an entry warns", %{tmp_dir: dir} do
      result =
        run(dir, page(button("text-body prose")),
          rules: [no_restyle: {:error, allow: ["layout", "prose"]}, no_raw_colors: :error]
        )

      assert Enum.any?(result.warnings, &(&1 =~ ~s(Contract entry "prose")))
      assert [_, _] = found_on(result, "text-body")
    end
  end

  describe "a font size in the standalone binary's output" do
    @css """
    :root { --text-body: 1rem; }
    @layer utilities {
      .text-body {
        font-size: 0.875rem;
        line-height: var(--tw-leading, 1.25rem);
      }
      .text-body-more {
        color: red;
      }
      .text-sm\\/6 {
        font-size: var(--text-sm);
      }
      .text-brand {
        color: #0f172a;
      }
      .text-custom {
        --font-size: 1rem;
        --my-font-size: 2rem;
        line-height: 1;
      }
      .text-minified { color: red;font-size: 1px }
      .text-empty {
      }
      @media (width >= 48rem) {
        .md\\:text-body\\/6 {
          font-size: 0.875rem;
        }
      }
      .md\\:text-wrapped {
        @media (width >= 48rem) {
          font-size: 2rem;
        }
      }
      .hover\\:text-brand {
        &:hover {
          @media (hover: hover) {
            color: red;
          }
        }
      }
    }
    .after { font-size: 2px; }
    """

    test "is read from the class's own rule" do
      for class <- ~w(text-body text-sm/6 text-minified md:text-body/6 md:text-wrapped) do
        assert Tailwind.sets_font_size?(@css, class), class
      end
    end

    test "is not read from another rule or a custom property" do
      for class <-
            ~w(text-body-more text-brand text-custom text-empty hover:text-brand text-nowhere) do
        refute Tailwind.sets_font_size?(@css, class), class
      end
    end

    test "an unterminated rule ends with the output" do
      assert Tailwind.sets_font_size?(".text-a { font-size: 1px;", "text-a")
      refute Tailwind.sets_font_size?(".text-a", "text-a")
    end
  end

  describe "a theme's modules" do
    defp read(dir, css, extra \\ %{}) do
      for {path, contents} <- Map.put(extra, "app.css", css) do
        file = Path.join(dir, path)
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, contents)
      end

      Theme.load(Path.join(dir, "app.css"))
    end

    test "are an @config or an @plugin", %{tmp_dir: dir} do
      assert read(dir, ~s(@config "./a.js";\n)).modules
      assert read(dir, ~s(@plugin "./a.js";\n)).modules
      assert read(dir, ~s(@plugin\n  "./a.js";\n)).modules
    end

    test "are not in a comment, nor another at-rule", %{tmp_dir: dir} do
      refute read(dir, ~s(/* @plugin "./a.js"; */\n)).modules
      refute read(dir, ~s(@plugins "./a.js";\n)).modules
      refute read(dir, ~s(@configure x;\n)).modules
      refute read(dir, ~s(@import "tailwindcss";\n)).modules
    end

    test "count from any file the stylesheet reaches", %{tmp_dir: dir} do
      assert read(dir, ~s(@import "./kit.css";\n), %{"kit.css" => ~s(@plugin "./a.js";\n)}).modules

      assert read(dir, ~s(@import "kit/theme.css";\n), %{
               "node_modules/kit/package.json" => ~s({"name": "kit"}),
               "node_modules/kit/theme.css" => ~s(@plugin "./a.js";\n)
             }).modules
    end

    test "tell two reads apart, and do not change what else was read", %{tmp_dir: dir} do
      without = read(dir, ~s(@utility a { color: red; }\n))
      with_plugin = read(dir, ~s(@utility a { color: red; }\n@plugin "./a.js";\n))

      refute without.signature == with_plugin.signature
      assert without.utility_properties == with_plugin.utility_properties
    end

    test "are read for the stylesheet Tailwind builds", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "partial.css"), "@theme { --color-a: #123; }\n")
      read(dir, ~s(@import "tailwindcss";\n@plugin "./a.js";\n))

      assert Theme.modules_of(Path.join(dir, "app.css"))
      refute Theme.modules_of(Path.join(dir, "partial.css"))
    end
  end

  describe "the classifier's memo" do
    defmodule Counting do
      use GenServer

      def init(test), do: {:ok, test}

      def handle_call({:font_size, _entry, [token]}, _from, test) do
        send(test, {:asked, self(), token})
        {:reply, token == "text-body", test}
      end
    end

    defp counting_oracle do
      {:ok, pid} = GenServer.start_link(Counting, self())
      pid
    end

    defp module_theme(oracle) do
      %Theme{Theme.load(nil) | modules: true, oracle: {oracle, "/app.css"}, signature: 7}
    end

    test "asks once per process and per oracle" do
      oracle = counting_oracle()
      theme = module_theme(oracle)

      assert ProjectClassifier.group_of(theme, "text-body") == "font-size"
      assert ProjectClassifier.group_of(theme, "text-body") == "font-size"
      assert_received {:asked, ^oracle, "text-body"}
      refute_received {:asked, _, "text-body"}
    end

    test "a new run's oracle is asked again, since JavaScript can change between runs" do
      first = counting_oracle()
      second = counting_oracle()

      assert ProjectClassifier.group_of(module_theme(first), "text-body") == "font-size"
      assert ProjectClassifier.group_of(module_theme(second), "text-body") == "font-size"
      assert_received {:asked, ^first, "text-body"}
      assert_received {:asked, ^second, "text-body"}
    end

    test "answers the same in another process" do
      theme = module_theme(counting_oracle())

      assert ProjectClassifier.group_of(theme, "text-body") == "font-size"

      assert Task.await(Task.async(fn -> ProjectClassifier.group_of(theme, "text-body") end)) ==
               "font-size"

      assert Task.await(Task.async(fn -> ProjectClassifier.group_of(theme, "text-brand") end)) ==
               "text-color"
    end

    test "only text classes the grammar reads as colors are asked about" do
      oracle = counting_oracle()
      theme = module_theme(oracle)

      assert ProjectClassifier.group_of(theme, "bg-brand") == "bg-color"
      assert ProjectClassifier.group_of(theme, "text-sm") == "font-size"
      assert ProjectClassifier.group_of(theme, "flex") == "display"
      refute_received {:asked, _, _}

      assert ProjectClassifier.group_of(theme, "md:text-brand/50") == "text-color"
      assert_received {:asked, ^oracle, "md:text-brand/50"}
    end

    test "a stopped oracle leaves it a color" do
      oracle = counting_oracle()
      theme = module_theme(oracle)
      GenServer.stop(oracle)

      assert ProjectClassifier.group_of(theme, "text-body") == "text-color"
    end

    test "a theme without modules has no oracle to ask" do
      assert ProjectClassifier.group_of(Theme.load(nil), "text-body") == "text-color"
    end
  end
end

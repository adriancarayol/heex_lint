defmodule HeexLint.ThemeImportsTest do
  # A design system published as a package ships its @theme in its own CSS,
  # which the app imports. Files under node_modules contribute no tokens by
  # default, so once the app declares one color of its own, every kit color reads
  # as undeclared. The theme_imports setting names the imports whose package is
  # the project's own theme.
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  alias HeexLint.{Config, Project, Theme}

  @moduletag :tmp_dir

  @app """
  @import "tailwindcss";
  /* The design system ships its tokens as a package. */
  @import "acme-ui/theme.css";

  /* One color of the app's own. */
  @theme inline {
    --color-spotlight: oklch(0.92 0 0);
  }
  """

  @kit_theme """
  /* A kit that imports Tailwind itself: its palette is still not a token. */
  @import "tailwindcss";
  @import "./brand.css";

  @theme inline {
    --color-primary: var(--primary);
    --color-muted: var(--muted);
    --text-kicker: 0.6875rem;
    --shadow-lift: 0 4px 12px rgb(0 0 0 / 0.1);
    --radius-kit: 7px;
  }

  :root {
    --primary: oklch(0.205 0 0);
    --muted: oklch(0.97 0 0);
  }

  .dark {
    --primary: oklch(0.9 0 0);
  }

  @utility kit-stack {
    display: flex;
    gap: 1rem;
  }
  """

  @kit %{
    "node_modules/acme-ui/package.json" =>
      ~s({"name":"acme-ui","exports":{"./theme.css":"./styles/theme.css","./raw.css":"./styles/raw.css"}}),
    "node_modules/acme-ui/styles/theme.css" => @kit_theme,
    "node_modules/acme-ui/styles/brand.css" => "@theme { --color-brand: oklch(0.6 0.2 260); }\n"
  }

  # Tailwind's package, with a palette that must not leak.
  @tailwind %{
    "node_modules/tailwindcss/package.json" => ~s({"name":"tailwindcss"}),
    "node_modules/tailwindcss/index.css" => ~s(@import "./theme.css";\n),
    "node_modules/tailwindcss/theme.css" =>
      "@theme { --color-red-500: oklch(0.6 0.2 25); --animate-spin: spin 1s; }\n"
  }

  defp write(dir, files) do
    for {path, contents} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))

      case contents do
        {:link, target} -> File.ln_s!(target, full)
        css -> File.write!(full, css)
      end
    end

    dir
  end

  defp package(name, css),
    do: %{
      "node_modules/#{name}/package.json" => ~s({"name":"#{name}"}),
      "node_modules/#{name}/index.css" => css
    }

  defp color(name), do: "@theme { --color-#{name}: #123456; }\n"

  defp load(dir, files, patterns \\ []) do
    write(dir, Map.merge(%{"app.css" => @app}, Map.merge(@tailwind, @kit)) |> Map.merge(files))
    Theme.load(Path.join(dir, "app.css"), patterns)
  end

  defp tokens(theme), do: theme.tokens |> MapSet.to_list() |> Enum.sort()

  describe "Theme.load/2" do
    test "without theme_imports, a package's tokens do not count", %{tmp_dir: dir} do
      assert tokens(load(dir, %{})) == ["spotlight"]
    end

    test "a string or a Regex names the import, and files from within it count too", %{
      tmp_dir: dir
    } do
      all = ["brand", "muted", "primary", "spotlight"]

      assert tokens(load(dir, %{}, ["^acme-ui/"])) == all
      assert tokens(Theme.load(Path.join(dir, "app.css"), [~r/^acme-ui\//])) == all
    end

    test "any one pattern is enough, and an invalid string is skipped", %{tmp_dir: dir} do
      assert "primary" in tokens(load(dir, %{}, ["^nothing", "acme-ui/theme"]))

      assert "primary" in tokens(
               Theme.load(Path.join(dir, "app.css"), ["^acme-ui/(", "^acme-ui/"])
             )

      assert tokens(Theme.load(Path.join(dir, "app.css"), ["^acme-ui/("])) == ["spotlight"]
    end

    test "a pattern reads the import as written, not where it resolves", %{tmp_dir: dir} do
      assert tokens(load(dir, %{}, ["^other-ui/"])) == ["spotlight"]
      assert tokens(Theme.load(Path.join(dir, "app.css"), ["styles/theme"])) == ["spotlight"]

      relative = %{"app.css" => ~s(@import "./node_modules/acme-ui/styles/theme.css";\n)}
      assert tokens(load(dir, relative, ["^acme-ui/"])) == []
      assert "primary" in tokens(load(dir, relative, ["node_modules/acme-ui"]))
    end

    test "the kit's values, scales and utilities are read like the project's", %{tmp_dir: dir} do
      theme = load(dir, %{}, ["^acme-ui/"])

      assert %{"primary" => _, "brand" => _, "spotlight" => _} = theme.colors
      assert {"kit", 7.0} in Theme.scale(theme, :radius)
      assert {"kicker", 11.0} in Theme.scale(theme, :text)
      assert theme.grammar != nil
      assert MapSet.member?(theme.theme_names, "shadow-lift")
      assert Theme.utility_properties_of(theme, "kit-stack") == ["display", "gap"]

      # Without the setting the utility is still known, and the rest is not.
      plain = load(dir, %{})
      assert Theme.utility_properties_of(plain, "kit-stack") == ["display", "gap"]
      refute List.keymember?(Theme.scale(plain, :radius), "kit", 0)
      assert Map.keys(plain.colors) == ["spotlight"]
    end

    test "dark blocks of a kit stay skipped", %{tmp_dir: dir} do
      assert load(dir, %{}, ["^acme-ui/"]).values["primary"] == "oklch(0.205 0 0)"
    end

    test "a kit's resets and --spacing apply, in cascade order", %{tmp_dir: dir} do
      reset = %{
        "node_modules/acme-ui/styles/theme.css" => """
        @import "./brand.css";
        @theme { --color-*: initial; --color-kept: #111; --radius-*: initial; --spacing: 0.5rem; }
        """
      }

      theme = load(dir, reset, ["^acme-ui/"])
      assert tokens(theme) == ["kept", "spotlight"]
      assert Theme.scale(theme, :radius) == []
      assert theme.spacing == 8.0

      # Nothing a package resets reaches the project's theme without the setting.
      plain = load(dir, reset)
      assert List.keymember?(Theme.scale(plain, :radius), "lg", 0)
      assert plain.spacing == 4.0
    end

    test "the importing file's own declarations come after the kit's", %{tmp_dir: dir} do
      app = %{
        "app.css" => """
        @import "acme-ui/theme.css";
        @theme { --color-*: initial; --color-mine: #111; --primary: #222; }
        """
      }

      assert tokens(load(dir, app, ["^acme-ui/"])) == ["mine"]
    end

    test "the kit's own bare Tailwind import stays out", %{tmp_dir: dir} do
      theme = load(dir, %{}, ["^acme-ui/"])

      refute "red-500" in tokens(theme)
      assert theme.tailwind
    end

    test "no pattern brings the palette in through a bare Tailwind import", %{tmp_dir: dir} do
      # `.` and `theme` both match the `./theme.css` this stub's index.css imports,
      # and @shadcn/lint's bare import never reads that file. Tailwind 4.3's own
      # index.css inlines its parts, so this guards the shape, not today's package.
      for pattern <- [".", "theme", "tailwindcss"] do
        refute "red-500" in tokens(load(dir, %{}, [pattern]))
      end

      refute MapSet.member?(load(dir, %{}, ["."]).theme_names, "animate-spin")
    end

    test "Tailwind's stylesheet by path stays out unless it is named", %{tmp_dir: dir} do
      by_path = %{"app.css" => ~s(@import "tailwindcss/theme.css";\n)}
      refute "red-500" in tokens(load(dir, by_path))
      assert "red-500" in tokens(load(dir, by_path, ["^tailwindcss/theme"]))

      from_kit = %{
        "node_modules/acme-ui/styles/theme.css" => ~s(@import "tailwindcss/theme.css";\n)
      }

      refute "red-500" in tokens(load(dir, from_kit, ["^acme-ui/"]))
    end

    test "naming Tailwind's index by path owns what it imports", %{tmp_dir: dir} do
      by_path = %{"app.css" => ~s(@import "tailwindcss/index.css";\n)}
      assert "red-500" in tokens(load(dir, by_path, ["^tailwindcss/index"]))
    end

    test "another package a kit imports stays out until it is named", %{tmp_dir: dir} do
      files =
        Map.merge(package("other-kit", color("other")), %{
          "node_modules/acme-ui/styles/theme.css" => ~s(@import "other-kit";\n) <> color("kit")
        })

      assert tokens(load(dir, files, ["^acme-ui/"])) == ["kit", "spotlight"]
      assert "other" in tokens(load(dir, files, ["^acme-ui/", "^other-kit"]))
    end

    test "a scope is part of the package's name", %{tmp_dir: dir} do
      files = %{
        "app.css" => ~s(@import "@acme/ui/theme.css";\n),
        "node_modules/@acme/ui/package.json" => ~s({"name":"@acme/ui"}),
        "node_modules/@acme/ui/theme.css" => """
        @import "./brand.css";
        @import "@acme/other/x.css";
        #{color("kit")}
        """,
        "node_modules/@acme/ui/brand.css" => color("brand"),
        "node_modules/@acme/other/package.json" => ~s({"name":"@acme/other"}),
        "node_modules/@acme/other/x.css" => color("other")
      }

      assert tokens(load(dir, files, ["^@acme/ui/"])) == ["brand", "kit"]
      assert tokens(load(dir, files, ["^@acme/"])) == ["brand", "kit", "other"]
    end

    test "a package installed inside the kit is another package", %{tmp_dir: dir} do
      files = %{
        "node_modules/acme-ui/styles/theme.css" => """
        @import "nested-kit/x.css";
        @import "./brand.css";
        """,
        "node_modules/acme-ui/node_modules/nested-kit/package.json" => ~s({"name":"nested-kit"}),
        "node_modules/acme-ui/node_modules/nested-kit/x.css" => color("nested")
      }

      assert tokens(load(dir, files, ["^acme-ui/"])) == ["brand", "spotlight"]
    end

    test "under pnpm the package is what follows the last node_modules", %{tmp_dir: dir} do
      store = "node_modules/.pnpm/@acme+ui@1.0.0/node_modules/@acme/ui"

      files = %{
        "app.css" => ~s(@import "@acme/ui/theme.css";\n),
        "#{store}/package.json" => ~s({"name":"@acme/ui"}),
        "#{store}/theme.css" => ~s(@import "./brand.css";\n) <> color("kit"),
        "#{store}/brand.css" => color("brand"),
        "node_modules/@acme/ui" => {:link, "../.pnpm/@acme+ui@1.0.0/node_modules/@acme/ui"}
      }

      assert tokens(load(dir, files)) == []
      assert tokens(Theme.load(Path.join(dir, "app.css"), ["^@acme/ui/"])) == ["brand", "kit"]
    end

    test "a stylesheet directly under node_modules is a package of its own", %{tmp_dir: dir} do
      files = %{
        "sub/app.css" => ~s(@import "../node_modules/loose.css";\n),
        "node_modules/loose.css" => ~s(@import "./sibling.css";\n) <> color("loose"),
        "node_modules/sibling.css" => color("sibling")
      }

      write(dir, files)
      theme = Theme.load(Path.join(dir, "sub/app.css"), ["loose"])
      assert tokens(theme) == ["loose"]
    end

    test "an unnamed package reaching a named one counts the named one", %{tmp_dir: dir} do
      files =
        Map.merge(
          package("wrapper-kit", ~s(@import "acme-ui/theme.css";\n) <> color("wrapper")),
          %{
            "app.css" => ~s(@import "wrapper-kit";\n)
          }
        )

      assert tokens(load(dir, files, ["^acme-ui/"])) == ["brand", "muted", "primary"]
    end

    test "walking through another package forgets the owned one", %{tmp_dir: dir} do
      files =
        Map.merge(package("back-kit", ~s(@import "acme-ui/raw.css";\n)), %{
          "node_modules/acme-ui/styles/theme.css" => ~s(@import "back-kit";\n) <> color("kit"),
          "node_modules/acme-ui/styles/raw.css" => color("raw")
        })

      assert tokens(load(dir, files, ["^acme-ui/theme"])) == ["kit", "spotlight"]
    end

    test "the first read of a file decides how it counts", %{tmp_dir: dir} do
      files = %{
        "app.css" => """
        @import "acme-ui/raw.css";
        @import "acme-ui/theme.css";
        """,
        "node_modules/acme-ui/styles/raw.css" => ~s(@import "./brand.css";\n) <> color("raw")
      }

      assert tokens(load(dir, files, ["^acme-ui/theme"])) == ["muted", "primary"]
    end

    test "a file outside node_modules counts whoever imports it", %{tmp_dir: dir} do
      files = %{
        "shared.css" => color("shared"),
        "node_modules/acme-ui/styles/theme.css" => ~s(@import "../../../shared.css";\n)
      }

      # Under a named kit, as with any import of the project's own files.
      assert tokens(load(dir, files, ["^acme-ui/"])) == ["shared", "spotlight"]
      # Under a package's walk it is read as the package's, as before.
      assert tokens(load(dir, files)) == ["spotlight"]
    end

    test "a pattern that matches a project file changes nothing", %{tmp_dir: dir} do
      files = %{"app.css" => ~s(@import "./tokens.css";\n), "tokens.css" => color("mine")}

      plain = load(dir, files)
      named = Theme.load(Path.join(dir, "app.css"), ["tokens"])

      assert tokens(named) == ["mine"]
      assert Theme.signature(named) == Theme.signature(plain)
    end

    test "a workspace package counts with or without the setting", %{tmp_dir: dir} do
      files = %{
        "app.css" => ~s(@import "ws-kit/theme.css";\n),
        "packages/ws-kit/package.json" => ~s({"name":"ws-kit"}),
        "packages/ws-kit/theme.css" => color("ws"),
        "node_modules/ws-kit" => {:link, "../packages/ws-kit"}
      }

      assert tokens(load(dir, files)) == ["ws"]
      assert tokens(Theme.load(Path.join(dir, "app.css"), ["^ws-kit/"])) == ["ws"]
    end

    test "a named package a workspace package imports counts", %{tmp_dir: dir} do
      files = %{
        "app.css" => ~s(@import "ws-kit/theme.css";\n),
        "packages/ws-kit/package.json" => ~s({"name":"ws-kit"}),
        "packages/ws-kit/theme.css" => ~s(@import "acme-ui/theme.css";\n),
        "node_modules/ws-kit" => {:link, "../packages/ws-kit"}
      }

      assert tokens(load(dir, files)) == []

      assert tokens(Theme.load(Path.join(dir, "app.css"), ["^acme-ui/"])) ==
               ["brand", "muted", "primary"]
    end

    test "an unnamed package still contributes only its animations", %{tmp_dir: dir} do
      files = %{
        "node_modules/acme-ui/styles/theme.css" =>
          "@theme { --animate-kit: spin 1s; --shadow-kit: none; --color-kit: #111; }\n"
      }

      plain = load(dir, files)
      assert MapSet.member?(plain.theme_names, "animate-kit")
      refute MapSet.member?(plain.theme_names, "shadow-kit")

      named = Theme.load(Path.join(dir, "app.css"), ["^acme-ui/"])
      assert MapSet.member?(named.theme_names, "animate-kit")
      assert MapSet.member?(named.theme_names, "shadow-kit")
    end

    test "a missing import inside a kit is noted and the rest read", %{tmp_dir: dir} do
      files = %{
        "node_modules/acme-ui/styles/theme.css" =>
          ~s(@import "./gone.css";\n@import "./brand.css";\n)
      }

      theme = load(dir, files, ["^acme-ui/"])
      assert "./gone.css" in theme.missing_imports
      assert "brand" in tokens(theme)
    end

    test "an import cycle with fan-out inside a kit ends", %{tmp_dir: dir} do
      cycle =
        for {name, a, b} <- [{"a", "b", "c"}, {"b", "c", "a"}, {"c", "a", "b"}], into: %{} do
          {"node_modules/acme-ui/styles/#{name}.css",
           ~s(@import "./#{a}.css";\n@import "./#{b}.css";\n) <> color(name)}
        end

      files = Map.merge(cycle, %{"app.css" => ~s(@import "acme-ui/styles/a.css";\n)})

      assert tokens(load(dir, files, ["^acme-ui/"])) == ["a", "b", "c"]
    end

    test "the signature tells the two reads apart", %{tmp_dir: dir} do
      plain = load(dir, %{})
      named = Theme.load(Path.join(dir, "app.css"), ["^acme-ui/"])

      refute Theme.signature(plain) == Theme.signature(named)

      assert Theme.signature(named) ==
               Theme.signature(Theme.load(Path.join(dir, "app.css"), ["^acme-ui/"]))
    end

    test "a read with no file is empty whatever the patterns", %{} do
      assert Theme.load(nil, ["^acme-ui/"]) == Theme.load(nil)
    end
  end

  describe "Theme.compile_imports/1" do
    test "takes a value or a list, and sets invalid strings apart" do
      regex = ~r/^b/

      assert {[], []} = Theme.compile_imports(nil)
      assert {[], []} = Theme.compile_imports([])
      assert {[%Regex{source: "^a"}], []} = Theme.compile_imports("^a")
      assert {[^regex], []} = Theme.compile_imports(regex)

      assert {[%Regex{source: "^a"}, ^regex], ["("]} =
               Theme.compile_imports(["^a", "(", regex])
    end
  end

  describe "Theme.discover/2" do
    test "a named kit's tokens decide which stylesheet wins", %{tmp_dir: dir} do
      write(
        dir,
        Map.merge(@kit, %{
          "a/app.css" => ~s(@import "tailwindcss/theme.css";\n) <> color("one") <> color("two"),
          "b/app.css" => ~s(@import "tailwindcss/theme.css";\n@import "acme-ui/theme.css";\n)
        })
      )

      assert Theme.discover(dir) == Path.join(dir, "a/app.css")
      assert Theme.discover(dir, ["^acme-ui/"]) == Path.join(dir, "b/app.css")
    end
  end

  describe "a stylesheet from a Hex package" do
    test "under deps/ by relative path, it counts without the setting", %{tmp_dir: dir} do
      write(dir, %{
        "assets/css/app.css" => ~s(@import "../../deps/my_kit/priv/static/theme.css";\n),
        "deps/my_kit/priv/static/theme.css" => ~s(@import "./brand.css";\n) <> color("kit"),
        "deps/my_kit/priv/static/brand.css" => color("brand")
      })

      assert tokens(Theme.load(Path.join(dir, "assets/css/app.css"))) == ["brand", "kit"]
    end

    test "linked into node_modules from deps/, it counts without the setting", %{tmp_dir: dir} do
      write(dir, %{
        "assets/css/app.css" => ~s(@import "my_kit/theme.css";\n),
        "deps/my_kit/package.json" => ~s({"name":"my_kit"}),
        "deps/my_kit/theme.css" => color("kit"),
        "assets/node_modules/my_kit" => {:link, "../../deps/my_kit"}
      })

      assert tokens(Theme.load(Path.join(dir, "assets/css/app.css"))) == ["kit"]
    end
  end

  describe "Config" do
    test "takes a string, a Regex or a list of them" do
      regex = ~r/^acme/

      assert Config.new(settings: [theme_imports: "^acme"]).settings.theme_imports == ["^acme"]
      assert Config.new(settings: [theme_imports: regex]).settings.theme_imports == [regex]

      assert Config.new(settings: [theme_imports: ["^acme", regex]]).settings.theme_imports ==
               ["^acme", regex]

      assert Config.new(settings: [theme_imports: regex]).warnings == []
    end

    test "a value of the wrong type warns and is ignored" do
      config = Config.new(settings: [theme_imports: [1]])

      refute Map.has_key?(config.settings, :theme_imports)

      assert ["settings.theme_imports must be a string or a list of strings" <> _] =
               config.warnings
    end

    test "is a setting only, not a rule option" do
      config = Config.new(settings: [theme_imports: ["^acme"]], rules: [])

      refute Map.has_key?(Config.recognition(config, []), :theme_imports)
      refute Map.has_key?(Config.recognition(config, theme_imports: ["^x"]), :theme_imports)
    end
  end

  # The kit's own Tailwind import resolves to the real package, so these go
  # through the real build. The whole of node_modules cannot be a link here, as
  # with_tailwind/1 makes it: the kit is written into it.
  defp link_tailwind(dir) do
    source = Path.expand("../fixtures/node/node_modules", __DIR__)
    target = Path.join(dir, "node_modules")
    File.mkdir_p!(target)

    for entry <- File.ls!(source), not String.starts_with?(entry, ".") do
      File.ln_s!(Path.join(source, entry), Path.join(target, entry))
    end

    dir
  end

  defp page(dir, classes, rules, settings \\ [], extra \\ %{}) do
    run(
      dir,
      Map.merge(@kit, %{
        "assets/css/app.css" => @app,
        "lib/app_web/live/page_live.ex" => live(~s(<div class="#{classes}" />))
      })
      |> Map.merge(extra),
      rules: rules,
      settings: settings
    )
  end

  defp on_page(result),
    do: Enum.filter(result.diagnostics, &String.ends_with?(&1.file, "page_live.ex"))

  @named [theme_imports: ["^acme-ui/"]]

  describe "no_raw_colors with a theme from a package" do
    setup %{tmp_dir: dir}, do: %{dir: link_tailwind(dir)}

    test "without theme_imports, the kit's colors are undeclared", %{dir: dir} do
      assert [finding] =
               dir
               |> page("text-spotlight ring-primary/60", no_raw_colors: :error)
               |> on_page()

      assert finding.message ==
               ~s("ring-primary/60" is not a declared theme color. Use one of: spotlight. ) <>
                 "To add a color, declare --color-<name> in assets/css/app.css first."
    end

    test "with theme_imports, the kit's colors are the project's own", %{dir: dir} do
      assert dir
             |> page(
               "bg-primary ring-primary/60 text-muted border-brand text-spotlight",
               [no_raw_colors: :error],
               @named
             )
             |> on_page() == []
    end

    test "the palette is still raw, and the kit's colors are now suggestions", %{dir: dir} do
      assert [finding] = dir |> page("bg-zinc-100", [no_raw_colors: :error], @named) |> on_page()

      assert finding.message =~ "Nearest theme tokens: bg-muted, bg-spotlight."
      assert [%{replacement: "bg-muted"}, %{replacement: "bg-spotlight"}] = finding.suggestions

      assert [%{message: "brand, muted, primary, spotlight"}] =
               dir
               |> page("bg-zinc-100", [no_raw_colors: {:error, message: "{{tokens}}"}], @named)
               |> on_page()
    end

    test "a color nobody declares is still undeclared", %{dir: dir} do
      assert [finding] = dir |> page("bg-highlight", [no_raw_colors: :error], @named) |> on_page()

      assert finding.message =~
               "is not a declared theme color. Use one of: brand, muted, primary, spotlight."
    end

    test "a pattern that names another import changes nothing", %{dir: dir} do
      assert [finding] =
               dir
               |> page("bg-primary", [no_raw_colors: :error], theme_imports: ["^other-ui/"])
               |> on_page()

      assert finding.message =~ "Use one of: spotlight."
    end

    test "the kit's scales are not colors", %{dir: dir} do
      assert dir
             |> page("text-kicker shadow-lift", [no_raw_colors: :error], @named)
             |> on_page() == []

      assert [_, _] =
               dir
               |> page("text-kicker shadow-lift", no_raw_colors: :error)
               |> on_page()
    end

    test "an invalid pattern warns once and is ignored", %{dir: dir} do
      result =
        page(dir, "bg-primary bg-highlight", [no_raw_colors: :error],
          theme_imports: ["^acme-ui/(", "^acme-ui/", "^acme-ui/("]
        )

      assert [finding] = on_page(result)
      assert finding.message =~ ~s("bg-highlight")

      assert "settings.theme_imports has an invalid pattern, ^acme-ui/(; it is ignored." in result.warnings

      assert Enum.count(result.warnings, &(&1 =~ "invalid pattern")) == 1
    end

    test "a rule's own theme_imports option does nothing", %{dir: dir} do
      assert [_] =
               dir
               |> page("bg-primary", no_raw_colors: {:error, theme_imports: ["^acme-ui/"]})
               |> on_page()
    end
  end

  describe "other rules with a theme from a package" do
    setup %{tmp_dir: dir}, do: %{dir: link_tailwind(dir)}

    test "no_restyle reads the kit's scales", %{dir: dir} do
      card = %{
        "lib/app_web/live/page_live.ex" => live(~s(<.card class="rounded-kit" />))
      }

      assert [finding] =
               dir
               |> page("", [no_restyle: {:error, allow: ["layout"]}], @named, card)
               |> on_page()

      assert finding.message =~ "owns its shape"

      assert [finding] =
               dir
               |> page("", [no_restyle: {:error, allow: ["layout"]}], [], card)
               |> on_page()

      assert finding.message =~ "does not recognize"
    end

    test "no_arbitrary_values suggests the kit's steps", %{dir: dir} do
      assert [finding] =
               dir
               |> page("rounded-[7px]", [no_arbitrary_values: :error], @named)
               |> on_page()

      assert [%{replacement: "rounded-kit"}] = finding.suggestions
    end

    test "no_unknown_classes asks a build that has the kit", %{dir: dir} do
      assert [finding] =
               dir
               |> page(
                 "rounded-kit shadow-lift kit-stack flex nope",
                 [no_unknown_classes: :error],
                 @named
               )
               |> on_page()

      assert finding.message =~ ~s("nope")
    end
  end

  # The binary carries Tailwind, so nothing needs linking.
  describe "the standalone Tailwind binary" do
    test "reads a named kit the same way", %{tmp_dir: dir} do
      result =
        page(
          dir,
          "bg-primary text-muted kit-stack bg-highlight",
          [no_unknown_classes: :error, no_raw_colors: :error],
          tailwind_bin: standalone_bin(),
          theme_imports: ["^acme-ui/"]
        )

      assert ["bg-highlight"] =
               result
               |> on_page()
               |> Enum.map(&hd(Regex.run(~r/"([^"]+)"/, &1.message, capture: :all_but_first)))
               |> Enum.uniq()
    end
  end

  describe "Project" do
    defp project(dir, settings), do: Project.load(dir, [], settings)

    test "reads the setting for a discovered theme", %{tmp_dir: dir} do
      write(dir, Map.merge(@kit, %{"assets/css/app.css" => @app}))

      assert tokens(project(dir, []).theme) == ["spotlight"]
      assert "primary" in tokens(project(dir, @named).theme)
    end

    test "and in which stylesheet it discovers", %{tmp_dir: dir} do
      write(
        dir,
        Map.merge(@kit, %{
          "a/app.css" => ~s(@import "tailwindcss/theme.css";\n) <> color("one") <> color("two"),
          "b/app.css" => ~s(@import "tailwindcss/theme.css";\n@import "acme-ui/theme.css";\n)
        })
      )

      assert project(dir, []).theme_file == Path.join(dir, "a/app.css")
      assert project(dir, @named).theme_file == Path.join(dir, "b/app.css")
    end

    test "and for a configured one", %{tmp_dir: dir} do
      write(dir, Map.merge(@kit, %{"theme/kit.css" => @app}))

      assert "primary" in tokens(project(dir, Keyword.put(@named, :theme, "theme/kit.css")).theme)
    end

    test "and when the configured path is wrong, in what it falls back to", %{tmp_dir: dir} do
      write(
        dir,
        Map.merge(@kit, %{
          "a/app.css" => ~s(@import "tailwindcss/theme.css";\n) <> color("one"),
          "b/app.css" => ~s(@import "tailwindcss/theme.css";\n@import "acme-ui/theme.css";\n)
        })
      )

      found = project(dir, Keyword.put(@named, :theme, "gone.css"))

      assert found.theme_file == Path.join(dir, "b/app.css")
      assert "primary" in tokens(found.theme)
      assert [warning] = found.warnings
      assert warning =~ "Using b/app.css"
    end

    test "and in the entry a partial theme asks Tailwind through", %{tmp_dir: dir} do
      write(
        dir,
        Map.merge(@kit, %{
          "a/app.css" => ~s(@import "tailwindcss/theme.css";\n) <> color("one"),
          "b/app.css" => ~s(@import "tailwindcss/theme.css";\n@import "acme-ui/theme.css";\n),
          "partial.css" => color("mine")
        })
      )

      assert project(dir, theme: "partial.css").entry == Path.join(dir, "a/app.css")

      assert project(dir, Keyword.put(@named, :theme, "partial.css")).entry ==
               Path.join(dir, "b/app.css")
    end

    test "a prefix a named kit declares is not the project's, as in @shadcn/lint", %{tmp_dir: dir} do
      write(
        dir,
        Map.merge(@kit, %{
          "assets/css/app.css" => ~s(@import "acme-ui/theme.css";\n),
          "node_modules/acme-ui/styles/theme.css" => ~s|@import "tailwindcss" prefix(tw);\n|
        })
      )

      named = project(dir, @named)

      assert named.theme.prefix == "tw"
      assert named.tailwind_prefix == nil
    end

    test "the project's own prefix still counts beside a named kit", %{tmp_dir: dir} do
      write(
        dir,
        Map.merge(@kit, %{
          "assets/css/app.css" =>
            ~s|@import "tailwindcss" prefix(tw);\n@import "acme-ui/theme.css";\n|
        })
      )

      assert project(dir, @named).tailwind_prefix == "tw"
    end

    test "an invalid pattern warns once, loaded without a Config", %{tmp_dir: dir} do
      write(dir, Map.merge(@kit, %{"assets/css/app.css" => @app}))

      found = project(dir, theme_imports: ["(", "(", "^acme-ui/"])

      assert found.warnings == [
               "settings.theme_imports has an invalid pattern, (; it is ignored."
             ]

      assert "primary" in tokens(found.theme)
    end

    test "each app of an umbrella reads its own kit", %{tmp_dir: dir} do
      kit = fn app, token ->
        %{
          "apps/#{app}/mix.exs" => "",
          "apps/#{app}/assets/css/app.css" =>
            ~s(@import "acme-ui/theme.css";\n@import "tailwindcss/theme.css";\n),
          "apps/#{app}/assets/node_modules/acme-ui/package.json" => ~s({"name":"acme-ui"}),
          "apps/#{app}/assets/node_modules/acme-ui/theme.css" => color(token)
        }
      end

      files =
        Map.merge(kit.("web", "web-kit"), kit.("admin", "admin-kit"))
        |> Map.merge(%{"mix.exs" => ""})

      write(dir, files)

      web = Path.join(dir, "apps/web/lib/page.ex")
      admin = Path.join(dir, "apps/admin/lib/page.ex")

      for file <- [web, admin] do
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, "defmodule Page do\nend\n")
      end

      found = Project.load(dir, [web, admin], theme_imports: ["^acme-ui"])

      assert tokens(Project.for_file(found, web).theme) == ["web-kit"]
      assert tokens(Project.for_file(found, admin).theme) == ["admin-kit"]

      plain = Project.load(dir, [web, admin], [])
      assert tokens(Project.for_file(plain, web).theme) == []
    end
  end
end

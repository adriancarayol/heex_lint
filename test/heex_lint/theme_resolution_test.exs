defmodule HeexLint.ThemeResolutionTest do
  # Which file a package @import reaches decides whose tokens count. These follow
  # the resolver @shadcn/lint's theme read uses, checked against its built rules.
  # That is not Tailwind's own: Tailwind prefers a style condition, and several rows
  # here read another file than it builds.
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  alias HeexLint.Theme

  @moduletag :tmp_dir

  defp write(dir, files) do
    for {path, contents} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, contents)
    end

    dir
  end

  defp color(name), do: "@theme { --color-#{name}: #123456; }\n"

  defp kit(files, name \\ "kit") do
    Map.new(files, fn {path, contents} ->
      {"node_modules/#{name}/#{path}",
       if(is_map(contents), do: JSON.encode!(contents), else: contents)}
    end)
  end

  # The tokens `specifier` contributes, with the package named by `theme_imports`.
  defp tokens(dir, specifier, files) do
    write(dir, Map.put(files, "app.css", ~s(@import "#{specifier}";\n)))

    Path.join(dir, "app.css")
    |> Theme.load([~r/^kit|^@acme|^\.hidden|^dep/])
    |> Map.fetch!(:tokens)
    |> Enum.sort()
  end

  describe "exports conditions" do
    for {name, specifier, exports, files, expected} <- [
          {"import reads before style, even a script", "kit",
           %{"." => %{"style" => "./s.css", "import" => "./i.js"}},
           %{"s.css" => "s", "i.js" => :script}, []},
          {"default reads before style, bare", "kit",
           %{"." => %{"style" => "./s.css", "default" => "./d.css"}},
           %{"s.css" => "s", "d.css" => "d"}, ["d"]},
          {"default reads before style, on a subpath", "kit/theme",
           %{"./theme" => %{"style" => "./s.css", "default" => "./d.css"}},
           %{"s.css" => "s", "d.css" => "d"}, ["d"]},
          {"import reads before style, on a subpath", "kit/theme.css",
           %{"./theme.css" => %{"style" => "./s.css", "import" => "./a.css"}},
           %{"s.css" => "s", "a.css" => "a"}, ["a"]},
          {"import reads before default", "kit/theme.css",
           %{"./theme.css" => %{"import" => "./a.css", "default" => "./d.css"}},
           %{"a.css" => "a", "d.css" => "d"}, ["a"]},
          {"conditions nest under the preferred one", "kit/theme.css",
           %{
             "./theme.css" => %{
               "import" => %{"style" => "./s.css", "default" => "./d.css"},
               "default" => "./x.css"
             }
           }, %{"s.css" => "s", "d.css" => "d", "x.css" => "x"}, ["d"]},
          {"a style condition alone is read like any other", "kit/theme.css",
           %{"./theme.css" => %{"style" => "./s.css"}}, %{"s.css" => "s"}, ["s"]},
          {"a preferred condition with no target falls to the next", "kit/theme.css",
           %{"./theme.css" => %{"import" => nil, "default" => %{}, "require" => "./r.css"}},
           %{"r.css" => "r"}, ["r"]},
          {"a target no file answers does not try the next condition", "kit/theme.css",
           %{"./theme.css" => %{"import" => "./gone.css", "default" => "./d.css"}},
           %{"d.css" => "d"}, []},
          {"an invalid target tries the next condition", "kit/theme.css",
           %{"./theme.css" => %{"import" => "../gone.css", "default" => "./d.css"}},
           %{"d.css" => "d"}, ["d"]},
          {"an array target", "kit/theme.css", %{"./theme.css" => ["./a.css"]}, %{"a.css" => "a"},
           ["a"]},
          {"an array skips what is not a target", "kit/theme.css",
           %{"./theme.css" => ["../gone.css", %{"nope" => %{}}, "./b.css"]}, %{"b.css" => "b"},
           ["b"]}
        ] do
      test name, %{tmp_dir: dir} do
        files =
          Map.new(unquote(Macro.escape(files)), fn
            {path, :script} -> {path, "export const x = 1;\n"}
            {path, token} -> {path, color(token)}
          end)

        manifest = %{"name" => "kit", "exports" => unquote(Macro.escape(exports))}

        assert tokens(dir, unquote(specifier), kit(Map.put(files, "package.json", manifest))) ==
                 unquote(expected)
      end
    end

    test "any other condition is read in the order it is written", %{tmp_dir: dir} do
      css = %{"z.css" => color("z"), "a.css" => color("a")}

      zfirst = ~s({"exports":{"./theme.css":{"zzz":"./z.css","aaa":"./a.css"}}})
      afirst = ~s({"exports":{"./theme.css":{"aaa":"./a.css","zzz":"./z.css"}}})

      assert tokens(dir, "kit/theme.css", kit(Map.put(css, "package.json", zfirst))) == ["z"]
      assert tokens(dir, "kit/theme.css", kit(Map.put(css, "package.json", afirst))) == ["a"]
    end

    test "a repeated condition keeps its place and takes its last value", %{tmp_dir: dir} do
      manifest = ~s({"exports":{"./theme.css":{"zzz":"./z.css","aaa":"./a.css","zzz":"./y.css"}}})

      assert tokens(
               dir,
               "kit/theme.css",
               kit(%{
                 "package.json" => manifest,
                 "z.css" => color("z"),
                 "y.css" => color("y"),
                 "a.css" => color("a")
               })
             ) == ["y"]
    end

    test "conditions nest 32 levels and no further", %{tmp_dir: dir} do
      nested = fn levels ->
        Enum.reduce(1..levels, "./deep.css", fn _, inner -> %{"default" => inner} end)
      end

      files = fn levels ->
        kit(%{
          "package.json" => %{"exports" => %{"./theme.css" => nested.(levels)}},
          "deep.css" => color("deep")
        })
      end

      assert tokens(dir, "kit/theme.css", files.(32)) == ["deep"]
      assert tokens(dir, "kit/theme.css", files.(33)) == []
    end

    test "a string or a top-level condition is not an exports map", %{tmp_dir: dir} do
      css = %{"x.css" => color("x"), "index.css" => color("i")}

      for exports <- ["./x.css", %{"style" => "./x.css"}, ["./x.css"]] do
        files = kit(Map.put(css, "package.json", %{"exports" => exports}))
        assert tokens(dir, "kit", files) == ["i"]
      end

      # With nothing else to read, it finds nothing.
      File.rm!(Path.join(dir, "node_modules/kit/index.css"))
      assert tokens(dir, "kit", %{}) == []
    end

    test "a scoped package reads the same way", %{tmp_dir: dir} do
      files =
        kit(
          %{
            "package.json" => %{
              "exports" => %{"./theme.css" => %{"style" => "./s.css", "default" => "./d.css"}}
            },
            "s.css" => color("s"),
            "d.css" => color("d")
          },
          "@acme/ui"
        )

      assert tokens(dir, "@acme/ui/theme.css", files) == ["d"]
    end

    test "a package linked from a workspace reads the same way", %{tmp_dir: dir} do
      write(dir, %{
        "packages/kit/package.json" =>
          ~s({"name":"kit","exports":{"./theme.css":{"style":"./s.css","default":"./d.css"}}}),
        "packages/kit/s.css" => color("s"),
        "packages/kit/d.css" => color("d"),
        "app.css" => ~s(@import "kit/theme.css";\n)
      })

      File.mkdir_p!(Path.join(dir, "node_modules"))
      File.ln_s!("../packages/kit", Path.join(dir, "node_modules/kit"))

      assert dir |> Path.join("app.css") |> Theme.load() |> Map.fetch!(:tokens) |> Enum.sort() ==
               ["d"]
    end

    test "an unnamed package's utilities come from the same file", %{tmp_dir: dir} do
      write(
        dir,
        kit(%{
          "package.json" => %{
            "exports" => %{"." => %{"style" => "./s.css", "default" => "./d.css"}}
          },
          "s.css" => "@utility from-style { display: flex; }\n",
          "d.css" => "@utility from-default { display: flex; }\n"
        })
        |> Map.put("app.css", ~s(@import "kit";\n))
      )

      theme = Theme.load(Path.join(dir, "app.css"))

      assert Theme.declares_utility?(theme, "from-default")
      refute Theme.declares_utility?(theme, "from-style")
    end

    test "a manifest with a trailing newline is read", %{tmp_dir: dir} do
      assert tokens(
               dir,
               "kit/theme.css",
               kit(%{
                 "package.json" => ~s({"exports":{"./theme.css":"./a.css"}}\n\n),
                 "a.css" => color("a"),
                 "theme.css" => color("t")
               })
             ) == ["a"]
    end
  end

  describe "exports keys" do
    test "a missing target falls back to the package's own file", %{tmp_dir: dir} do
      assert tokens(
               dir,
               "kit/theme.css",
               kit(%{
                 "package.json" => %{"exports" => %{"./theme.css" => "./gone.css"}},
                 "theme.css" => color("t")
               })
             ) == ["t"]
    end

    test "the longest key is tried first, and a missing target tries the next", %{tmp_dir: dir} do
      css = %{"one/styles/theme.css" => color("one"), "two/theme.css" => color("two")}
      manifest = %{"exports" => %{"./*" => "./one/*", "./styles/*" => "./two/*"}}

      assert tokens(dir, "kit/styles/theme.css", kit(Map.put(css, "package.json", manifest))) ==
               ["two"]

      File.rm!(Path.join(dir, "node_modules/kit/two/theme.css"))
      assert tokens(dir, "kit/styles/theme.css", %{}) == ["one"]
    end

    test "a wildcard key answers for its directory", %{tmp_dir: dir} do
      assert tokens(
               dir,
               "kit/parts",
               kit(%{
                 "package.json" => %{"exports" => %{"./parts/*" => "./src/parts/*.css"}},
                 "src/parts/index.css" => color("parts")
               })
             ) == ["parts"]
    end

    for {name, exports} <- [
          {"walks out of the package", %{"./theme.css" => "../out.css"}},
          {"reaches into node_modules", %{"./theme.css" => "./node_modules/out.css"}},
          {"has an encoded separator", %{"./theme.css" => "./a%2fb.css"}},
          {"has no leading ./", %{"./theme.css" => "a.css"}},
          {"is absolute", %{"./theme.css" => "/a.css"}}
        ] do
      test "a target that #{name} is refused", %{tmp_dir: dir} do
        files =
          kit(%{
            "package.json" => %{"exports" => unquote(Macro.escape(exports))},
            "a%2fb.css" => color("a"),
            "a.css" => color("a"),
            "node_modules/out.css" => color("a")
          })

        assert tokens(dir, "kit/theme.css", Map.put(files, "node_modules/out.css", color("a"))) ==
                 []
      end
    end

    test "a capture that walks up is refused", %{tmp_dir: dir} do
      files =
        kit(%{"package.json" => %{"exports" => %{"./x/*" => "./one/*"}}})
        |> Map.put("node_modules/evil.css", color("evil"))

      assert tokens(dir, "kit/x/../../evil.css", files) == []
    end
  end

  describe "the package's own files" do
    test "the import, then under src/", %{tmp_dir: dir} do
      manifest = %{"package.json" => %{}}

      assert tokens(dir, "kit/theme.css", kit(Map.put(manifest, "src/theme.css", color("src")))) ==
               ["src"]

      assert tokens(dir, "kit/theme.css", kit(Map.put(manifest, "theme.css", color("top")))) ==
               ["top"]
    end

    test "a bare import reads index.css, then src's", %{tmp_dir: dir} do
      assert tokens(
               dir,
               "kit",
               kit(%{"package.json" => %{}, "src/index.css" => color("src")})
             ) == ["src"]

      assert tokens(dir, "kit", kit(%{"index.css" => color("top")})) == ["top"]
    end

    test "a subpath never walks out of the package", %{tmp_dir: dir} do
      files =
        kit(%{"package.json" => %{}})
        |> Map.put("node_modules/other/x.css", color("out"))

      assert tokens(dir, "kit/../other/x.css", files) == []
    end

    test "a package with no package.json still has files", %{tmp_dir: dir} do
      assert tokens(dir, "kit/theme.css", kit(%{"theme.css" => color("t")})) == ["t"]

      assert tokens(dir, "@acme/ui/theme.css", kit(%{"theme.css" => color("s")}, "@acme/ui")) ==
               ["s"]
    end

    test "a package.json that cannot be read still has files", %{tmp_dir: dir} do
      for manifest <- ["{not json", "[1,2]"] do
        files = kit(%{"package.json" => manifest, "theme.css" => color("t")})
        assert tokens(dir, "kit/theme.css", files) == ["t"]
      end
    end

    test "a stale .js target reads its TypeScript source", %{tmp_dir: dir} do
      assert tokens(
               dir,
               "kit/theme.css",
               kit(%{
                 "package.json" => %{"exports" => %{"./theme.css" => "./i.js"}},
                 "i.ts" => color("ts"),
                 "theme.css" => color("t")
               })
             ) == ["ts"]
    end

    test "a name starting with a dot is a package, not a path", %{tmp_dir: dir} do
      assert tokens(dir, ".hidden/x.css", kit(%{"x.css" => color("t")}, ".hidden")) == ["t"]
    end
  end

  describe "an imports map" do
    defp hash_kit(imports, files) do
      kit(
        Map.merge(
          %{
            "package.json" => %{"name" => "kit", "imports" => imports},
            "theme.css" => ~s(@import "#tokens";\n) <> color("t")
          },
          files
        )
      )
    end

    test "reaches a file, and it counts with the package", %{tmp_dir: dir} do
      assert tokens(
               dir,
               "kit/theme.css",
               hash_kit(%{"#tokens" => "./tokens.css"}, %{"tokens.css" => color("hash")})
             ) == ["hash", "t"]
    end

    test "reads conditions like exports", %{tmp_dir: dir} do
      assert tokens(
               dir,
               "kit/theme.css",
               hash_kit(%{"#tokens" => %{"style" => "./s.css", "default" => "./d.css"}}, %{
                 "s.css" => color("s"),
                 "d.css" => color("d")
               })
             ) == ["d", "t"]
    end

    test "a wildcard, and a wildcard answering for its directory", %{tmp_dir: dir} do
      wildcard = %{"#t/*" => "./tokens/*.css"}

      assert tokens(
               dir,
               "kit/theme.css",
               kit(%{
                 "package.json" => %{"imports" => wildcard},
                 "theme.css" => ~s(@import "#t/one";\n),
                 "tokens/one.css" => color("one")
               })
             ) == ["one"]

      assert tokens(
               dir,
               "kit/theme.css",
               kit(%{
                 "package.json" => %{"imports" => wildcard},
                 "theme.css" => ~s(@import "#t";\n),
                 "tokens/index.css" => color("index")
               })
             ) == ["index"]
    end

    test "a package target resolves as a package", %{tmp_dir: dir} do
      files =
        hash_kit(%{"#tokens" => "dep/tokens.css"}, %{})
        |> Map.merge(kit(%{"package.json" => %{}, "tokens.css" => color("dep")}, "dep"))

      # A pattern on the import as written names it; this one has none for `#tokens`.
      write(dir, Map.put(files, "app.css", ~s(@import "kit/theme.css";\n)))

      read = fn patterns ->
        Theme.load(Path.join(dir, "app.css"), patterns).tokens |> Enum.sort()
      end

      assert read.([~r/^kit/]) == ["t"]
      assert read.([~r/^kit/, ~r/^#tokens/]) == ["dep", "t"]
    end

    test "a target that leaves the package is refused", %{tmp_dir: dir} do
      files =
        hash_kit(%{"#tokens" => "../other/x.css"}, %{})
        |> Map.put("node_modules/other/x.css", color("out"))

      assert tokens(dir, "kit/theme.css", files) == ["t"]
    end

    test "a name no map answers does not go looking under node_modules", %{tmp_dir: dir} do
      files =
        hash_kit(%{}, %{})
        |> Map.put("node_modules/#tokens/index.css", color("out"))

      assert tokens(dir, "kit/theme.css", files) == ["t"]
    end

    test "the importing stylesheet's own package answers", %{tmp_dir: dir} do
      files =
        kit(%{"package.json" => %{}, "theme.css" => color("t")})
        |> Map.put("package.json", ~s({"imports":{"#kit":"kit/theme.css"}}))
        |> Map.put("app.css", ~s(@import "#kit";\n))

      write(dir, files)

      assert Theme.load(Path.join(dir, "app.css"), [~r/^#kit/]).tokens |> Enum.sort() == ["t"]
    end
  end

  describe "the style and main fields" do
    for field <- ["style", "main"] do
      test "#{field} answers a bare import when nothing else does", %{tmp_dir: dir} do
        files = kit(%{"package.json" => %{unquote(field) => "./f.css"}, "f.css" => color("f")})

        assert tokens(dir, "kit", files) == ["f"]
      end

      test "#{field} does not beat index.css or exports", %{tmp_dir: dir} do
        field = %{unquote(field) => "./f.css"}
        css = %{"f.css" => color("f"), "other.css" => color("other")}

        assert tokens(
                 dir,
                 "kit",
                 kit(Map.merge(css, %{"package.json" => field, "index.css" => color("i")}))
               ) == ["i"]

        File.rm!(Path.join(dir, "node_modules/kit/index.css"))

        assert tokens(
                 dir,
                 "kit",
                 kit(
                   Map.put(
                     css,
                     "package.json",
                     Map.put(field, "exports", %{"." => "./other.css"})
                   )
                 )
               ) == ["other"]
      end

      test "#{field} stays inside the package", %{tmp_dir: dir} do
        files =
          kit(%{"package.json" => %{unquote(field) => "../out.css"}})
          |> Map.put("node_modules/out.css", color("out"))

        assert tokens(dir, "kit", files) == []
      end

      test "#{field} does not answer a subpath", %{tmp_dir: dir} do
        files = kit(%{"package.json" => %{unquote(field) => "./f.css"}, "f.css" => color("f")})

        assert tokens(dir, "kit/theme.css", files) == []
      end
    end

    test "style comes before main", %{tmp_dir: dir} do
      assert tokens(
               dir,
               "kit",
               kit(%{
                 "package.json" => %{"main" => "./m.css", "style" => "./s.css"},
                 "m.css" => color("m"),
                 "s.css" => color("s")
               })
             ) == ["s"]
    end
  end

  defp link_tailwind(dir) do
    source = Path.expand("../fixtures/node/node_modules", __DIR__)
    target = Path.join(dir, "node_modules")
    File.mkdir_p!(target)

    for entry <- File.ls!(source), not String.starts_with?(entry, ".") do
      File.ln_s!(Path.join(source, entry), Path.join(target, entry))
    end
  end

  defp page(dir, specifier, files, classes, settings \\ [theme_imports: ["^kit"]]) do
    css = ~s(@import "tailwindcss";\n@import "#{specifier}";\n) <> color("spotlight")

    result =
      run(
        dir,
        Map.merge(files, %{
          "assets/css/app.css" => css,
          "lib/app_web/live/page_live.ex" => live(~s(<div class="#{classes}" />))
        }),
        rules: [no_raw_colors: :error],
        settings: settings
      )

    {Enum.filter(result.diagnostics, &String.ends_with?(&1.file, "page_live.ex")),
     result.warnings}
  end

  # Tailwind builds all of these, so nothing warns that a color went missing. They
  # go through the real build for that reason.
  describe "no_raw_colors with a named kit" do
    setup %{tmp_dir: dir} do
      link_tailwind(dir)
      :ok
    end

    test "an array target's colors are declared", %{tmp_dir: dir} do
      files =
        kit(%{
          "package.json" => %{"exports" => %{"./theme.css" => ["./a.css"]}},
          "a.css" => color("kit-a")
        })

      assert {[], []} = page(dir, "kit/theme.css", files, "bg-kit-a text-spotlight")
    end

    test "a color imported through the package's imports map is declared", %{tmp_dir: dir} do
      files =
        kit(%{
          "package.json" => %{"name" => "kit", "imports" => %{"#tokens" => "./tokens.css"}},
          "theme.css" => ~s(@import "#tokens";\n) <> color("kit-t"),
          "tokens.css" => color("kit-hash")
        })

      assert {[], []} = page(dir, "kit/theme.css", files, "bg-kit-t bg-kit-hash")
    end

    test "a package with no package.json declares its colors", %{tmp_dir: dir} do
      files = kit(%{"theme.css" => color("kit-t")})

      assert {[], []} = page(dir, "kit/theme.css", files, "bg-kit-t text-spotlight")
    end

    test "a script ahead of the style condition declares nothing, as upstream", %{tmp_dir: dir} do
      files =
        kit(%{
          "package.json" => %{
            "exports" => %{"." => %{"style" => "./s.css", "import" => "./i.js"}}
          },
          "s.css" => color("kit-s"),
          "i.js" => "export const x = 1;\n"
        })

      assert {[finding], []} = page(dir, "kit", files, "bg-kit-s")

      assert finding.message =~
               ~s("bg-kit-s" is not a declared theme color. Use one of: spotlight.)
    end
  end

  describe "the way around a script ahead of the style condition" do
    setup %{tmp_dir: dir} do
      link_tailwind(dir)
      :ok
    end

    test "naming the stylesheet by its path declares its colors", %{tmp_dir: dir} do
      files =
        kit(
          %{
            "package.json" => %{
              "exports" => %{"." => %{"style" => "./theme.css", "import" => "./i.js"}}
            },
            "theme.css" => color("kit-s"),
            "i.js" => "export const x = 1;\n"
          },
          "@acme/ui"
        )

      assert {[], []} =
               page(dir, "../../node_modules/@acme/ui/theme.css", files, "bg-kit-s",
                 theme_imports: ["node_modules/@acme/ui/"]
               )
    end
  end

  describe "Theme.resolve_stylesheet/2" do
    test "gives the real path, and nil for what it cannot read", %{tmp_dir: dir} do
      write(dir, kit(%{"package.json" => %{}, "theme.css" => color("t")}))

      assert Theme.resolve_stylesheet(dir, "kit/theme.css") ==
               Path.join(dir, "node_modules/kit/theme.css")

      assert Theme.resolve_stylesheet(dir, "kit/gone.css") == nil
      assert Theme.resolve_stylesheet(dir, "gone") == nil
      assert Theme.resolve_stylesheet(dir, "https://example.com/x.css") == nil
      assert Theme.resolve_stylesheet(dir, "data:text/css,x") == nil
    end
  end
end

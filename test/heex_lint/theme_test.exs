defmodule HeexLint.ThemeTest do
  use ExUnit.Case, async: true

  alias HeexLint.Theme

  defp values(css) do
    {values, _scoped_names, _theme_names, _declarations} = Theme.parse_declarations(css)
    values
  end

  describe "parse_declarations" do
    test ":root and @theme values win over a scoped selector's" do
      values =
        values("""
        .before { --gap: 2px; }
        :root, :host { --radius: 0.5rem; }
        .compact { --radius: 0.25rem; --gap: 1px; }
        [data-density="compact"] :root { --radius: 0.125rem; }
        @theme { --spacing: 4px; }
        .tight { --spacing: 2px; }
        """)

      assert values["radius"] == "0.5rem"
      assert values["spacing"] == "4px"
      # Set only by scoped selectors: the last one still resolves.
      assert values["gap"] == "1px"
    end

    test "a :root value replaces an earlier scoped one, and later :root values win" do
      {values, scoped_names, _, _} =
        Theme.parse_declarations("""
        .compact { --radius: 1px; --gap: 2px; }
        :root { --radius: 3px; }
        html { --radius: 4px; }
        """)

      assert values["radius"] == "4px"
      assert MapSet.equal?(scoped_names, MapSet.new(["gap"]))
    end

    test "a selector list is scoped unless every selector is a root" do
      values =
        values("""
        :root, html , :host { --a: root; }
        :root, .compact { --a: scoped; --b: scoped; }
        html { --b: root; }
        """)

      assert values == %{"a" => "root", "b" => "root"}
    end

    test "at-rule preludes are not scoped, but selectors inside them are" do
      values =
        values("""
        :root { --a: 1px; --b: 1px; --c: 1px; }
        @media (min-width: 40rem) { :root { --a: 2px; } }
        @layer theme { --b: 2px; }
        @media (min-width: 40rem) { .compact { --c: 2px; } }
        """)

      assert values == %{"a" => "2px", "b" => "2px", "c" => "1px"}
    end

    test "a rule nested in a scoped selector is scoped" do
      assert values(":root { --a: 1px; } .compact { :root { --a: 2px; } }") == %{"a" => "1px"}
    end

    test "dark blocks stay skipped" do
      values =
        values("""
        .dark { --only-dark: 1px; }
        :root { --a: 1px; }
        .dark { --a: 2px; }
        .dark .compact { --a: 3px; }
        @media (prefers-color-scheme: dark) { :root { --a: 4px; } }
        """)

      assert values == %{"a" => "1px"}
    end
  end

  describe "load" do
    @describetag :tmp_dir

    defp load(dir, files) do
      for {name, css} <- files, do: File.write!(Path.join(dir, name), css)
      Theme.load(Path.join(dir, "app.css"))
    end

    test "a scoped value in one file does not beat a :root value from an import", %{tmp_dir: dir} do
      theme =
        load(dir, %{
          "base.css" => ":root { --radius: 8px; }",
          "app.css" => ~s(@import "./base.css";\n.compact { --radius: 4px; })
        })

      assert theme.values["radius"] == "8px"
    end

    test "a scoped import does not beat a :root value from another import", %{tmp_dir: dir} do
      files = %{
        "root.css" => ":root { --radius: 8px; }",
        "scoped.css" => ".compact { --radius: 4px; }"
      }

      for imports <- [~w(root scoped), ~w(scoped root)] do
        app = Enum.map_join(imports, "\n", &~s(@import "./#{&1}.css";))
        theme = load(dir, Map.put(files, "app.css", app))
        assert theme.values["radius"] == "8px", "imports: #{inspect(imports)}"
      end
    end

    test "a :root value in the importing file replaces a :root value it imports", %{tmp_dir: dir} do
      theme =
        load(dir, %{
          "base.css" => ":root { --radius: 8px; }",
          "app.css" => ~s(@import "./base.css";\n:root { --radius: 2px; })
        })

      assert theme.values["radius"] == "2px"
    end

    test "values only scoped selectors set resolve across files, last one winning", %{
      tmp_dir: dir
    } do
      theme =
        load(dir, %{
          "a.css" => ".a { --gap: 1px; }",
          "app.css" => ~s(@import "./a.css";\n.b { --gap: 2px; })
        })

      assert theme.values["gap"] == "2px"
      assert MapSet.member?(theme.scoped_names, "gap")
    end

    test "a stylesheet reached by two import paths is read once", %{tmp_dir: dir} do
      theme =
        load(dir, %{
          "shared.css" => "@utility dia { color: red }",
          "b.css" => ~s(@import "./shared.css";),
          "c.css" => ~s(@import "./shared.css";\n@utility dia { padding: 1px }),
          "app.css" => ~s(@import "./b.css";\n@import "./c.css";)
        })

      assert Theme.utility_properties_of(theme, "dia") == ["padding"]
      assert Enum.frequencies(theme.files) |> Map.values() |> Enum.uniq() == [1]
    end

    test "two case spellings are one stylesheet only on a disk that has one", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "shared.css"), "@utility sym { color: red }")
      one_file? = File.exists?(Path.join(dir, "SHARED.css"))

      files = %{
        "b.css" => ~s(@import "#{dir}/Shared.css";),
        "c.css" => ~s(@utility sym { padding: 1px }\n@import "#{dir}/shared.css";),
        "app.css" => ~s(@import "./b.css";\n@import "./c.css";)
      }

      if one_file? do
        theme = load(dir, files)

        assert Theme.utility_properties_of(theme, "sym") == ["padding"]
        assert length(theme.files) == 4
      else
        theme = load(dir, Map.put(files, "Shared.css", "@utility sym { margin: 0 }"))

        assert Theme.utility_properties_of(theme, "sym") == ["color"]
        assert length(theme.files) == 5
      end
    end

    test "two hard links are read as two stylesheets, as their paths differ", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "one.css"), "@utility sym { color: red }")
      File.ln!(Path.join(dir, "one.css"), Path.join(dir, "two.css"))

      theme =
        load(dir, %{
          "c.css" => ~s(@utility sym { padding: 1px }\n@import "./two.css";),
          "app.css" => ~s(@import "./one.css";\n@import "./c.css";)
        })

      assert Theme.utility_properties_of(theme, "sym") == ["color"]
    end

    test "a stylesheet read again does not undo what came after it", %{tmp_dir: dir} do
      theme =
        load(dir, %{
          "shared.css" => ":root { --radius: 8px; }",
          "b.css" => ~s(@import "./shared.css";\n:root { --radius: 4px; }),
          "c.css" => ~s(@import "./shared.css";),
          "app.css" => ~s(@import "./b.css";\n@import "./c.css";)
        })

      assert theme.values["radius"] == "4px"
    end

    test "an import cycle reads each stylesheet once", %{tmp_dir: dir} do
      theme =
        load(dir, %{
          "a.css" => ~s(@import "./app.css";\n@utility dia { color: red }),
          "app.css" => ~s(@import "./a.css";)
        })

      assert Theme.utility_properties_of(theme, "dia") == ["color"]
      assert length(theme.files) == 2
    end

    test "a byte order mark leaves a leading :root unscoped", %{tmp_dir: dir} do
      theme =
        load(dir, %{
          "base.css" => ":root { --radius: 12px; }",
          "tokens.css" => "\uFEFF:root { --radius: 8px; } .compact { --radius: 4px; }",
          "bare.css" => "\uFEFF--gap: 3px;",
          "app.css" => """
          @import "./base.css";
          @import "./tokens.css";
          @import "./bare.css";
          @theme { --radius-card: var(--radius); }
          """
        })

      assert theme.values["radius"] == "8px"
      assert theme.values["gap"] == "3px"
      assert Map.new(Theme.scale(theme, :radius))["card"] == 8.0
    end

    test "a color token reads its variable from :root", %{tmp_dir: dir} do
      theme =
        load(dir, %{
          "app.css" => """
          @theme { --color-brand: var(--brand); }
          :root { --brand: #000000; }
          .promo { --brand: #ffffff; }
          """
        })

      assert theme.colors["brand"] == HeexLint.Grammar.Colors.parse("#000000")
    end
  end
end

defmodule HeexLint.ThemeTest do
  use ExUnit.Case, async: true

  alias HeexLint.{LintHelpers, Theme}

  setup do
    %{theme: Theme.load(LintHelpers.theme())}
  end

  test "reads variables from the file and its local imports", %{theme: theme} do
    assert Theme.variable?(theme, "--surface")
    assert Theme.variable?(theme, "--danger")
    assert Theme.variable?(theme, "--color-brand")
    refute Theme.variable?(theme, "--missing")
  end

  test "keeps the first definition of a variable", %{theme: theme} do
    assert theme.variables["--surface"] == "#f4f4f1"
  end

  test "turns @theme colors into utilities and other colors into variable shorthands", %{
    theme: theme
  } do
    utilities = Map.new(theme.colors, &{&1.variable, &1.utility})

    assert utilities["--color-brand"] == "brand"
    assert utilities["--surface"] == "(--surface)"
    refute Map.has_key?(utilities, "--gutter")
    refute Map.has_key?(utilities, "--font-display")
  end

  test "ranks colors by how close they look", %{theme: theme} do
    assert [%{variable: "--surface-raised"} | _] = Theme.closest_colors(theme, "#fefefe")
    assert [%{variable: "--ink"} | _] = Theme.closest_colors(theme, "oklch(14.1% 0.005 285.823)")
  end

  test "knows plain CSS class prefixes", %{theme: theme} do
    assert Theme.class_prefix?(theme, "toast--")
    refute Theme.class_prefix?(theme, "bg-")
    refute Theme.class_prefix?(theme, "")
  end

  test "is empty without a file" do
    assert Theme.load(nil) == %Theme{}
    assert Theme.load("missing.css") == %Theme{}
  end
end

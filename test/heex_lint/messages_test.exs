defmodule HeexLint.MessagesTest do
  use ExUnit.Case, async: true

  alias HeexLint.Messages

  test "placeholders, fallbacks and unknown keys" do
    data = %{"component" => ".button", "variants" => "", "sizes" => nil}

    assert Messages.interpolate("Use a {{component}} variant: {{variants|none defined}}.", data) ==
             "Use a .button variant: none defined."

    assert Messages.interpolate("{{ sizes | none }} {{unknown}} {{unknown|x}}", data) ==
             "none {{unknown}} {{unknown|x}}"
  end

  test "custom messages get the universal slots and the note" do
    data = %{"className" => "p-4", "replacement" => "p-3"}
    assert Messages.render("built-in", data) == "built-in"

    assert Messages.render("built-in", data, nil, "Use {{suggestions}} for {{class}}.") ==
             "Use p-3 for p-4."

    assert Messages.render("built-in {{className}}", data, nil, nil, "See DESIGN.md.") ==
             "built-in p-4 See DESIGN.md."

    assert Messages.render("built-in", data, "Contract words.", "Rule words.") ==
             "Contract words."
  end

  test "attribute findings expose className as attr=\"value\"" do
    data = %{"attribute" => "fill", "value" => "#f00"}
    assert Messages.render("x", data, nil, "{{className}} is raw.") == ~s(fill="#f00" is raw.)
  end

  test "likely placeholder typos warn" do
    assert [warning] = Messages.check("Use {{compnent}}.", "no_restyle")

    assert warning ==
             ~s(Unknown message placeholder "{{compnent}}" in no_restyle. Did you mean "{{component}}"? It will remain literal.)

    assert Messages.check("Literal {{braces}} here.", "no_restyle") == []
  end

  test "token lists put foreground tokens last and cap at twelve" do
    tokens = for n <- 1..14, do: "t#{String.pad_leading("#{n}", 2, "0")}"

    assert Messages.list_tokens(["primary-foreground", "primary", "muted"]) ==
             "muted, primary, primary-foreground"

    assert Messages.list_tokens(tokens) =~ "t12 (+2 more)"
  end
end

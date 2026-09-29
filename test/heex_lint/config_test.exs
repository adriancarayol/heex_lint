defmodule HeexLint.ConfigTest do
  use ExUnit.Case, async: true

  alias HeexLint.Config
  alias HeexLint.Rules.{NoArbitraryValues, NoRawColors, NoRestyle}

  test "without rules, the recommended set applies with its component override" do
    config = Config.new([])

    assert {NoRestyle, :error, [allow: ["layout"]]} in Config.rules_for(
             config,
             "lib/app_web/live/page_live.ex"
           )

    refute Enum.any?(
             Config.rules_for(config, "lib/app_web/components/core_components.ex"),
             &(elem(&1, 0) == NoRestyle)
           )
  end

  test "only the listed rules are enabled" do
    config = Config.new(rules: [no_raw_colors: :warn])
    assert Config.rules_for(config, "lib/a.ex") == [{NoRawColors, :warning, []}]
  end

  test "overrides apply in order; a severity alone keeps the options" do
    config =
      Config.new(
        rules: [no_arbitrary_values: {:error, allow: ["layout"]}],
        overrides: [
          [files: ["lib/legacy/**"], rules: [no_arbitrary_values: :warning]],
          [files: ["lib/legacy/marketing/*"], rules: [no_arbitrary_values: :off]]
        ]
      )

    assert Config.rules_for(config, "lib/legacy/page.ex") == [
             {NoArbitraryValues, :warning, [allow: ["layout"]]}
           ]

    assert Config.rules_for(config, "lib/legacy/marketing/page.ex") == []

    assert Config.rules_for(config, "lib/app/page.ex") == [
             {NoArbitraryValues, :error, [allow: ["layout"]]}
           ]
  end

  test "recognition options: a rule's own wins over the shared settings" do
    config = Config.new(settings: [ui: "AppWeb.UI", merge_functions: ["tw"]], rules: [])
    assert %{ui: "AppWeb.UI", merge_functions: ["tw"]} = Config.recognition(config, [])
    assert %{merge_functions: ["cx"]} = Config.recognition(config, merge_functions: ["cx"])
  end

  test "invalid configuration raises" do
    assert_raise ArgumentError, ~r/unknown heex_lint rule/, fn ->
      Config.new(rules: [no_such_rule: :error])
    end

    assert_raise ArgumentError, ~r/unknown heex_lint setting/, fn ->
      Config.new(settings: [themes: "x"], rules: [])
    end

    assert_raise ArgumentError, ~r/limited to 500 characters/, fn ->
      Config.new(rules: [no_raw_colors: {:error, message: String.duplicate("x", 501)}])
    end
  end
end

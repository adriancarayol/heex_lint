defmodule HeexLint.PolicyTest do
  use ExUnit.Case, async: true

  alias HeexLint.Policy
  alias HeexLint.Policy.ConfigError

  defp policy(options) do
    {policy, _warnings} = Policy.compile(options, nil, "test")
    policy
  end

  defp ok?(options, token, component \\ nil),
    do: Policy.decide(policy(options), component, token) == :ok

  describe "allow and deny" do
    test "the policy table" do
      # Neither: no exceptions.
      refute ok?([], "mt-4")
      # allow: only matches.
      assert ok?([allow: ["layout"]], "mt-4")
      refute ok?([allow: ["layout"]], "p-4")
      # allow: [] allows nothing.
      refute ok?([allow: []], "mt-4")
      # deny alone: everything except the matches.
      assert ok?([deny: ["w-*"]], "p-4")
      refute ok?([deny: ["w-*"]], "w-full")
      # deny: [] alone: everything.
      assert ok?([deny: []], "bg-pink-500")
    end

    test "deny subtracts from allow" do
      refute ok?([allow: ["layout"], deny: ["w-*"]], "w-full")
      assert ok?([allow: ["layout"], deny: ["w-*"]], "mt-4")
    end
  end

  describe "entries" do
    test "categories, groups and patterns" do
      assert ok?([allow: ["spacing"]], "gap-2")
      assert ok?([allow: ["p"]], "p-4")
      # Groups are separate: p does not include px.
      refute ok?([allow: ["p"]], "px-4")
      refute ok?([allow: ["rounded"]], "rounded-t-lg")
      # An entry that is a group and a class matches both.
      assert ok?([allow: ["flex"]], "flex")
      assert ok?([allow: ["flex"]], "flex-1")
      assert ok?([allow: ["p-*"]], "md:!p-4")
      assert ok?([allow: ["bg-primary"]], "bg-primary/50")
      # A fraction is the value itself.
      refute ok?([allow: ["w-1"]], "w-1/2")
    end

    test "entries with a colon match the full class" do
      assert ok?([allow: ["[margin:*]"]], "[margin:1rem]")
      refute ok?([allow: ["[margin:*]"]], "md:[margin:1rem]")
    end

    test "markers count as layout; unclassified never does" do
      assert ok?([allow: ["layout"]], "group")
      assert ok?([allow: ["layout"]], "peer/name")
      refute ok?([allow: ["layout"]], "flex-cols")
      assert ok?([allow: ["layout", "flex-cols"]], "flex-cols")
    end

    test "a misspelled category or group is a configuration error" do
      assert_raise ConfigError,
                   ~r/Contract entry "spacig" is not a category .* Did you mean "spacing"\?/,
                   fn ->
                     policy(allow: ["spacig"])
                   end
    end

    test "other unknown names warn and match by name" do
      {_policy, [warning]} = Policy.compile([allow: ["prose-custom"]], nil, "test")
      assert warning =~ ~s(Contract entry "prose-custom" is not a category)
    end

    test "an invalid pattern is a configuration error" do
      assert_raise ConfigError, ~s(Contract pattern "(" is not a valid regular expression.), fn ->
        policy(contracts: [[pattern: "("]])
      end
    end
  end

  describe "contracts" do
    test "replace the keys they write and inherit the rest" do
      options = [
        allow: ["*-amber-*"],
        deny: ["bg-amber-500"],
        contracts: [[pattern: "^badge$", allow: ["*-amber-500"], deny: []]]
      ]

      refute ok?(options, "bg-amber-500")
      assert ok?(options, "text-amber-600")
      assert ok?(options, "bg-amber-500", "badge")
      refute ok?(options, "text-amber-600", "badge")
    end

    test "the last matching contract applies" do
      options = [
        allow: ["layout"],
        contracts: [
          [pattern: "title$", allow: ["typography"]],
          [pattern: "^card_title$", allow: ["color"]]
        ]
      ]

      assert ok?(options, "text-primary", "card_title")
      refute ok?(options, "text-sm", "card_title")
      assert ok?(options, "text-sm", "dialog_title")
    end

    test "verdicts carry the category and the contract's words" do
      options = [
        allow: ["layout"],
        contracts: [[pattern: "^button$", message: %{spacing: "Use a size."}]]
      ]

      assert {:not_allowed, ["layout"], "spacing", "Use a size."} =
               Policy.decide(policy(options), "button", "p-4")

      assert {:not_allowed, ["layout"], "color", nil} =
               Policy.decide(policy(options), "button", "bg-primary")

      assert {:not_allowed, ["layout"], "unclassified", nil} =
               Policy.decide(policy(options), "button", "zzz")
    end
  end
end

defmodule HeexLint.Rules.NoUnknownVariablesTest do
  use ExUnit.Case, async: true

  import HeexLint.LintHelpers

  test "reports undefined variables and suggests close names" do
    [diagnostic] = lint(~s|<div class="bg-(--surfce)">x</div>|, :no_unknown_variables)

    assert diagnostic.message =~ "reads --surfce"
    assert diagnostic.message =~ "Did you mean --surface?"
  end

  test "reads var() references" do
    assert [_] = lint(~s|<div class="text-[var(--nope)]">x</div>|, :no_unknown_variables)
  end

  test "allows theme variables, inline variables and allowed patterns" do
    template = """
    <div class="bg-(--surface) text-[var(--danger)] w-(--progress) h-(--radix-height)">x</div>
    <div style="--progress: 40%">y</div>
    """

    assert lint(template, :no_unknown_variables, rule: [allow: ["--radix-*"]]) == []
  end

  test "is skipped without a theme" do
    assert lint(~s|<div class="bg-(--anything)">x</div>|, :no_unknown_variables, theme: nil) == []
  end
end

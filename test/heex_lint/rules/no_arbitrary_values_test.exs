defmodule HeexLint.Rules.NoArbitraryValuesTest do
  use ExUnit.Case, async: true

  import HeexLint.LintHelpers

  defp message(class) do
    [diagnostic] = lint(~s(<div class="#{class}">x</div>), :no_arbitrary_values)
    diagnostic.message
  end

  test "suggests the exact spacing step" do
    assert message("p-[12px]") =~ "Use the spacing scale: p-3 (12px)."
    assert message("md:-mt-[1rem]") =~ "md:-mt-4 (16px)"
    assert message("w-[1px]") =~ "Use w-px."
  end

  test "suggests the neighbouring spacing steps" do
    assert message("gap-[13px]") =~ "gap-3.25 (13px)."
    assert message("gap-[13.5px]") =~ "gap-3.25 (13px) or gap-3.5 (14px)"
  end

  test "suggests the nearest font size and radius" do
    assert message("text-[11px]") =~ "Use the nearest font size: text-xs (12px)."
    assert message("rounded-t-[7px]") =~ "rounded-t-md (6px)"
  end

  test "suggests theme colors for arbitrary colors" do
    assert message("bg-[#fdfdfd]") =~ "bg-(--surface-raised)"
    assert message("text-[#111]") =~ "text-(--ink)"
  end

  test "reports arbitrary properties" do
    assert message("[mask-type:alpha]") =~ "Use a Tailwind utility"
  end

  test "allows variable references" do
    template =
      ~s|<div class="bg-(--surface) text-[var(--ink)] text-[length:var(--gutter)] bg-[var(--ink)]/50">x</div>|

    assert lint(template, :no_arbitrary_values) == []
  end

  test "ignores arbitrary variants unless asked" do
    template = ~s(<div class="[&>svg]:size-4">x</div>)

    assert lint(template, :no_arbitrary_values) == []
    assert [_] = lint(template, :no_arbitrary_values, rule: [variants: true])
  end

  test "supports allow patterns" do
    template = ~s(<div class="grid-cols-[4rem_1fr] max-w-[80ch]">x</div>)

    assert [%{message: message}] =
             lint(template, :no_arbitrary_values, rule: [allow: ["grid-cols-[*"]])

    assert message =~ "max-w-[80ch]"
  end
end

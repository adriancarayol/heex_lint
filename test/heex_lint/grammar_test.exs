defmodule HeexLint.GrammarTest do
  use ExUnit.Case, async: true

  alias HeexLint.Grammar.{Categories, Classes, Classifier, Colors, Lengths, Similar}

  doctest Classifier
  doctest Categories
  doctest Classes
  doctest Colors
  doctest Lengths
  doctest Similar

  # From @shadcn/lint's classifier tests; the whole grammar is also checked
  # against the reference implementation on Tailwind's full class list.
  @groups [
    {"text-sm", "font-size"},
    {"text-red-500", "text-color"},
    {"text-center", "text-alignment"},
    {"text-muted-foreground", "text-color"},
    {"bg-pink-500", "bg-color"},
    {"bg-primary/90", "bg-color"},
    {"bg-[#333]", "bg-color"},
    {"bg-(--x)", "bg-color"},
    {"p-4", "p"},
    {"px-6", "px"},
    {"gap-2", "gap"},
    {"mt-4", "mt"},
    {"-mt-4", "mt"},
    {"!p-0", "p"},
    {"p-0!", "p"},
    {"w-full", "w"},
    {"w-[320px]", "w"},
    {"w-1/2", "w"},
    {"size-4", "size"},
    {"rounded-lg", "rounded"},
    {"rounded", "rounded"},
    {"border", "border-w"},
    {"border-2", "border-w"},
    {"border-border", "border-color"},
    {"ring-2", "ring-w"},
    {"ring-ring/50", "ring-color"},
    {"shadow-lg", "shadow"},
    {"shadow-lg/50", "shadow"},
    {"shadow-none", "shadow"},
    {"opacity-50", "opacity"},
    {"animate-spin", "animate"},
    {"transition-colors", "transition"},
    {"hover:bg-accent", "bg-color"},
    {"md:hover:text-sm", "font-size"},
    {"data-[state=open]:bg-accent", "bg-color"},
    {"[&_svg]:size-4", "size"},
    {"[color:red]", "arbitrary..color"},
    {"font-medium", "font-weight"},
    {"leading-none", "leading"},
    {"truncate", "text-overflow"},
    {"flex", "display"},
    {"hidden", "display"},
    {"absolute", "position"},
    {"z-50", "z"},
    {"col-start-2", "col-start"},
    {"self-end", "align-self"},
    {"sr-only", "sr"},
    {"flex-grow", "grow"},
    {"flex-grow-0", "grow"},
    {"flex-shrink", "shrink"},
    {"flex-shrink-[2]", "shrink"},
    {"md:flex-grow", "grow"},
    {"overflow-ellipsis", "text-overflow"},
    {"decoration-slice", "box-decoration"},
    {"decoration-clone", "box-decoration"},
    {"decoration-sky-500", "text-decoration-color"},
    {"text-sm/6", "font-size"},
    {"text-white/50", "text-color"}
  ]

  test "classifies classes into cn's groups" do
    for {token, group} <- @groups do
      assert {token, Classifier.group_of(token)} == {token, group}
    end
  end

  test "names the grammar does not know have no group" do
    for token <- ["unknown-thing", "cn-accordion-item", "group/button", "[novalue]", "", "!"] do
      assert Classifier.group_of(token) == nil
    end
  end

  test "categories" do
    assert Categories.category_of("p") == "spacing"
    assert Categories.category_of("bg-color") == "color"
    assert Categories.category_of("font-size") == "typography"
    assert Categories.category_of("rounded") == "shape"
    assert Categories.category_of("shadow") == "effects"
    assert Categories.category_of("transition") == "motion"
    assert Categories.category_of("mt") == nil
    assert Categories.category_of("text-alignment") == nil
    assert Categories.category_of("arbitrary..padding-top") == "spacing"
    assert Categories.category_of("arbitrary..font-size") == "typography"
    assert Categories.category_of("arbitrary..width") == nil
  end

  test "class shape" do
    assert Classes.arbitrary_value?("p-[13px]")
    assert Classes.arbitrary_value?("md:[padding:1rem]")
    refute Classes.arbitrary_value?("bg-(--brand)")
    refute Classes.arbitrary_value?("data-[state=open]:flex")
    assert Classes.palette_class?("hover:bg-zinc-100/50")
    refute Classes.palette_class?("bg-primary")
    refute Classes.palette_class?("text-white")
    assert Classes.marker?("group/card")

    assert Classes.replace_class("p-4 bg-zinc-100 bg-zinc-1000", "bg-zinc-100", "bg-muted") ==
             "p-4 bg-muted bg-zinc-1000"
  end

  test "colors" do
    assert Colors.parse("oklch(55.6% 0 none)") != nil
    assert Colors.parse("color-mix(in srgb, red, blue)") == nil
    assert Colors.parse("currentColor") == nil
    assert Colors.named_color?("RebeccaPurple")
  end

  test "lengths" do
    assert Lengths.px("calc(1rem - 4px)") == 12.0
    assert Lengths.px("50%") == nil
    assert Lengths.px("0") == 0.0
  end

  test "did you mean" do
    assert Similar.did_you_mean("spacig", ["spacing", "shape"]) == "spacing"
    assert Similar.did_you_mean("ab", ["abc"]) == nil
    assert Similar.did_you_mean("primary", ["primary"]) == nil
  end
end

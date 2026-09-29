defmodule HeexLint.ClassNameTest do
  use ExUnit.Case, async: true

  alias HeexLint.ClassName

  doctest ClassName

  test "keeps colons inside brackets" do
    assert %ClassName{variants: ["[&:hover]"], utility: "p-2"} = ClassName.parse("[&:hover]:p-2")
    assert %ClassName{variants: [], utility: "bg-[url(a:b)]"} = ClassName.parse("bg-[url(a:b)]")
  end

  test "reads the trailing important modifier" do
    assert %ClassName{utility: "p-2", important: true} = ClassName.parse("p-2!")
  end

  test "rebuilds a class around a new utility" do
    class = ClassName.parse("md:hover:!-mt-[13px]")
    assert ClassName.with_utility(class, "mt-3") == "md:hover:-mt-3!"
  end
end

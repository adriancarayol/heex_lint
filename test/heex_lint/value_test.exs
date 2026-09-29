defmodule HeexLint.ValueTest do
  use ExUnit.Case, async: true

  alias HeexLint.Value

  defp tokens(value, indentation \\ 0), do: value |> Value.strings(indentation) |> Value.tokens()

  test "splits quoted values, following line breaks" do
    assert tokens({:string, "p-4  bg-white\n  mt-2", {3, 10}}, 4) == [
             {:static, "p-4", {3, 10}},
             {:static, "bg-white", {3, 15}},
             {:static, "mt-2", {4, 7}}
           ]
  end

  test "reads list items, && and if branches but not conditions" do
    code = ~S|["px-2", @flag && "py-5", if(@size == "sm", do: "a", else: "b c"), @class]|

    assert tokens({:expr, code, {1, 1}}) == [
             {:static, "px-2", {1, 3}},
             {:static, "py-5", {1, 20}},
             {:static, "a", {1, 50}},
             {:static, "b", {1, 61}},
             {:static, "c", {1, 63}}
           ]
  end

  test "reads case and cond clauses and ~w sigils" do
    code = ~S|case @variant do "primary" -> "bg-brand"; _ -> ~w(bg-surface text-ink) end|

    assert Enum.map(tokens({:expr, code, {1, 1}}), &elem(&1, 1)) ==
             ["bg-brand", "bg-surface", "text-ink"]

    code = ~S|cond do @a -> "m-1"; true -> "m-2" end|
    assert Enum.map(tokens({:expr, code, {1, 1}}), &elem(&1, 1)) == ["m-1", "m-2"]
  end

  test "marks classes joined to runtime values as partial" do
    assert tokens({:expr, ~S|"px-2 bg-#{@color} #{@extra}"|, {1, 1}}) == [
             {:static, "px-2", {1, 2}},
             {:partial, "bg-\#{…}", {1, 7}}
           ]

    assert [{:partial, "w-\#{…}", {1, 2}}] = tokens({:expr, ~S|"w-" <> @width|, {1, 1}})
  end

  test "keeps positions on later lines of an expression" do
    code = ~s|[\n  "x",\n  "text-(--ink)"\n]|

    assert tokens({:expr, code, {10, 20}}, 4) == [
             {:static, "x", {11, 8}},
             {:static, "text-(--ink)", {12, 8}}
           ]
  end

  test "treats unparsable code as a runtime value" do
    assert Value.strings({:expr, "[", {1, 1}}, 0) == [[{:dynamic, {1, 1}}]]
  end
end

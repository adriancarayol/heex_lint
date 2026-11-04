defmodule HeexLint.Grammar.Trie do
  @moduledoc """
  Builds the class map from cn's class groups and theme scales: nodes keyed
  by their path of `-`-split parts, each `{group, validators}`. Every prefix
  of a node's path is a node too, as in tailwind-merge's trie. Built in config
  order, so a later group wins an exact path, and validators stay in the order
  they were added.
  """

  alias HeexLint.Grammar.Validators

  @typedoc "Each path of parts, with its exact group and its `{validator, group}` list."
  @type t :: %{[String.t()] => {String.t() | nil, [{String.t(), String.t()}]}}

  @doc "The class map of `class_groups`, reading `$t` references from `theme`."
  @spec build([{String.t(), list()}], %{String.t() => list()}) :: t()
  def build(class_groups, theme) do
    Enum.reduce(class_groups, %{[] => {nil, []}}, fn {group, definitions}, nodes ->
      Enum.reduce(definitions, nodes, &process(&1, [], group, theme, &2))
    end)
  end

  defp process("", path, group, _theme, nodes) do
    nodes |> put_node(path) |> Map.update(path, {group, []}, fn {_, v} -> {group, v} end)
  end

  defp process(text, path, group, _theme, nodes) when is_binary(text) do
    target = path ++ String.split(text, "-")
    nodes |> put_node(target) |> Map.update!(target, fn {_, v} -> {group, v} end)
  end

  defp process(%{"$t" => name}, path, group, theme, nodes) do
    Enum.reduce(Map.get(theme, name, []), nodes, &process(&1, path, group, theme, &2))
  end

  defp process(%{"$v" => name}, path, group, _theme, nodes) do
    unless name in Validators.names(), do: raise("cn-classifier: unknown validator #{name}")

    nodes
    |> put_node(path)
    |> Map.update(path, {nil, [{name, group}]}, fn {g, v} -> {g, v ++ [{name, group}]} end)
  end

  defp process(pairs, path, group, theme, nodes) when is_list(pairs) do
    Enum.reduce(pairs, nodes, fn {key, inner}, acc ->
      child = path ++ String.split(key, "-")
      acc = put_node(acc, child)
      Enum.reduce(inner, acc, &process(&1, child, group, theme, &2))
    end)
  end

  defp put_node(nodes, path) do
    Enum.reduce(1..length(path)//1, nodes, fn n, acc ->
      Map.put_new(acc, Enum.take(path, n), {nil, []})
    end)
  end
end

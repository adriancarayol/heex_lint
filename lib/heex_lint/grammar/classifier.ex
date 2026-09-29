defmodule HeexLint.Grammar.Classifier do
  @moduledoc """
  Classifies a Tailwind class into its class group, such as `p`, `bg-color`
  or `font-size`.

  The grammar is the default config of [cn](https://github.com/shadcn-ui/cn)
  0.3.2 (MIT), vendored in `priv/cn_config.json`. The lookup mirrors
  tailwind-merge's class map: a trie keyed by `-`-split parts, built in
  config order, where exact parts go as deep as they can and validators are
  tried on the rest from the deepest node back up.

      iex> HeexLint.Grammar.Classifier.group_of("md:hover:text-sm")
      "font-size"
      iex> HeexLint.Grammar.Classifier.group_of("text-red-500")
      "text-color"
      iex> HeexLint.Grammar.Classifier.group_of("unknown-thing")
      nil
  """

  alias HeexLint.Grammar.{Classes, Validators}

  @config_path Path.expand("../../../priv/cn_config.json", __DIR__)
  @external_resource @config_path

  # The cn version this grammar comes from.
  @cn_version "0.3.2"

  # tailwind-merge's prefix for arbitrary properties; two dots cannot
  # collide with a plugin group.
  @arbitrary_property_prefix "arbitrary.."

  # Tailwind still generates these utilities under their Tailwind 3 names,
  # so they read as the utilities they are.
  @renamed %{
    "flex-grow" => "grow",
    "flex-shrink" => "shrink",
    "overflow-ellipsis" => "text-ellipsis",
    "decoration-slice" => "box-decoration-slice",
    "decoration-clone" => "box-decoration-clone"
  }

  # Objects are exported as {"$o": [[key, value], ...]} so their order,
  # which decides the first match, survives JSON.
  ordered = fn
    ordered, %{"$o" => pairs} ->
      Enum.map(pairs, fn [key, value] -> {key, ordered.(ordered, value)} end)

    ordered, list when is_list(list) ->
      Enum.map(list, &ordered.(ordered, &1))

    _ordered, other ->
      other
  end

  config = @config_path |> File.read!() |> JSON.decode!()
  theme = config |> Map.fetch!("theme") |> then(&ordered.(ordered, &1)) |> Map.new()
  class_groups = config |> Map.fetch!("classGroups") |> then(&ordered.(ordered, &1))

  # Nodes keyed by their path of parts; a node is {group, validators}.
  # Every prefix of a node's path is a node too, as in the trie.
  put_node = fn nodes, path ->
    Enum.reduce(1..length(path)//1, nodes, fn n, acc ->
      Map.put_new(acc, Enum.take(path, n), {nil, []})
    end)
  end

  split = fn key -> String.split(key, "-") end

  process = fn process, definition, path, group, nodes ->
    case definition do
      "" ->
        nodes |> put_node.(path) |> Map.update(path, {group, []}, fn {_, v} -> {group, v} end)

      text when is_binary(text) ->
        target = path ++ split.(text)
        nodes |> put_node.(target) |> Map.update!(target, fn {_, v} -> {group, v} end)

      %{"$t" => name} ->
        Enum.reduce(Map.get(theme, name, []), nodes, &process.(process, &1, path, group, &2))

      %{"$v" => name} ->
        unless name in Validators.names(), do: raise("cn-classifier: unknown validator #{name}")

        nodes
        |> put_node.(path)
        |> Map.update(path, {nil, [{name, group}]}, fn {g, v} -> {g, v ++ [{name, group}]} end)

      pairs when is_list(pairs) ->
        Enum.reduce(pairs, nodes, fn {key, inner}, acc ->
          child = path ++ split.(key)
          acc = put_node.(acc, child)
          Enum.reduce(inner, acc, &process.(process, &1, child, group, &2))
        end)
    end
  end

  nodes =
    Enum.reduce(class_groups, %{[] => {nil, []}}, fn {group, definitions}, acc ->
      Enum.reduce(definitions, acc, &process.(process, &1, [], group, &2))
    end)

  @nodes nodes
  @groups Enum.map(class_groups, &elem(&1, 0))
  @postfix_lookup_groups MapSet.new(Map.get(config, "postfixLookupClassGroups", []))

  @doc "The cn version the grammar comes from."
  def cn_version, do: @cn_version

  @doc "Every class group id, in config order."
  @spec groups() :: [String.t()]
  def groups, do: @groups

  @doc """
  The class group of `token`, ignoring its variants and important marker,
  or `nil` when the grammar does not recognize it.
  """
  @spec group_of(String.t()) :: String.t() | nil
  def group_of(token) do
    base = token |> String.trim() |> Classes.split_variants() |> elem(1)

    base =
      cond do
        String.ends_with?(base, "!") -> String.slice(base, 0..-2//1)
        String.starts_with?(base, "!") -> String.slice(base, 1..-1//1)
        true -> base
      end

    if base == "", do: nil, else: classify(current_name(base))
  end

  defp classify(base) do
    case postfix_index(base) do
      nil ->
        lookup(base)

      slash ->
        # Without the modifier first, so text-sm/6 stays font-size instead
        # of reaching text-color's catch-all.
        group = lookup(binary_part(base, 0, slash))

        cond do
          group && MapSet.member?(@postfix_lookup_groups, group) -> lookup(base) || group
          group -> group
          true -> lookup(base)
        end
    end
  end

  defp current_name(base) do
    case Map.fetch(@renamed, base) do
      {:ok, renamed} ->
        renamed

      :error ->
        case Regex.run(~r/^flex-(grow|shrink)-(.+)$/, base) do
          [_, utility, value] -> "#{utility}-#{value}"
          nil -> base
        end
    end
  end

  # Only a slash outside brackets starts a modifier, as in bg-primary/90.
  defp postfix_index(base) do
    {index, _depth} =
      base
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.reduce({nil, 0}, fn
        {c, _i}, {index, depth} when c in [?[, ?(] -> {index, depth + 1}
        {c, _i}, {index, depth} when c in [?], ?)] -> {index, depth - 1}
        {?/, i}, {_index, 0} -> {i, 0}
        _, acc -> acc
      end)

    index
  end

  defp lookup(base) do
    if String.starts_with?(base, "[") and String.ends_with?(base, "]") do
      arbitrary_property_group(base)
    else
      parts = String.split(base, "-")
      start = if hd(parts) == "" and length(parts) > 1, do: 1, else: 0
      walk(parts, start)
    end
  end

  defp arbitrary_property_group(base) do
    content = String.slice(base, 1..-2//1)

    case :binary.match(content, ":") do
      {colon, _} when colon > 0 -> @arbitrary_property_prefix <> binary_part(content, 0, colon)
      _ -> nil
    end
  end

  # tailwind-merge's search order: exact parts as deep as they go, then
  # validators on the tail, from the deepest node back up.
  defp walk(parts, start) do
    tail = Enum.drop(parts, start)
    depth = exact_depth(tail, [], 0)
    path = Enum.take(tail, depth)

    level =
      if depth == length(tail) do
        case Map.fetch!(@nodes, path) do
          {group, _} when group != nil -> {:found, group}
          # An exact match with no group has an empty tail to validate.
          _ -> depth - 1
        end
      else
        depth
      end

    case level do
      {:found, group} -> group
      level -> validate(tail, level)
    end
  end

  defp exact_depth([part | rest], path, depth) do
    next = path ++ [part]
    if Map.has_key?(@nodes, next), do: exact_depth(rest, next, depth + 1), else: depth
  end

  defp exact_depth([], _path, depth), do: depth

  defp validate(_tail, level) when level < 0, do: nil

  defp validate(tail, level) do
    {_group, validators} = Map.fetch!(@nodes, Enum.take(tail, level))
    rest = tail |> Enum.drop(level) |> Enum.join("-")

    case Enum.find(validators, fn {name, _group} -> Validators.check(name, rest) end) do
      {_name, group} -> group
      nil -> validate(tail, level - 1)
    end
  end
end

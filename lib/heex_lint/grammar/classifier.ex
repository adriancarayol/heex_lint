defmodule HeexLint.Grammar.Classifier do
  @moduledoc """
  Classifies a Tailwind class into its class group, such as `p`, `bg-color`
  or `font-size`.

  The grammar is the default config of [cn](https://github.com/shadcn-ui/cn)
  0.4.0 (MIT), vendored in `priv/cn_config.json`. The lookup mirrors
  tailwind-merge's class map: a trie keyed by `-`-split parts, built in
  config order, where exact parts go as deep as they can and validators are
  tried on the rest from the deepest node back up.

  The trie for cn's own config is built at compile time. A theme that
  declares scales gets its own from `grammar/1`, the way cn's `mergeConfigs`
  applies them: the whole config is walked again, because a default scale is
  often a validator rather than a list of names, and a later group wins an
  exact path.

      iex> HeexLint.Grammar.Classifier.group_of("md:hover:text-sm")
      "font-size"
      iex> HeexLint.Grammar.Classifier.group_of("text-red-500")
      "text-color"
      iex> HeexLint.Grammar.Classifier.group_of("unknown-thing")
      nil
  """

  alias HeexLint.Grammar.{Categories, Classes, ThemeScales, Trie, Validators}

  @config_path Path.expand("../../../priv/cn_config.json", __DIR__)
  @external_resource @config_path

  # The cn version this grammar comes from.
  @cn_version "0.4.0"

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

  @theme theme
  @class_groups class_groups
  @nodes Trie.build(class_groups, theme)
  @groups Enum.map(class_groups, &elem(&1, 0))
  @postfix_lookup_groups MapSet.new(Map.get(config, "postfixLookupClassGroups", []))

  @doc "The cn version the grammar comes from."
  def cn_version, do: @cn_version

  @doc "Every class group id, in config order."
  @spec groups() :: [String.t()]
  def groups, do: @groups

  @doc """
  The class map with a theme's scales applied, or `nil` when they change
  nothing and cn's own applies. Replaced scales go first and extended ones
  after, as in cn's `mergeConfigs`.
  """
  @spec grammar(ThemeScales.t()) :: Trie.t() | nil
  def grammar(%{extend: extend, override: override})
      when map_size(extend) == 0 and map_size(override) == 0,
      do: nil

  def grammar(%{extend: extend, override: override}) do
    theme =
      @theme
      |> Map.merge(override)
      |> Map.merge(extend, fn _scale, defaults, names -> defaults ++ names end)

    Trie.build(@class_groups, theme)
  end

  @doc """
  The class group of `token`, ignoring its variants and important marker,
  or `nil` when `grammar` does not recognize it. Without a grammar, cn's own.
  """
  @spec group_of(String.t(), Trie.t() | nil) :: String.t() | nil
  def group_of(token, grammar \\ nil)

  def group_of(token, nil), do: group_of(token, @nodes)

  def group_of(token, nodes) do
    base = token |> String.trim() |> Classes.split_variants() |> elem(1)

    base =
      cond do
        String.ends_with?(base, "!") -> String.slice(base, 0..-2//1)
        String.starts_with?(base, "!") -> String.slice(base, 1..-1//1)
        true -> base
      end

    if base == "", do: nil, else: classify(current_name(base), nodes)
  end

  defp classify(base, nodes) do
    case postfix_index(base) do
      nil ->
        lookup(base, nodes)

      slash ->
        # Without the modifier first, so text-sm/6 stays font-size instead
        # of reaching text-color's catch-all.
        group = lookup(binary_part(base, 0, slash), nodes)

        cond do
          group && MapSet.member?(@postfix_lookup_groups, group) -> lookup(base, nodes) || group
          group -> group
          true -> lookup(base, nodes)
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

  defp lookup(base, nodes) do
    if String.starts_with?(base, "[") and String.ends_with?(base, "]") do
      arbitrary_property_group(base)
    else
      parts = String.split(base, "-")
      start = if hd(parts) == "" and length(parts) > 1, do: 1, else: 0
      walk(parts, start, nodes)
    end
  end

  defp arbitrary_property_group(base) do
    content = String.slice(base, 1..-2//1)

    case :binary.match(content, ":") do
      {colon, _} when colon > 0 -> Categories.property_group(binary_part(content, 0, colon))
      _ -> nil
    end
  end

  # tailwind-merge's search order: exact parts as deep as they go, then
  # validators on the tail, from the deepest node back up.
  defp walk(parts, start, nodes) do
    tail = Enum.drop(parts, start)
    depth = exact_depth(tail, [], 0, nodes)
    path = Enum.take(tail, depth)

    level =
      if depth == length(tail) do
        case Map.fetch!(nodes, path) do
          {group, _} when group != nil -> {:found, group}
          # An exact match with no group has an empty tail to validate.
          _ -> depth - 1
        end
      else
        depth
      end

    case level do
      {:found, group} -> group
      level -> validate(tail, level, nodes)
    end
  end

  defp exact_depth([part | rest], path, depth, nodes) do
    next = path ++ [part]
    if Map.has_key?(nodes, next), do: exact_depth(rest, next, depth + 1, nodes), else: depth
  end

  defp exact_depth([], _path, depth, _nodes), do: depth

  defp validate(_tail, level, _nodes) when level < 0, do: nil

  defp validate(tail, level, nodes) do
    {_group, validators} = Map.fetch!(nodes, Enum.take(tail, level))
    rest = tail |> Enum.drop(level) |> Enum.join("-")

    case Enum.find(validators, fn {name, _group} -> Validators.check(name, rest) end) do
      {_name, group} -> group
      nil -> validate(tail, level - 1, nodes)
    end
  end
end

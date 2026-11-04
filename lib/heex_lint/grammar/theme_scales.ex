defmodule HeexLint.Grammar.ThemeScales do
  @moduledoc """
  The theme scales a project declares, the way `cn build` registers them:
  `--radius-card` in `@theme` adds `card` to the radius scale, and
  `--radius-*: initial` replaces the default scale with the declared names.

  Ported from @shadcn/lint's `src/project/theme-scales.ts` (MIT).
  """

  @typedoc """
  A cn config extension. Scales under `extend` add their names to cn's
  defaults; scales under `override` replace them.
  """
  @type t :: %{extend: %{String.t() => [String.t()]}, override: %{String.t() => [String.t()]}}

  # Tailwind namespace to cn theme scale, each named the same. Longest first,
  # so `--text-shadow-x` is a text shadow and `--font-weight-x` a weight.
  # `--color-*` and `--font-*` are left out: cn already accepts any name on
  # those scales.
  @namespaces ~w(
    inset-shadow drop-shadow text-shadow font-weight perspective breakpoint
    container tracking spacing leading animate radius shadow aspect blur ease
    text
  )

  @doc """
  The extension `declarations` make, read in cascade order: a reset drops what
  was declared before it, as in Tailwind.

      iex> HeexLint.Grammar.ThemeScales.of([
      ...>   %{name: "radius-*", value: "initial", theme: true},
      ...>   %{name: "radius-card", value: "1px", theme: true},
      ...>   %{name: "shadow-soft", value: "none", theme: true}
      ...> ])
      %{extend: %{"shadow" => ["soft"]}, override: %{"radius" => ["card"]}}
  """
  @spec of([%{name: String.t(), value: String.t(), theme: boolean()}]) :: t()
  def of(declarations) do
    {names, reset} =
      declarations
      |> Enum.filter(& &1.theme)
      |> Enum.with_index()
      |> Enum.reduce({%{}, MapSet.new()}, &apply_declaration/2)

    names = Map.new(names, fn {scale, declared} -> {scale, in_declared_order(declared)} end)

    %{
      extend: Map.reject(names, fn {scale, _names} -> MapSet.member?(reset, scale) end),
      override: Map.new(reset, &{&1, Map.get(names, &1, [])})
    }
  end

  # A scale's names as `%{name => when it was declared}` while they are read.
  defp in_declared_order(declared) do
    declared |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))
  end

  defp apply_declaration({%{name: "*", value: value}, _at}, read) do
    if initial?(value), do: Enum.reduce(@namespaces, read, &reset_scale/2), else: read
  end

  # `--spacing` is the base Tailwind multiplies for `p-4` and the rest of the
  # numeric scale, so setting it after a reset brings that scale back. Named
  # spacing values declared after it still extend.
  defp apply_declaration({%{name: "spacing", value: value}, _at}, {names, reset}) do
    if initial?(value), do: {names, reset}, else: {names, MapSet.delete(reset, "spacing")}
  end

  defp apply_declaration({%{name: property, value: value}, at}, read) do
    case Enum.find(@namespaces, &String.starts_with?(property, &1 <> "-")) do
      nil ->
        read

      scale ->
        apply_name(
          scale,
          String.replace_prefix(property, scale <> "-", ""),
          initial?(value),
          at,
          read
        )
    end
  end

  defp apply_name(scale, "*", true, _at, read), do: reset_scale(scale, read)
  defp apply_name(_scale, "*", false, _at, read), do: read
  defp apply_name(_scale, "", _initial, _at, read), do: read

  defp apply_name(scale, name, initial, at, {names, reset} = read) do
    declared = Map.get(names, scale)

    cond do
      # `--text-display--line-height` is a sub-property of `display`.
      String.contains?(name, "--") -> read
      initial and declared == nil -> read
      initial -> {Map.put(names, scale, Map.delete(declared, name)), reset}
      declared == nil -> {Map.put(names, scale, %{name => at}), reset}
      true -> {Map.put(names, scale, Map.put_new(declared, name, at)), reset}
    end
  end

  defp reset_scale(scale, {names, reset}),
    do: {Map.delete(names, scale), MapSet.put(reset, scale)}

  defp initial?(value), do: String.trim(value) == "initial"
end

defmodule HeexLint.Color do
  @moduledoc """
  Parses CSS colors into OKLab so theme colors can be ranked by how close they
  look to a raw palette color.

  Supports hex (`#fff`, `#ffffff`, with or without alpha), `rgb()`/`rgba()` and
  `oklch()`. Anything else returns `nil`.
  """

  @type oklab :: {float(), float(), float()}

  @spec parse(String.t()) :: oklab() | nil
  def parse(value) do
    value = value |> String.trim() |> String.downcase()

    cond do
      String.starts_with?(value, "#") -> hex(String.trim_leading(value, "#"))
      String.starts_with?(value, "rgb") -> rgb(value)
      String.starts_with?(value, "oklch(") -> oklch(value)
      true -> nil
    end
  end

  @doc """
  Perceptual distance between two OKLab colors.
  """
  @spec distance(oklab(), oklab()) :: float()
  def distance({l1, a1, b1}, {l2, a2, b2}),
    do: :math.sqrt(:math.pow(l1 - l2, 2) + :math.pow(a1 - a2, 2) + :math.pow(b1 - b2, 2))

  defp hex(<<r, g, b>>), do: hex(<<r, r, g, g, b, b>>)
  defp hex(<<r, g, b, _a>>), do: hex(<<r, r, g, g, b, b>>)
  defp hex(<<rgb::binary-size(6), _alpha::binary-size(2)>>), do: hex(rgb)

  defp hex(<<r::binary-size(2), g::binary-size(2), b::binary-size(2)>>) do
    with {r, ""} <- Integer.parse(r, 16),
         {g, ""} <- Integer.parse(g, 16),
         {b, ""} <- Integer.parse(b, 16) do
      srgb(r / 255, g / 255, b / 255)
    else
      _ -> nil
    end
  end

  defp hex(_), do: nil

  defp rgb(value) do
    case numbers(value) do
      [r, g, b | _] -> srgb(r / 255, g / 255, b / 255)
      _ -> nil
    end
  end

  defp oklch(value) do
    case numbers(value) do
      [l, c, h | _] ->
        l = if String.contains?(value, "%"), do: l / 100, else: l
        radians = h * :math.pi() / 180
        {l, c * :math.cos(radians), c * :math.sin(radians)}

      _ ->
        nil
    end
  end

  # CSS `none` components (as in `oklch(98.5% 0 none)`) count as zero.
  defp numbers(value) do
    ~r/-?\d*\.?\d+/
    |> Regex.scan(String.replace(value, "none", "0"))
    |> Enum.map(fn [n] -> n |> Float.parse() |> elem(0) end)
  end

  defp srgb(r, g, b) do
    [r, g, b] = Enum.map([r, g, b], &linear/1)

    l = :math.pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1 / 3)
    m = :math.pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1 / 3)
    s = :math.pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1 / 3)

    {
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }
  end

  defp linear(c) when c <= 0.04045, do: c / 12.92
  defp linear(c), do: :math.pow((c + 0.055) / 1.055, 2.4)
end

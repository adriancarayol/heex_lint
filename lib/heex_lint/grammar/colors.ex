defmodule HeexLint.Grammar.Colors do
  @moduledoc """
  CSS color parsing into OKLab, so a raw color can be compared with the
  theme's tokens. OKLab is perceptually uniform enough that a plain
  Euclidean distance says whether two colors are "the same gray" or "the
  same red". Ported from @shadcn/lint's `src/grammar/colors.ts` (MIT).
  """

  @type lab :: {float(), float(), float()}

  # The CSS named colors, as sRGB hex.
  @named %{
    "aliceblue" => "#f0f8ff",
    "antiquewhite" => "#faebd7",
    "aqua" => "#00ffff",
    "aquamarine" => "#7fffd4",
    "azure" => "#f0ffff",
    "beige" => "#f5f5dc",
    "bisque" => "#ffe4c4",
    "black" => "#000000",
    "blanchedalmond" => "#ffebcd",
    "blue" => "#0000ff",
    "blueviolet" => "#8a2be2",
    "brown" => "#a52a2a",
    "burlywood" => "#deb887",
    "cadetblue" => "#5f9ea0",
    "chartreuse" => "#7fff00",
    "chocolate" => "#d2691e",
    "coral" => "#ff7f50",
    "cornflowerblue" => "#6495ed",
    "cornsilk" => "#fff8dc",
    "crimson" => "#dc143c",
    "cyan" => "#00ffff",
    "darkblue" => "#00008b",
    "darkcyan" => "#008b8b",
    "darkgoldenrod" => "#b8860b",
    "darkgray" => "#a9a9a9",
    "darkgreen" => "#006400",
    "darkgrey" => "#a9a9a9",
    "darkkhaki" => "#bdb76b",
    "darkmagenta" => "#8b008b",
    "darkolivegreen" => "#556b2f",
    "darkorange" => "#ff8c00",
    "darkorchid" => "#9932cc",
    "darkred" => "#8b0000",
    "darksalmon" => "#e9967a",
    "darkseagreen" => "#8fbc8f",
    "darkslateblue" => "#483d8b",
    "darkslategray" => "#2f4f4f",
    "darkslategrey" => "#2f4f4f",
    "darkturquoise" => "#00ced1",
    "darkviolet" => "#9400d3",
    "deeppink" => "#ff1493",
    "deepskyblue" => "#00bfff",
    "dimgray" => "#696969",
    "dimgrey" => "#696969",
    "dodgerblue" => "#1e90ff",
    "firebrick" => "#b22222",
    "floralwhite" => "#fffaf0",
    "forestgreen" => "#228b22",
    "fuchsia" => "#ff00ff",
    "gainsboro" => "#dcdcdc",
    "ghostwhite" => "#f8f8ff",
    "gold" => "#ffd700",
    "goldenrod" => "#daa520",
    "gray" => "#808080",
    "green" => "#008000",
    "greenyellow" => "#adff2f",
    "grey" => "#808080",
    "honeydew" => "#f0fff0",
    "hotpink" => "#ff69b4",
    "indianred" => "#cd5c5c",
    "indigo" => "#4b0082",
    "ivory" => "#fffff0",
    "khaki" => "#f0e68c",
    "lavender" => "#e6e6fa",
    "lavenderblush" => "#fff0f5",
    "lawngreen" => "#7cfc00",
    "lemonchiffon" => "#fffacd",
    "lightblue" => "#add8e6",
    "lightcoral" => "#f08080",
    "lightcyan" => "#e0ffff",
    "lightgoldenrodyellow" => "#fafad2",
    "lightgray" => "#d3d3d3",
    "lightgreen" => "#90ee90",
    "lightgrey" => "#d3d3d3",
    "lightpink" => "#ffb6c1",
    "lightsalmon" => "#ffa07a",
    "lightseagreen" => "#20b2aa",
    "lightskyblue" => "#87cefa",
    "lightslategray" => "#778899",
    "lightslategrey" => "#778899",
    "lightsteelblue" => "#b0c4de",
    "lightyellow" => "#ffffe0",
    "lime" => "#00ff00",
    "limegreen" => "#32cd32",
    "linen" => "#faf0e6",
    "magenta" => "#ff00ff",
    "maroon" => "#800000",
    "mediumaquamarine" => "#66cdaa",
    "mediumblue" => "#0000cd",
    "mediumorchid" => "#ba55d3",
    "mediumpurple" => "#9370db",
    "mediumseagreen" => "#3cb371",
    "mediumslateblue" => "#7b68ee",
    "mediumspringgreen" => "#00fa9a",
    "mediumturquoise" => "#48d1cc",
    "mediumvioletred" => "#c71585",
    "midnightblue" => "#191970",
    "mintcream" => "#f5fffa",
    "mistyrose" => "#ffe4e1",
    "moccasin" => "#ffe4b5",
    "navajowhite" => "#ffdead",
    "navy" => "#000080",
    "oldlace" => "#fdf5e6",
    "olive" => "#808000",
    "olivedrab" => "#6b8e23",
    "orange" => "#ffa500",
    "orangered" => "#ff4500",
    "orchid" => "#da70d6",
    "palegoldenrod" => "#eee8aa",
    "palegreen" => "#98fb98",
    "paleturquoise" => "#afeeee",
    "palevioletred" => "#db7093",
    "papayawhip" => "#ffefd5",
    "peachpuff" => "#ffdab9",
    "peru" => "#cd853f",
    "pink" => "#ffc0cb",
    "plum" => "#dda0dd",
    "powderblue" => "#b0e0e6",
    "purple" => "#800080",
    "rebeccapurple" => "#663399",
    "red" => "#ff0000",
    "rosybrown" => "#bc8f8f",
    "royalblue" => "#4169e1",
    "saddlebrown" => "#8b4513",
    "salmon" => "#fa8072",
    "sandybrown" => "#f4a460",
    "seagreen" => "#2e8b57",
    "seashell" => "#fff5ee",
    "sienna" => "#a0522d",
    "silver" => "#c0c0c0",
    "skyblue" => "#87ceeb",
    "slateblue" => "#6a5acd",
    "slategray" => "#708090",
    "slategrey" => "#708090",
    "snow" => "#fffafa",
    "springgreen" => "#00ff7f",
    "steelblue" => "#4682b4",
    "tan" => "#d2b48c",
    "teal" => "#008080",
    "thistle" => "#d8bfd8",
    "tomato" => "#ff6347",
    "turquoise" => "#40e0d0",
    "violet" => "#ee82ee",
    "wheat" => "#f5deb3",
    "white" => "#ffffff",
    "whitesmoke" => "#f5f5f5",
    "yellow" => "#ffff00",
    "yellowgreen" => "#9acd32"
  }

  @doc """
  Whether `value` is one of the CSS named colors, such as `red`.
  """
  @spec named_color?(String.t()) :: boolean()
  def named_color?(value), do: Map.has_key?(@named, value |> String.trim() |> String.downcase())

  @doc """
  Parses a CSS color into OKLab, or `nil` for anything that is not a literal
  color (variables, `color-mix()`, keywords such as `currentColor`).

      iex> HeexLint.Grammar.Colors.parse("#fff") |> elem(0) |> Float.round(3)
      1.0
      iex> HeexLint.Grammar.Colors.parse("var(--x)")
      nil
  """
  @spec parse(String.t()) :: lab() | nil
  def parse(value) do
    text = value |> String.trim() |> String.downcase()

    cond do
      text == "" -> nil
      String.starts_with?(text, "#") -> from_hex(text)
      Map.has_key?(@named, text) -> from_hex(Map.fetch!(@named, text))
      true -> function(text)
    end
  end

  @doc """
  Perceptual distance between two colors: roughly, under 0.02 is the same
  color and under 0.1 the same family.
  """
  @spec distance(lab(), lab()) :: float()
  def distance({l1, a1, b1}, {l2, a2, b2}) do
    :math.sqrt((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2))
  end

  defp function(text) do
    with [_, fun, inner] <- Regex.run(~r/^([a-z]+)\((.*)\)$/s, text),
         parts when length(parts) >= 3 <- args(inner) do
      from_function(fun, parts, inner)
    else
      _ -> nil
    end
  end

  defp from_function(fun, parts, _inner) when fun in ["rgb", "rgba"] do
    with [r, g, b] <- channels(parts, [{255, 1}, {255, 1}, {255, 1}]), do: from_rgb(r, g, b)
  end

  defp from_function(fun, parts, _inner) when fun in ["hsl", "hsla"] do
    with [h, s, l] <- channels(parts, [{1, 1}, {100, 1}, {100, 1}]), do: from_hsl(h, s, l)
  end

  defp from_function("hwb", parts, _inner) do
    with [h, w, b] <- channels(parts, [{1, 1}, {100, 1}, {100, 1}]), do: from_hwb(h, w, b)
  end

  defp from_function("oklch", parts, _inner) do
    with [l, c, h] <- channels(parts, [{1, 1}, {1, 0.4}, {1, 1}]) do
      radians = h * :math.pi() / 180
      {l, c * :math.cos(radians), c * :math.sin(radians)}
    end
  end

  defp from_function("oklab", parts, _inner) do
    with [l, a, b] <- channels(parts, [{1, 1}, {1, 0.4}, {1, 0.4}]), do: {l, a, b}
  end

  defp from_function("color", ["srgb" | _], inner) do
    rest = inner |> String.replace(~r/^\s*srgb\s+/, "") |> args()

    case channels(rest, [{1, 1}, {1, 1}, {1, 1}]) do
      [r, g, b] -> from_rgb(r, g, b)
      _ -> nil
    end
  end

  defp from_function(_fun, _parts, _inner), do: nil

  # The arguments of a color function, with the alpha channel dropped.
  # Accepts both the modern space syntax and the legacy comma syntax.
  defp args(inner) do
    inner
    |> String.split("/")
    |> hd()
    |> String.trim()
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.take(3)
  end

  defp channels(parts, scales) do
    values =
      parts
      |> Enum.take(3)
      |> Enum.zip(scales)
      |> Enum.map(fn {raw, {scale, percent}} -> channel(raw, scale, percent) end)

    if length(values) == 3 and Enum.all?(values, &is_number/1), do: values, else: nil
  end

  # CSS `none` is a missing channel, computed as zero. Tailwind's own theme
  # writes it for achromatic entries: oklch(55.6% 0 none).
  defp channel("none", _scale, _percent), do: 0.0

  defp channel(raw, scale, percent) do
    if String.ends_with?(raw, "%") do
      case number(String.slice(raw, 0..-2//1)) do
        nil -> nil
        value -> value / 100 * percent
      end
    else
      case number(String.replace(raw, ~r/deg$/, "")) do
        nil -> nil
        value -> value / scale
      end
    end
  end

  # JavaScript's Number() for a channel, finite values only.
  defp number(text) do
    case HeexLint.Grammar.Validators.js_number(text) do
      value when is_float(value) -> value
      _ -> nil
    end
  end

  defp from_hex("#" <> digits) do
    digits =
      if String.length(digits) in [3, 4],
        do: digits |> String.graphemes() |> Enum.map_join(&(&1 <> &1)),
        else: digits

    with true <- String.length(digits) in [6, 8],
         true <- Regex.match?(~r/^[0-9a-f]+$/i, digits),
         {n, ""} <- Integer.parse(String.slice(digits, 0, 6), 16) do
      import Bitwise
      from_rgb((n >>> 16 &&& 255) / 255, (n >>> 8 &&& 255) / 255, (n &&& 255) / 255)
    else
      _ -> nil
    end
  end

  defp linear(c) when c <= 0.04045, do: c / 12.92
  defp linear(c), do: :math.pow((c + 0.055) / 1.055, 2.4)

  defp cbrt(x) when x < 0, do: -:math.pow(-x, 1 / 3)
  defp cbrt(x), do: :math.pow(x, 1 / 3)

  defp from_rgb(r, g, b) do
    lr = linear(r)
    lg = linear(g)
    lb = linear(b)
    l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
    m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
    s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)

    {0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
     1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
     0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s}
  end

  defp hsl_to_rgb(h, s, l) do
    a = s * min(l, 1 - l)

    f = fn n ->
      k = fmod(n + h / 30, 12)
      l - a * max(-1, Enum.min([k - 3, 9 - k, 1]))
    end

    {f.(0), f.(8), f.(4)}
  end

  # JavaScript's %, which keeps the sign of the dividend.
  defp fmod(a, b), do: a - b * trunc(a / b)

  defp from_hsl(h, s, l) do
    {r, g, b} = hsl_to_rgb(h, s, l)
    from_rgb(r, g, b)
  end

  defp from_hwb(h, w, b) do
    if w + b >= 1 do
      gray = w / (w + b)
      from_rgb(gray, gray, gray)
    else
      {r, g, bl} = hsl_to_rgb(h, 1, 0.5)
      scale = fn c -> c * (1 - w - b) + w end
      from_rgb(scale.(r), scale.(g), scale.(bl))
    end
  end
end

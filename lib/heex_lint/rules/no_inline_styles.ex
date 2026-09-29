defmodule HeexLint.Rules.NoInlineStyles do
  @moduledoc """
  Reports `style` attributes and `<style>` elements.

  Setting CSS custom properties is allowed, since that is how runtime values
  reach classes: `style={"--progress: \#{@percent}%"}` with `w-(--progress)`.

  ## Options

    * `:allow` - CSS properties that may be set inline, such as `["view-transition-name"]`.
    * `:allow_custom_properties` - allow `--*` properties (default `true`).
    * `:message` - a custom message. Placeholders: `{{property}}`, `{{theme}}`.
  """

  @behaviour HeexLint.Rule

  alias HeexLint.{Element, Rule, Value}

  @impl true
  def name, do: :no_inline_styles

  @impl true
  def check(%Element{type: :tag, name: "style"} = element, context) do
    default =
      "<style> elements bypass the design system. Use Tailwind classes, or put shared CSS in #{Rule.theme_file(context)}."

    [
      {{element.line, element.column},
       Rule.message(context, default, property: "", theme: Rule.theme_file(context))}
    ]
  end

  def check(%Element{} = element, context) do
    for %{name: "style", value: value} <- element.attributes,
        items <- Value.strings(value, element.indentation),
        finding <- findings(items, context),
        do: finding
  end

  defp findings([{:dynamic, position}], context) do
    default =
      "Inline style is set from a runtime value, which bypasses the design system. " <>
        "Style with classes; for runtime values set a CSS variable (style={\"--size: \#{@size}\"}) and read it with a class such as w-(--size)."

    [{position, Rule.message(context, default, property: "", theme: Rule.theme_file(context))}]
  end

  defp findings(items, context) do
    for {property, position} <- properties(items), not allowed?(property, context.options) do
      default =
        "Inline style sets #{property}. Style with Tailwind classes instead; " <>
          "for runtime values set a CSS variable (style=\"--size: 40%\") and read it with a class such as w-(--size)."

      {position,
       Rule.message(context, default, property: property, theme: Rule.theme_file(context))}
    end
  end

  # Finds `property:` at the start of each declaration.
  defp properties(items) do
    chars = Enum.map(items, &char/1)
    text = Enum.join(chars)

    ~r/(?:^|;)\s*([-a-zA-Z]+)\s*:/
    |> Regex.scan(text, return: :index, capture: :all_but_first)
    |> Enum.map(fn [{start, length}] ->
      property = binary_part(text, start, length)
      # Every item is one grapheme, so the character index is the item index.
      index = text |> binary_part(0, start) |> String.length()
      {String.downcase(property), position(Enum.at(items, index))}
    end)
  end

  defp char({:char, char, _}), do: char
  # A placeholder that can never start a property name.
  defp char(_), do: "\u0000"

  defp position({:char, _, position}), do: position
  defp position({_, position}), do: position

  defp allowed?("--" <> _, options), do: Keyword.get(options, :allow_custom_properties, true)
  defp allowed?(property, options), do: property in Keyword.get(options, :allow, [])
end

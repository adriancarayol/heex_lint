defmodule HeexLint.Rules.NoInlineStyles do
  @moduledoc """
  Use classes for styling, and pass dynamic values through CSS custom
  properties when a class needs them. Reports ordinary inline properties,
  hardcoded colors in custom properties, style values that cannot be read,
  and `<style>` elements.

      <div style="color: red">                    Inline style sets color...
      <div style={"--tone: #ec4899"}>            Custom property --tone hardcodes a color...
      <div style={@style}>                       Dynamic style object cannot be checked...
      <div class="w-(--width)" style={"--width: \#{@width}px"}>   allowed

  A function component forwarding the `style` it received is allowed; its
  authored default is still checked.

  ## Options

    * `:allow` - CSS property names exempt from the check (`transform`,
      `border-*`, `--*`). An allowed property is not checked further.
    * `:deny` - removes exemptions; without `:allow`, exempts every other property.
    * `:contracts` - property policies for components, matched on the name
      as written (`button` for `<.button>`, `Layouts.app`). HTML elements
      take the top-level policy.
    * `:message` - replaces the text. `{{property}}` is the property.
  """

  @behaviour HeexLint.Rule

  alias HeexLint.{Grammar.Colors, Policy, Rule}
  alias HeexLint.Policy.ConfigError

  @messages %{
    inline_style:
      "Inline style sets {{property}}. Style through classes; use CSS custom properties for dynamic values.",
    dynamic_style:
      "Dynamic style object cannot be checked. Build it from CSS custom properties only.",
    custom_prop_color:
      "Custom property {{property}} hardcodes a color. Define it as a theme token instead of injecting a raw value.",
    style_element:
      "A <style> element injects CSS outside the design system. Use classes, or declare the rule in your theme CSS."
  }

  @color_function ~r/#[0-9a-f]{3,8}\b|\b(?:rgb|rgba|hsl|hsla|hwb|oklch|oklab|lab|lch|color|color-mix|light-dark)\(/i

  @impl true
  def name, do: :no_inline_styles

  @impl true
  def prepare(options, _project) do
    {:ok, compile(options), []}
  rescue
    error in ConfigError -> {:error, error.message}
  end

  @impl true
  def check(file, policy, options) do
    style_elements =
      for {_template, elements} <- file.elements,
          element <- elements,
          element.type == :tag and element.name == "style",
          # Colocated CSS is bundled into the app's stylesheet, like a
          # single-file component's own <style> block.
          not HeexLint.Element.colocated_css?(element) do
        %{
          position: {element.line, element.column},
          message: Rule.message(@messages.style_element, %{}, nil, options, file)
        }
      end

    style_sites =
      for site <- file.sites,
          site.kind == :style,
          finding <- site_findings(site, policy, options, file),
          do: finding

    style_elements ++ style_sites
  end

  defp site_findings(site, policy, options, file) do
    component = site.written || ""

    dynamic =
      for position <- site.unresolved do
        data = %{"component" => Rule.display(component)}

        %{
          position: position,
          message:
            Rule.message(
              @messages.dynamic_style,
              data,
              words_for(policy, component),
              options,
              file
            )
        }
      end

    declarations =
      for string <- site.strings,
          {property, value, position} <- declarations(string),
          finding = judge(property, value, position, component, policy, options, file),
          finding != nil,
          do: finding

    dynamic ++ declarations
  end

  defp judge(property, value, position, component, policy, options, file) do
    {exempt, words} = decide(policy, component, property)

    message =
      cond do
        exempt -> nil
        not String.starts_with?(property, "--") -> @messages.inline_style
        raw_color?(value) -> @messages.custom_prop_color
        true -> nil
      end

    if message do
      data = %{"property" => property, "component" => Rule.display(component)}
      %{position: position, message: Rule.message(message, data, words, options, file)}
    end
  end

  # Declarations of a style attribute. A `;` inside quotes or parentheses is
  # part of the value.
  defp declarations(%{items: items}) do
    items
    |> split_declarations()
    |> Enum.flat_map(fn declaration ->
      text = Enum.map_join(declaration, &char/1)

      case :binary.match(text, ":") do
        {colon, _} ->
          property_text = binary_part(text, 0, colon)
          property = String.trim(property_text)

          if property == "" do
            []
          else
            leading =
              String.length(property_text) - String.length(String.trim_leading(property_text))

            position = declaration |> Enum.at(leading) |> position_of()
            value = binary_part(text, colon + 1, byte_size(text) - colon - 1)
            [{property, value, position}]
          end

        :nomatch ->
          []
      end
    end)
  end

  defp split_declarations(items) do
    {done, current, _depth, _quote} =
      Enum.reduce(items, {[], [], 0, nil}, fn item, {done, current, depth, quote} ->
        c = char(item)

        cond do
          quote != nil and c == quote -> {done, current ++ [item], depth, nil}
          quote != nil -> {done, current ++ [item], depth, quote}
          c in [~s("), "'"] -> {done, current ++ [item], depth, c}
          c == "(" -> {done, current ++ [item], depth + 1, nil}
          c == ")" -> {done, current ++ [item], max(depth - 1, 0), nil}
          c == ";" and depth == 0 -> {done ++ [current], [], depth, nil}
          true -> {done, current ++ [item], depth, nil}
        end
      end)

    done ++ [current]
  end

  defp char({:char, c, _}), do: c
  defp char({:interp, _}), do: "￼"

  defp position_of({:char, _, position}), do: position
  defp position_of({:interp, position}), do: position
  defp position_of(nil), do: {1, 1}

  @doc false
  # The value, or any leaf of it outside var(), read as a color. URL
  # payloads, quoted strings and comments are not color values.
  def raw_color?(value) do
    text = color_value_text(value)

    Regex.match?(@color_function, text) or Colors.parse(text) != nil or
      text
      |> String.replace(~r/var\([^)]*\)/i, " ")
      |> String.split(~r/[\s,()\/]+/)
      |> Enum.any?(&(&1 != "" and Colors.parse(&1) != nil))
  end

  defp color_value_text(value), do: color_text(value, "", nil, 0, nil)

  # Mirrors @shadcn/lint's colorValueText: `prev` is the previous character
  # of the original value, for the url( word boundary.
  defp color_text("", acc, _quote, _url, _prev), do: acc

  defp color_text(<<c::utf8, rest::binary>>, acc, quote, url, _prev) when quote != nil do
    cond do
      c == ?\\ ->
        case rest do
          <<next::utf8, rest::binary>> -> color_text(rest, acc, quote, url, next)
          "" -> acc
        end

      c == quote ->
        color_text(rest, acc, nil, url, c)

      true ->
        color_text(rest, acc, quote, url, c)
    end
  end

  defp color_text("/*" <> rest, acc, nil, url, _prev) do
    case :binary.match(rest, "*/") do
      {pos, 2} ->
        color_text(
          binary_part(rest, pos + 2, byte_size(rest) - pos - 2),
          acc <> " ",
          nil,
          url,
          ?/
        )

      :nomatch ->
        acc <> " "
    end
  end

  defp color_text(<<q::utf8, rest::binary>>, acc, nil, url, _prev) when q in [?", ?'],
    do: color_text(rest, acc <> " ", q, url, q)

  defp color_text(<<?\\, rest::binary>>, acc, nil, url, _prev) do
    case rest do
      <<c::utf8, rest::binary>> ->
        acc = if url == 0, do: acc <> "\\" <> <<c::utf8>>, else: acc
        color_text(rest, acc, nil, url, c)

      "" ->
        if url == 0, do: acc <> "\\", else: acc
    end
  end

  defp color_text(<<c::utf8, rest::binary>>, acc, nil, url, _prev) when url > 0 do
    url =
      case c do
        ?( -> url + 1
        ?) -> url - 1
        _ -> url
      end

    color_text(rest, acc, nil, url, c)
  end

  defp color_text(text, acc, nil, 0, prev) do
    boundary = prev == nil or not Regex.match?(~r/[\w-]/, <<prev::utf8>>)

    if boundary and String.downcase(String.slice(text, 0, 4)) == "url(" do
      color_text(String.slice(text, 4..-1//1), acc <> " ", nil, 1, ?()
    else
      <<c::utf8, rest::binary>> = text
      color_text(rest, acc <> <<c::utf8>>, nil, 0, c)
    end
  end

  ## Property policy

  defp compile(options) do
    top_allow =
      Policy.allow_list(%{allow: fetch(options, :allow), deny: fetch(options, :deny)}, nil)

    top_deny = fetch(options, :deny) || []

    baseline = %{
      allow:
        matcher(
          Policy.allow_list(%{allow: fetch(options, :allow), deny: fetch(options, :deny)}, nil)
        ),
      deny: matcher(top_deny),
      message: nil
    }

    contracts =
      options
      |> Keyword.get(:contracts, [])
      |> Enum.map(fn contract ->
        contract = Map.new(contract)

        pattern =
          case contract[:pattern] do
            %Regex{} = regex ->
              regex

            text when is_binary(text) ->
              case Regex.compile(text) do
                {:ok, regex} ->
                  regex

                {:error, _} ->
                  raise ConfigError,
                        ~s|Contract pattern "#{text}" is not a valid regular expression.|
              end

            other ->
              raise ConfigError, "Every contract needs a pattern, got: #{inspect(other)}"
          end

        allow = Map.get(contract, :allow)
        deny = Map.get(contract, :deny)

        %{
          pattern: pattern,
          allow: matcher(Policy.allow_list(%{allow: allow, deny: deny}, top_allow)),
          deny: matcher(deny || top_deny),
          message: contract[:message]
        }
      end)

    %{baseline: baseline, contracts: contracts}
  end

  defp fetch(options, key) do
    case Keyword.fetch(options, key) do
      {:ok, list} when is_list(list) -> list
      _ -> nil
    end
  end

  # Names or globs (border-*, --chart-*). The mistake this option invites
  # is a class, caught by shape: no standard property carries a digit.
  defp matcher(entries) do
    patterns =
      Enum.map(entries, fn entry ->
        custom = Regex.match?(~r/^--[\w*-]+$/, entry)

        if not custom and not Regex.match?(~r/^[a-zA-Z*][a-zA-Z*-]*$/, entry) do
          raise ConfigError,
                ~s|no_inline_styles: entry "#{entry}" is not a CSS property name (backgroundColor, background-color, border-*, --chart-1), so it would match nothing.|
        end

        Regex.compile!("^" <> String.replace(css_name(entry), "*", ".*") <> "$")
      end)

    fn property -> Enum.any?(patterns, &Regex.match?(&1, css_name(property))) end
  end

  # backgroundColor and background-color are one name; a custom property
  # is its own name.
  defp css_name("--" <> _ = name), do: name
  defp css_name(name), do: name |> String.replace(~r/[A-Z]/, "-\\0") |> String.downcase()

  defp policy_for(policy, ""), do: policy.baseline

  defp policy_for(policy, component) do
    policy.contracts
    |> Enum.reverse()
    |> Enum.find(policy.baseline, &Regex.match?(&1.pattern, component))
  end

  defp decide(policy, component, property) do
    rules = policy_for(policy, component)

    cond do
      rules.deny.(property) -> {false, rules.message}
      rules.allow.(property) -> {true, nil}
      true -> {false, rules.message}
    end
  end

  # The component's words for a finding about no single property.
  defp words_for(_policy, ""), do: nil
  defp words_for(policy, component), do: policy_for(policy, component).message
end

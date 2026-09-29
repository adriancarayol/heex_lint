defmodule HeexLint.Messages do
  @moduledoc """
  Rendering findings into messages, with the project's own words.
  Ported from @shadcn/lint's `src/rules/messages.ts` (MIT).

  A rule's `message` option (or a contract's) replaces the built-in text.
  Placeholders are written `{{key}}`, with an optional fallback for an
  empty value: `{{variants|none defined}}`. Unknown placeholders stay
  literal. Every finding offers `{{className}}` (also `{{class}}`),
  `{{property}}`, `{{component}}`, `{{suggestions}}` and `{{file}}`.
  The `note` setting is appended to every message.
  """

  alias HeexLint.Grammar.Similar

  @placeholder ~r/\{\{\s*([^{}|]+?)\s*(?:\|([^{}]*))?\}\}/
  @listed 12
  @max_length 500

  @keys ~w(
    className class property component suggestions file category variants wrapper
    sizes entries tokens suggestion replacement attribute value around where variantsSuffix
  )

  @doc "The placeholder names messages may use."
  def keys, do: @keys

  @doc "The longest custom message accepted."
  def max_length, do: @max_length

  @doc """
  Renders a finding. `builtin` is the rule's own text for it; `override`
  a contract's words; `rule_message` the rule's `message` option; `note`
  the shared note.
  """
  @spec render(String.t(), map(), String.t() | nil, String.t() | nil, String.t() | nil) ::
          String.t()
  def render(builtin, data, override \\ nil, rule_message \\ nil, note \\ nil) do
    text = present(override) || present(rule_message)
    note = present(note)

    if text == nil and note == nil do
      interpolate(builtin, data)
    else
      base = interpolate(text || builtin, universal(data))
      Enum.join(Enum.reject([base, note], &(&1 in [nil, ""])), " ")
    end
  end

  defp present(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil

  @doc """
  Replaces `{{key}}` and `{{key|fallback}}` with values from `data`. A key
  `data` does not have stays as written.
  """
  @spec interpolate(String.t(), map()) :: String.t()
  def interpolate(text, data) do
    Regex.replace(@placeholder, text, fn match, key, fallback ->
      case Map.fetch(data, key) do
        :error ->
          match

        {:ok, value} ->
          value = if value == nil, do: "", else: to_string(value)
          if value != "", do: value, else: String.trim(fallback || "")
      end
    end)
  end

  # The slots every finding offers, whatever the rule.
  defp universal(data) do
    first = fn keys -> Enum.find_value(keys, "", fn key -> non_empty(data[key]) end) end

    class_name =
      first.(["className"])
      |> then(
        &if(&1 == "" and data["attribute"],
          do: ~s(#{data["attribute"]}="#{data["value"]}"),
          else: &1
        )
      )

    Map.merge(data, %{
      "className" => class_name,
      "class" => class_name,
      "property" => first.(["property"]),
      "component" => first.(["component"]),
      "suggestions" => first.(["suggestions", "replacement", "suggestion"]),
      "file" => first.(["file"])
    })
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value), do: to_string(value)

  @doc """
  Warnings for placeholders that look like typos of a real one. Literal
  braces stay valid, so only near-misses warn.
  """
  @spec check(String.t(), String.t()) :: [String.t()]
  def check(message, label) do
    for [_, key | _] <- Regex.scan(@placeholder, message),
        key not in @keys,
        Regex.match?(~r/^[A-Za-z_$][\w$]*$/, key),
        nearest = nearest_key(key),
        nearest != nil do
      where =
        if String.contains?(label, "/") or String.starts_with?(label, "no_") or
             String.starts_with?(label, "require_"), do: label, else: ~s(contract "#{label}")

      ~s(Unknown message placeholder "{{#{key}}}" in #{where}. Did you mean "{{#{nearest}}}"? It will remain literal.)
    end
  end

  defp nearest_key(key) do
    {best, _} =
      Enum.reduce(@keys, {nil, 3}, fn candidate, {best, closest} ->
        d = Similar.edit_distance(String.downcase(key), String.downcase(candidate))

        cond do
          d < closest -> {candidate, d}
          d == closest -> {nil, closest}
          true -> {best, closest}
        end
      end)

    best
  end

  @doc """
  Lists declared tokens: foreground tokens last, up to twelve, then a count.
  """
  @spec list_tokens(Enumerable.t()) :: String.t()
  def list_tokens(declared) do
    sorted =
      Enum.sort(declared, fn a, b ->
        fa = if String.ends_with?(a, "-foreground"), do: 1, else: 0
        fb = if String.ends_with?(b, "-foreground"), do: 1, else: 0
        if fa != fb, do: fa < fb, else: a <= b
      end)

    {shown, rest} = Enum.split(sorted, @listed)
    list = Enum.join(shown, ", ")
    if rest != [], do: "#{list} (+#{length(rest)} more)", else: list
  end
end

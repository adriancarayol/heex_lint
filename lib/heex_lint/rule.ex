defmodule HeexLint.Rule do
  @moduledoc """
  A lint rule. Rules inspect one element at a time and return findings as
  `{position, message}` pairs; the runner turns them into diagnostics.

  The context passed to `check/2` has:

    * `:theme` - the `HeexLint.Theme`
    * `:options` - the rule's options from the config
    * `:class_attribute?` - a function telling whether an attribute name holds classes
  """

  alias HeexLint.{Element, Theme, Value}

  @type context :: %{
          theme: Theme.t(),
          options: keyword(),
          class_attribute?: (String.t() -> boolean())
        }

  @type finding :: {Value.position(), String.t()}

  @doc "The rule's name, as used in the config."
  @callback name() :: atom()

  @doc "Returns findings for `element`."
  @callback check(Element.t(), context()) :: [finding()]

  @doc """
  Returns the class tokens of every class attribute on `element`.
  """
  @spec class_tokens(Element.t(), context()) :: [
          {:static | :partial, String.t(), Value.position()}
        ]
  def class_tokens(%Element{} = element, context) do
    element.attributes
    |> Enum.filter(&(is_binary(&1.name) and context.class_attribute?.(&1.name)))
    |> Enum.flat_map(&(&1.value |> Value.strings(element.indentation) |> Value.tokens()))
  end

  @doc """
  Whether `class` matches one of the `patterns` in the rule's `:allow` option.

  Patterns are strings, where `*` matches any run of characters, or regexes.
  """
  @spec allowed?(String.t(), keyword()) :: boolean()
  def allowed?(class, options) do
    options
    |> Keyword.get(:allow, [])
    |> Enum.any?(fn
      %Regex{} = regex -> Regex.match?(regex, class)
      pattern -> Regex.match?(glob(pattern), class)
    end)
  end

  @doc """
  Returns the rule's custom `:message` with `{{placeholders}}` filled from
  `bindings`, or `default` when the rule has no custom message.
  """
  @spec message(context(), String.t(), keyword()) :: String.t()
  def message(context, default, bindings) do
    case Keyword.get(context.options, :message) do
      nil ->
        default

      template ->
        Enum.reduce(bindings, template, fn {key, value}, acc ->
          String.replace(acc, "{{#{key}}}", to_string(value))
        end)
    end
  end

  @doc """
  Where the theme lives, for messages.
  """
  @spec theme_file(context()) :: String.t()
  def theme_file(%{theme: %Theme{file: nil}}), do: "your Tailwind stylesheet"
  def theme_file(%{theme: %Theme{file: file}}), do: Path.relative_to_cwd(file)

  defp glob(pattern) do
    ~r/^#{pattern |> Regex.escape() |> String.replace("\\*", ".*")}$/
  end
end

defmodule HeexLint.Element do
  @moduledoc """
  An opening tag in a template: an HTML element, a function component or a slot.

  Attributes keep the tokenizer's value shapes:

    * `{:string, value, {line, column}}` - a quoted value, positioned at its first character
    * `{:expr, code, {line, column}}` - a `{...}` value, positioned at the first character of `code`
    * `nil` - a boolean attribute

  A root attribute such as `{@rest}` has the name `:root`. `parent` is the
  index of the enclosing element in the template, or nil. `text` is the
  content of a `<style>` element.
  """

  alias HeexLint.{TagHandler, Template, Tokenizer}

  defstruct [
    :file,
    :type,
    :name,
    :line,
    :column,
    :index,
    :parent,
    :text,
    indentation: 0,
    attributes: []
  ]

  @type value ::
          {:string, String.t(), {pos_integer(), pos_integer()}}
          | {:expr, String.t(), {pos_integer(), pos_integer()}}
          | nil

  @type attribute :: %{
          name: String.t() | :root,
          value: value(),
          line: pos_integer(),
          column: pos_integer()
        }

  @type t :: %__MODULE__{
          file: String.t(),
          type: :tag | :local_component | :remote_component | :slot,
          name: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          index: non_neg_integer(),
          parent: non_neg_integer() | nil,
          indentation: non_neg_integer(),
          attributes: [attribute()]
        }

  @types [:tag, :local_component, :remote_component, :slot]

  @doc """
  Returns every opening tag in `template`, in source order.
  """
  @spec from_template(Template.t()) :: {:ok, [t()]} | {:error, String.t()}
  def from_template(%Template{} = template) do
    {:ok, eex} =
      EEx.tokenize(template.source,
        line: template.line,
        # EEx adds the indentation to the starting column itself.
        column: template.column - template.indentation,
        indentation: template.indentation
      )

    state = Tokenizer.init(template.indentation, template.file, template.source, TagHandler)

    {tokens, cont} =
      Enum.reduce(eex, {[], {:text, :enabled}}, fn
        {:text, text, meta}, {tokens, cont} ->
          meta = [line: meta.line, column: meta.column]
          Tokenizer.tokenize(List.to_string(text), meta, tokens, cont, state)

        _eex, acc ->
          acc
      end)

    lines = String.split(template.source, ~r/\r?\n/)

    {elements, _stack} =
      tokens
      |> Tokenizer.finalize(template.file, cont, template.source)
      |> Enum.reduce({[], []}, fn
        {type, name, attrs, meta}, {elements, stack} when type in @types ->
          index = length(elements)

          element = %__MODULE__{
            file: template.file,
            type: type,
            name: name,
            line: meta.line,
            column: meta.column,
            index: index,
            parent: List.first(stack),
            indentation: template.indentation,
            attributes: Enum.map(attrs, &attribute(&1, template, lines))
          }

          stack = if meta[:closing] in [:self, :void], do: stack, else: [index | stack]
          {[element | elements], stack}

        {:text, text, _meta},
        {[%__MODULE__{name: "style", type: :tag} = style | rest], [index | _] = stack}
        when style.index == index ->
          {[%{style | text: (style.text || "") <> text} | rest], stack}

        {:close, _type, name, _meta}, {elements, stack} ->
          # Pop to the matching element, so a stray close cannot desync.
          case Enum.find_index(stack, fn i ->
                 Enum.at(elements, length(elements) - 1 - i).name == name
               end) do
            nil -> {elements, stack}
            position -> {elements, Enum.drop(stack, position + 1)}
          end

        _token, acc ->
          acc
      end)

    {:ok, Enum.reverse(elements)}
  rescue
    error in [Tokenizer.ParseError, EEx.SyntaxError] ->
      {:error, Exception.message(error)}
  end

  @doc """
  The name of the element as written in the template, such as `div`, `.button` or `:item`.
  """
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{type: :local_component, name: name}), do: "." <> name
  def display_name(%__MODULE__{type: :slot, name: name}), do: ":" <> name
  def display_name(%__MODULE__{name: name}), do: name

  @doc """
  Whether the element is a colocated stylesheet,
  `<style :type={Phoenix.LiveView.ColocatedCSS}>`, which LiveView extracts
  into the app's CSS bundle.
  """
  @spec colocated_css?(t()) :: boolean()
  def colocated_css?(%__MODULE__{type: :tag, name: "style", attributes: attributes}) do
    Enum.any?(attributes, fn
      %{name: ":type", value: {:expr, code, _}} -> String.contains?(code, "ColocatedCSS")
      _ -> false
    end)
  end

  def colocated_css?(_element), do: false

  @doc "Whether the element is a component or slot rather than an HTML tag."
  @spec component?(t()) :: boolean()
  def component?(%__MODULE__{type: type}), do: type != :tag

  defp attribute({name, value, meta}, template, lines) do
    %{
      name: name,
      value: value(value, name, meta, template, lines),
      line: meta.line,
      column: meta.column
    }
  end

  defp value({:string, value, _meta}, name, meta, template, lines) when is_binary(name) do
    {:string, value, string_start(name, meta, template, lines)}
  end

  defp value({:expr, code, meta}, _name, _attr_meta, _template, _lines) do
    {:expr, code, {meta.line, meta.column}}
  end

  defp value(other, _name, _meta, _template, _lines), do: other

  # The tokenizer does not record where a quoted value starts, so find the
  # opening quote after the attribute name on the attribute's line.
  defp string_start(name, meta, template, lines) do
    source_line = Enum.at(lines, meta.line - template.line, "")
    # Lines after the first lost their indentation in heredoc sigils.
    offset = if meta.line == template.line, do: template.column, else: template.indentation + 1
    from = meta.column - offset + String.length(name)
    rest = String.slice(source_line, from..-1//1)

    case Regex.run(~r/^\s*=\s*["']/, rest) do
      [match] -> {meta.line, meta.column + String.length(name) + String.length(match)}
      nil -> {meta.line, meta.column}
    end
  end
end

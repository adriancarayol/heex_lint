defmodule HeexLint.Template do
  @moduledoc """
  A HEEx template found in a source file, with the position of its first
  character and the function that renders it.

  Templates come from `.heex` files and from `~H` sigils in `.ex`/`.exs`
  files. Positions are kept absolute so every diagnostic points at the real
  file.

  `kind` says where the template's assigns come from:

    * `:component` - a function component; assigns are the caller's attributes
    * `:render` - a LiveView or LiveComponent `render/1`; assigns are socket state
  """

  defstruct [
    :file,
    :source,
    :module,
    :function,
    :clause,
    :elements,
    line: 1,
    column: 1,
    indentation: 0,
    kind: :component
  ]

  @type t :: %__MODULE__{
          file: String.t(),
          source: String.t(),
          module: String.t() | nil,
          function: String.t() | nil,
          clause: map() | nil,
          elements: {:ok, [HeexLint.Element.t()]} | {:error, String.t()} | nil,
          line: pos_integer(),
          column: pos_integer(),
          indentation: non_neg_integer(),
          kind: :component | :render
        }

  @heredocs [~s("""), ~s(''')]

  @doc """
  The template's elements, parsed once and kept on the template.
  """
  @spec elements(t()) :: {:ok, [HeexLint.Element.t()]} | {:error, String.t()}
  def elements(%__MODULE__{elements: nil} = template),
    do: HeexLint.Element.from_template(template)

  def elements(%__MODULE__{elements: elements}), do: elements

  @doc "Parses the template's elements and keeps them on it."
  @spec parse(t()) :: t()
  def parse(%__MODULE__{elements: nil} = template),
    do: %{template | elements: HeexLint.Element.from_template(template)}

  def parse(template), do: template

  @doc """
  Builds the template for a `~H` sigil from its AST metadata.
  """
  @spec from_sigil(String.t(), String.t(), keyword(), keyword()) :: t()
  def from_sigil(file, source, meta, string_meta) do
    if meta[:delimiter] in @heredocs do
      # Heredocs start on the line after the opening delimiter and have
      # their indentation stripped by the compiler.
      indentation = string_meta[:indentation] || 0

      %__MODULE__{
        file: file,
        source: source,
        line: meta[:line] + 1,
        column: indentation + 1,
        indentation: indentation
      }
    else
      delimiter = meta[:delimiter] || "\""

      %__MODULE__{
        file: file,
        source: source,
        line: meta[:line],
        column: meta[:column] + 2 + String.length(delimiter)
      }
    end
  end
end

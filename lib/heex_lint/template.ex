defmodule HeexLint.Template do
  @moduledoc """
  A HEEx template found in a source file, with the position of its first character.

  Templates come from `.heex` files and from `~H` sigils in `.ex`/`.exs` files.
  Positions are kept absolute so every diagnostic points at the real file.
  """

  defstruct [:file, :source, line: 1, column: 1, indentation: 0]

  @type t :: %__MODULE__{
          file: String.t(),
          source: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          indentation: non_neg_integer()
        }

  @heredocs [~s("""), ~s(''')]

  @doc """
  Returns the templates in `file`, whose contents are `contents`.
  """
  @spec from_file(String.t(), String.t()) :: {:ok, [t()]} | {:error, String.t()}
  def from_file(file, contents) do
    case Path.extname(file) do
      ".heex" -> {:ok, [%__MODULE__{file: file, source: contents}]}
      ext when ext in [".ex", ".exs"] -> sigils(file, contents)
      _ -> {:ok, []}
    end
  end

  defp sigils(file, contents) do
    case Code.string_to_quoted(contents, columns: true, token_metadata: true, file: file) do
      {:ok, ast} ->
        {_, templates} =
          Macro.prewalk(ast, [], fn
            {:sigil_H, meta, [{:<<>>, string_meta, [source]}, _modifiers]} = node, acc
            when is_binary(source) ->
              meta = Keyword.put(meta, :indentation, string_meta[:indentation])
              {node, [sigil(file, source, meta) | acc]}

            node, acc ->
              {node, acc}
          end)

        {:ok, Enum.reverse(templates)}

      {:error, {meta, message, token}} ->
        {:error, "#{file}:#{meta[:line]}: #{format_error(message)}#{token}"}
    end
  end

  defp format_error({prefix, suffix}), do: "#{prefix}#{suffix}"
  defp format_error(message), do: message

  # Heredoc sigils start on the line after the opening delimiter and have their
  # indentation stripped by the compiler; single-line sigils start after `~H"`.
  defp sigil(file, source, meta) do
    if meta[:delimiter] in @heredocs do
      indentation = meta[:indentation] || 0

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

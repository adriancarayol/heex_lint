defmodule HeexLint.Rule do
  @moduledoc """
  A lint rule.

  `prepare/2` runs once per distinct option set and compiles what the rule
  needs, such as its policy; a `{:error, message}` there is a
  configuration error, reported at the top of every file the rule checks.
  `check/3` runs once per file and returns findings.

  The file context holds:

    * `:project` - the `HeexLint.Project`
    * `:source` - the `HeexLint.Project.Source`
    * `:sites` - the file's `HeexLint.Sites`
    * `:elements` - `{template, elements}` for each template
    * `:note` - the shared note appended to messages
  """

  alias HeexLint.{Collector, Grammar.Classes, Messages}

  @type finding :: %{
          required(:position) => {pos_integer(), pos_integer()},
          required(:message) => String.t(),
          optional(:suggestions) => [suggestion()]
        }

  @type suggestion :: %{
          message: String.t(),
          replacement: String.t(),
          fix:
            %{
              file: String.t(),
              from: {pos_integer(), pos_integer()},
              old: String.t(),
              new: String.t()
            }
            | nil
        }

  @callback name() :: atom()
  @callback prepare(keyword(), HeexLint.Project.t()) ::
              {:ok, term(), [String.t()]} | {:error, String.t()}
  @callback check(map(), term(), keyword()) :: [finding()]

  @doc """
  The component as messages show it: `.button` for a function component.
  """
  @spec display(String.t() | nil) :: String.t()
  def display(nil), do: ""
  def display(""), do: ""
  def display(name), do: if(String.contains?(name, "."), do: name, else: "." <> name)

  @doc """
  The class tokens of a collected string, with positions.
  """
  def tokens(string), do: Collector.tokens(string)

  @doc """
  Renders a message, with the rule's `message` option and the shared note.
  """
  def message(builtin, data, override, options, file) do
    Messages.render(builtin, data, override, Keyword.get(options, :message), file[:note])
  end

  @doc """
  Suggestions that replace `token` with each replacement inside the
  literal it came from. None when the literal cannot be rewritten safely.
  """
  @spec suggestions(map(), String.t(), [String.t()], (String.t() -> String.t())) :: [suggestion()]
  def suggestions(string, token, replacements, describe) do
    Enum.flat_map(replacements, fn replacement ->
      case string[:literal] do
        %{raw: raw} = literal ->
          replaced = Classes.replace_class(raw, token, replacement)

          if replaced != raw do
            [
              %{
                message: describe.(replacement),
                replacement: replacement,
                fix: %{file: literal.file, from: literal.from, old: raw, new: replaced}
              }
            ]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  @doc "A configuration error's finding, at the top of the file."
  def config_error(message), do: %{position: {1, 1}, message: message}
end

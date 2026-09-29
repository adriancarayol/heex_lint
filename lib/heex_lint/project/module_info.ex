defmodule HeexLint.Project.ModuleInfo do
  @moduledoc """
  What the linter reads from one `defmodule`: its aliases, imports and uses,
  module attributes, function clauses and function components.
  """

  defstruct [
    :name,
    :file,
    :line,
    aliases: %{},
    imports: [],
    uses: [],
    attributes: %{},
    functions: %{},
    components: %{},
    embed_templates: [],
    templates: []
  ]

  @type clause :: %{
          kind: :def | :defp | :defmacro | :defmacrop,
          args: [Macro.t()],
          guard: Macro.t() | nil,
          body: Macro.t() | nil,
          line: pos_integer()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          file: String.t(),
          line: pos_integer(),
          aliases: %{String.t() => String.t()},
          imports: [String.t()],
          uses: [{String.t(), String.t() | nil}],
          attributes: %{String.t() => [Macro.t()]},
          functions: %{{String.t(), non_neg_integer()} => [clause()]},
          components: %{String.t() => HeexLint.Project.Component.t()},
          embed_templates: [String.t()],
          templates: [HeexLint.Template.t()]
        }

  @doc """
  The module `name` refers to from inside this module, expanding aliases.
  """
  @spec expand_alias(t(), String.t()) :: String.t()
  def expand_alias(%__MODULE__{aliases: aliases}, name) do
    [first | rest] = String.split(name, ".")

    case Map.fetch(aliases, first) do
      {:ok, full} -> Enum.join([full | rest], ".")
      :error -> name
    end
  end

  @doc "Whether the module is a LiveView or LiveComponent, whose `render/1` reads socket assigns."
  @spec live?(t()) :: boolean()
  def live?(%__MODULE__{uses: uses}) do
    Enum.any?(uses, fn
      {"Phoenix.LiveView", _} -> true
      {"Phoenix.LiveComponent", _} -> true
      {_, kind} when kind in ["live_view", "live_component"] -> true
      _ -> false
    end)
  end
end

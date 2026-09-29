defmodule HeexLint.Project.Component do
  @moduledoc """
  A function component: its declared attributes and slots, and the
  templates it renders.

  Attributes declared with `values:` are its variants: `attr :variant,
  values: ~w(primary ghost)` gives the variant names a finding suggests, and
  `attr :size, values: ...` the sizes a spacing finding offers.
  """

  defstruct [:module, :name, :file, :line, attrs: [], slots: [], templates: []]

  @type attr :: %{
          name: String.t(),
          type: Macro.t(),
          values: [String.t()] | nil,
          default: Macro.t() | :none,
          global: boolean(),
          line: pos_integer() | nil
        }

  @type t :: %__MODULE__{
          module: String.t(),
          name: String.t(),
          file: String.t(),
          line: pos_integer() | nil,
          attrs: [attr()],
          slots: [%{name: String.t(), attrs: [attr()]}],
          templates: [HeexLint.Template.t()]
        }

  @doc "The attribute called `name`, or nil."
  @spec attr(t(), String.t()) :: attr() | nil
  def attr(%__MODULE__{attrs: attrs}, name), do: Enum.find(attrs, &(&1.name == name))

  @doc "The values of the component's `variant` attribute, or nil."
  @spec variants(t()) :: [String.t()] | nil
  def variants(component), do: axis(component, "variant")

  @doc "The values of the component's `size` attribute, or nil."
  @spec sizes(t()) :: [String.t()] | nil
  def sizes(component), do: axis(component, "size")

  defp axis(component, name) do
    case attr(component, name) do
      %{values: [_ | _] = values} -> values
      _ -> nil
    end
  end

  @doc "Whether the component takes global attributes (`attr :rest, :global`), which carry `class`."
  @spec global?(t()) :: boolean()
  def global?(%__MODULE__{attrs: attrs}), do: Enum.any?(attrs, & &1.global)
end

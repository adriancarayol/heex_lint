defmodule HeexLint.Rules.RequireStaticClasses do
  @moduledoc """
  Keeps component class values readable by the linter. If a class is built
  from an unknown value, the other rules cannot check it; this rule reports
  that unreadable part.

      <.button class={"bg-\#{@color}"}>Save</.button>
      Dynamically built class on <.button> cannot be checked. Use static class strings.

  Static strings and choices between complete classes pass, and so do
  same-function assigns, variables and local helpers the linter can read.
  A function component forwarding the `class` it received is allowed; its
  authored default is still checked.

  Only recognized design-system components and their forwarding wrappers
  are checked. Turn the rule off inside your component directory, where
  components call their own helpers.

  ## Options

    * `:message` - replaces the text. `{{component}}` names the component.
  """

  @behaviour HeexLint.Rule

  alias HeexLint.Rule

  @dynamic "Dynamically built class on <{{component}}> cannot be checked. Use static class strings."

  @impl true
  def name, do: :require_static_classes

  @impl true
  def prepare(_options, _project), do: {:ok, nil, []}

  @impl true
  def check(file, _state, options) do
    for site <- file.sites,
        site.kind == :class,
        site.component != nil,
        position <- site.unresolved do
      data = %{"component" => Rule.display(site.component)}
      %{position: position, message: Rule.message(@dynamic, data, nil, options, file)}
    end
  end
end

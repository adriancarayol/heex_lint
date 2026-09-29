defmodule HeexLint.Rules.RequireStaticClasses do
  @moduledoc """
  Reports classes built at runtime, such as `"bg-\#{@color}"` or `"w-" <> @width`.

  Tailwind scans source files for complete class names, so a class assembled
  at runtime never gets CSS. Whole runtime values (`class={@class}`) are fine,
  and so are plain CSS classes the stylesheet defines (`"toast--\#{@kind}"` when
  it has `.toast--error`).

  ## Options

    * `:message` - a custom message. Placeholders: `{{class}}`.
  """

  @behaviour HeexLint.Rule

  alias HeexLint.{Rule, Theme}

  @impl true
  def name, do: :require_static_classes

  @impl true
  def check(element, context) do
    for {:partial, class, position} <- Rule.class_tokens(element, context),
        not Theme.class_prefix?(context.theme, static_prefix(class)) do
      default =
        "\"#{class}\" is built at runtime, so Tailwind never sees the full class and generates no CSS for it. " <>
          "Write every class out in full, for example with a case that maps each value to a complete class name."

      {position, Rule.message(context, default, class: class)}
    end
  end

  defp static_prefix(class), do: class |> String.split("\#{…}") |> hd()
end

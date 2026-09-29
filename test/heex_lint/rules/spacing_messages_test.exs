defmodule HeexLint.Rules.SpacingMessagesTest do
  # Ported from @shadcn/lint's spacing-messages tests: sizes first when the
  # component has a size axis, then where space around it goes, built only
  # from what the project's contracts allow.
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  @moduletag :tmp_dir

  @card """
  defmodule AppWeb.Card do
    use Phoenix.Component

    attr :class, :any, default: nil
    slot :inner_block
    def card(assigns), do: ~H"<div class={@class}>{render_slot(@inner_block)}</div>"

    attr :class, :any, default: nil
    slot :inner_block
    def card_header(assigns), do: ~H"<div class={@class}>{render_slot(@inner_block)}</div>"

    attr :class, :any, default: nil
    slot :inner_block
    def card_footer(assigns), do: ~H"<div class={@class}>{render_slot(@inner_block)}</div>"

    attr :class, :any, default: nil
    slot :inner_block
    def card_title(assigns), do: ~H"<h3 class={@class}>{render_slot(@inner_block)}</h3>"

    attr :class, :any, default: nil
    slot :inner_block
    def card_content(assigns), do: ~H"<div class={@class}>{render_slot(@inner_block)}</div>"

    attr :class, :any, default: nil
    slot :inner_block
    def field(assigns), do: ~H"<div class={@class}>{render_slot(@inner_block)}</div>"

    attr :class, :any, default: nil
    slot :inner_block
    def field_label(assigns), do: ~H"<label class={@class}>{render_slot(@inner_block)}</label>"
  end
  """

  @layout [allow: ["layout"]]
  @open_containers [
    pattern: "^card$|(content|header|footer|group|panel)$",
    allow: ["layout", "spacing"]
  ]
  @options Keyword.put(@layout, :contracts, [@open_containers])
  @containers ".card, .card_header, .card_footer and .card_content"

  defp message(dir, template, options \\ @options, extra \\ %{}) do
    live = """
    defmodule AppWeb.PageLive do
      use Phoenix.LiveView
      import AppWeb.CoreComponents
      import AppWeb.Card

      def render(assigns) do
        ~H\"\"\"
        #{template}
        \"\"\"
      end
    end
    """

    files =
      Map.merge(
        %{"lib/app_web/live/page_live.ex" => live, "lib/app_web/components/card.ex" => @card},
        extra
      )

    [finding] = lint(dir, files, rules: [no_restyle: {:error, options}])
    finding.message
  end

  test "a component with a size axis is offered its sizes", %{tmp_dir: dir} do
    assert message(dir, ~s(<.button class="p-4">Go</.button>), @layout) ==
             ~s|"p-4" is not allowed on <.button>: <.button> owns its spacing. Use a size (sm, lg), or margin here or gap on the parent for space around it. Add a size in lib/app_web/components/core_components.ex only if the design explicitly calls for one.|
  end

  test "a component without one is offered only the places around it", %{tmp_dir: dir} do
    assert message(dir, ~s(<.card_title class="pb-2">Hi</.card_title>), @layout) ==
             ~s|"pb-2" is not allowed on <.card_title>: <.card_title> owns its spacing. For space around it, use margin here or gap on the parent.|
  end

  test "margin is offered only when the contract allows it", %{tmp_dir: dir} do
    assert message(dir, ~s(<.button class="p-4">Go</.button>), []) =~
             ", or gap on the parent for space around it. Add"
  end

  test "a direct parent that accepts the class replaces the parent", %{tmp_dir: dir} do
    assert message(
             dir,
             ~s(<.card_header><.card_title class="pb-2">Hi</.card_title></.card_header>)
           ) ==
             ~s|"pb-2" is not allowed on <.card_title>: <.card_title> owns its spacing. For space around it, use margin here, spacing on <.card_header>, or .card, .card_footer and .card_content.|
  end

  test "further up, the parent stays and the container is added", %{tmp_dir: dir} do
    template = ~s(<.card_content><div><.button class="p-4">Go</.button></div></.card_content>)

    assert message(dir, template) =~
             ", or margin here, gap on the parent, spacing on <.card_content>, or .card, .card_header and .card_footer for space around it. Add a size"
  end

  test "EEx blocks are not layout parents", %{tmp_dir: dir} do
    template =
      ~s(<.card_content><%= if @on do %><.button class="p-4">Go</.button><% end %></.card_content>)

    assert message(dir, template) =~
             "or margin here, spacing on <.card_content>, or .card, .card_header and .card_footer for space around it. Add"
  end

  test "a direct parent that does not accept the class is skipped", %{tmp_dir: dir} do
    assert message(dir, ~s(<.field><.field_label class="px-2">Hi</.field_label></.field>)) =~
             "use margin here, gap on a plain wrapper around it, or #{@containers}."
  end

  test "margin denied with a direct container: the container leads", %{tmp_dir: dir} do
    options =
      Keyword.put(@layout, :contracts, [
        @open_containers,
        [pattern: "^card_title$", allow: ["layout"], deny: ["m-*"]]
      ])

    template = ~s(<.card_header><.card_title class="pb-2">Hi</.card_title></.card_header>)

    assert message(dir, template, options) =~
             "For space around it, use spacing on <.card_header> or .card, .card_footer and .card_content."
  end

  test "a literal pattern names its components, in the order written", %{tmp_dir: dir} do
    options =
      Keyword.put(@layout, :contracts, [[pattern: "^(row|stack|box)$", allow: ["spacing"]]])

    assert message(dir, ~s(<.button class="p-4">Go</.button>), options) =~
             ", or margin here, gap on the parent, or .row, .stack and .box for space around it. Add"
  end

  test "a non-literal pattern is matched against the component index", %{tmp_dir: dir} do
    options = Keyword.put(@layout, :contracts, [[pattern: "^fie.d$", allow: ["spacing"]]])

    assert message(dir, ~s(<.button class="p-4">Go</.button>), options) =~
             "or margin here, gap on the parent, or .field for space around it. Add"
  end

  test "two names read as a pair; margin denied still lists them", %{tmp_dir: dir} do
    options =
      Keyword.put(@layout, :contracts, [
        [pattern: "^(row|stack)$", allow: ["spacing"]],
        [pattern: "^button$", allow: ["layout"], deny: ["m-*"]]
      ])

    assert message(dir, ~s(<.button class="p-4">Go</.button>), options) =~
             ", or gap on the parent or .row and .stack for space around it. Add"
  end

  test "more than four names is a pattern, not a list", %{tmp_dir: dir} do
    options =
      Keyword.put(@layout, :contracts, [[pattern: "^(a1|a2|a3|a4|a5)$", allow: ["spacing"]]])

    assert message(dir, ~s(<.button class="p-4">Go</.button>), options) =~
             ", or margin here or gap on the parent for space around it. Add"
  end
end

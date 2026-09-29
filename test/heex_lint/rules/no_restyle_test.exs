defmodule HeexLint.Rules.NoRestyleTest do
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  @moduletag :tmp_dir

  defp restyle(dir, template, options \\ [allow: ["layout"]], extra \\ %{}) do
    files = Map.merge(%{"lib/app_web/live/page_live.ex" => live(template)}, extra)
    lint(dir, files, rules: [no_restyle: {:error, options}])
  end

  test "layout passes; appearance is reported with the component's variants", %{tmp_dir: dir} do
    assert restyle(dir, ~s(<.button class="mt-4 w-full">Save</.button>)) == []

    [color] = restyle(dir, ~s(<.button class="bg-pink-500">Save</.button>))

    assert color.message ==
             ~s("bg-pink-500" is not allowed on <.button>: <.button> owns its color. Use a variant: default, destructive, outline. Add a new variant in lib/app_web/components/core_components.ex only if the design explicitly calls for a treatment none of these provides.)

    assert {color.line, color.column} == {6, 21}
  end

  test "spacing suggests sizes and where space around goes", %{tmp_dir: dir} do
    [padding] = restyle(dir, ~s(<.button class="p-4">Save</.button>))

    assert padding.message ==
             ~s|"p-4" is not allowed on <.button>: <.button> owns its spacing. Use a size (sm, lg), or margin here or gap on the parent for space around it. Add a size in lib/app_web/components/core_components.ex only if the design explicitly calls for one.|
  end

  test "spacing without sizes names only the places around it", %{tmp_dir: dir} do
    [gap] = restyle(dir, ~s(<.card class="gap-2">x</.card>))

    assert gap.message ==
             ~s("gap-2" is not allowed on <.card>: <.card> owns its spacing. For space around it, use margin here or gap on the parent.)
  end

  test "an enclosing container that accepts spacing is named", %{tmp_dir: dir} do
    options = [
      allow: ["layout"],
      contracts: [[pattern: "^card_content$", allow: ["layout", "spacing"]]]
    ]

    template = """
    <.card_content>
      <.button class="p-4">Save</.button>
    </.card_content>
    """

    [finding] = restyle(dir, template, options)
    assert finding.message =~ "or margin here or spacing on <.card_content> for space around it."
  end

  test "contracts open categories per component; the last match wins", %{tmp_dir: dir} do
    options = [
      allow: ["layout"],
      contracts: [
        [pattern: "^card_title$", allow: ["layout", "typography"]],
        [pattern: "^card_content$", allow: ["layout", "spacing"]]
      ]
    ]

    template = """
    <.card_title class="text-sm">Account</.card_title>
    <.card_content class="p-4">Profile</.card_content>
    <.card_title class="text-pink-500">Account</.card_title>
    """

    assert [finding] = restyle(dir, template, options)

    assert finding.message =~
             ~s("text-pink-500" is not allowed on <.card_title>: <.card_title> owns its color.)
  end

  test "deny removes classes from allow", %{tmp_dir: dir} do
    [finding] =
      restyle(dir, ~s(<.button class="mt-4 w-full">x</.button>), allow: ["layout"], deny: ["w-*"])

    assert finding.message == ~s("w-full" is not allowed on <.button>: its contract denies w-*.)
  end

  test "neither allow nor deny reports every class, layout included", %{tmp_dir: dir} do
    [finding] = restyle(dir, ~s(<.button class="mt-4">x</.button>), [])

    assert finding.message =~
             "its contract allows no classes. Put layout classes on a parent element instead."
  end

  test "layout findings under a narrower contract list its entries", %{tmp_dir: dir} do
    options = [allow: ["layout"], contracts: [[pattern: "^icon$", allow: ["size-*"]]]]
    [finding] = restyle(dir, ~s(<.icon name="hero-x-mark" class="mt-2" />), options)

    assert finding.message =~
             "its contract allows size-*. Use one of those, or put layout classes on a parent element."
  end

  test "unclassified and declared classes", %{tmp_dir: dir} do
    [typo, declared] = restyle(dir, ~s(<.button class="flex-cols legacy-card">x</.button>))

    assert typo.message =~
             ~s("flex-cols" is not allowed on <.button>: the grammar does not recognize it.)

    assert declared.message =~
             "your CSS declares it, and the grammar cannot tell what it changes."
  end

  test "markers pass as layout", %{tmp_dir: dir} do
    assert restyle(dir, ~s(<.button class="group peer/save">x</.button>)) == []
  end

  test "plain elements and unrecognized components are outside the rule", %{tmp_dir: dir} do
    assert restyle(dir, ~s(<div class="bg-pink-500 p-4">x</div>)) == []
  end

  test "reads assigns, conditionals and helpers of the rendering function", %{tmp_dir: dir} do
    template = ~s(<.button class={["w-full", @active && "bg-pink-500"]}>Save</.button>)
    [finding] = restyle(dir, template)
    assert finding.message =~ ~s("bg-pink-500")
  end

  test "custom messages per category, with fallbacks", %{tmp_dir: dir} do
    options = [
      allow: ["layout"],
      message: %{
        spacing: "Use a {{component}} size: {{sizes|none defined}}.",
        default: "Use a {{component}} variant: {{variants|none defined}}."
      }
    ]

    [spacing, color] = restyle(dir, ~s(<.card class="p-2 bg-pink-500">x</.card>), options)
    assert spacing.message == "Use a .card size: none defined."
    assert color.message == "Use a .card variant: none defined."
  end

  test "a contract's message wins for its categories", %{tmp_dir: dir} do
    options = [
      allow: ["layout"],
      contracts: [
        [
          pattern: "^button$",
          allow: ["layout"],
          deny: ["w-*"],
          message: %{layout: "Set width on the parent container."}
        ]
      ]
    ]

    [finding] = restyle(dir, ~s(<.button class="w-full">x</.button>), options)
    assert finding.message == "Set width on the parent container."
  end

  test "wrappers that forward class get the underlying component's contract", %{tmp_dir: dir} do
    wrapper =
      component_module("Widgets", "save_button", "attr :class, :any, default: nil", """
      <.button class={["w-full", @class]}>Save</.button>
      """)

    template = ~s(<AppWeb.Widgets.save_button class="bg-pink-500" />)

    [finding] =
      restyle(dir, template, [allow: ["layout"]], %{"lib/app_web/widgets.ex" => wrapper})

    assert finding.message =~
             ~s("bg-pink-500" is not allowed on <.save_button>: <.save_button> forwards class to <.button>, which owns its color. Use a variant: default, destructive, outline.)
  end

  test "wrappers forwarding global attributes count too", %{tmp_dir: dir} do
    wrapper =
      component_module("Widgets", "danger_button", "attr :rest, :global", """
      <.button variant="destructive" {@rest}>Delete</.button>
      """)

    template = ~s(<AppWeb.Widgets.danger_button class="p-6" />)

    [finding] =
      restyle(dir, template, [allow: ["layout"]], %{"lib/app_web/widgets.ex" => wrapper})

    assert finding.message =~ "forwards class to <.button>, which owns its spacing."
  end

  test "classes on a slot belong to the component it is passed to", %{tmp_dir: dir} do
    components =
      component_module("Table", "table", "slot :col", """
      <table><td :for={col <- @col} class={col[:class]}>{render_slot(col)}</td></table>
      """)

    options = [
      allow: ["layout"],
      contracts: [[pattern: "^table$", allow: ["layout", "typography"]]]
    ]

    template = """
    <.table>
      <:col class="text-right font-mono">a</:col>
      <:col class="bg-muted">b</:col>
    </.table>
    """

    extra = %{
      "lib/app_web/components/table.ex" =>
        String.replace(components, "use AppWeb, :html", "use Phoenix.Component")
    }

    [finding] = restyle(dir, template, options, extra)
    assert finding.message =~ ~s("bg-muted" is not allowed on <.table>)
  end
end

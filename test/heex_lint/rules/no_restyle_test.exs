defmodule HeexLint.Rules.NoRestyleTest do
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  @moduletag :tmp_dir

  defp restyle(dir, template, options \\ [allow: ["layout"]], extra \\ %{}) do
    files = Map.merge(%{"lib/app_web/live/page_live.ex" => live(template)}, extra)
    lint(dir, files, rules: [no_restyle: {:error, options}])
  end

  describe "what a wrapper hands on" do
    @panels ~S'''
    defmodule AppWeb.Panels do
      use AppWeb, :html

      attr :class, :any, default: nil
      attr :title_class, :any, default: nil
      slot :inner_block

      def panel(assigns) do
        ~H"""
        <.card class={@class}>
          <.card_title class={@title_class}>{render_slot(@inner_block)}</.card_title>
        </.card>
        """
      end

      attr :title_class, :any, default: nil
      def renamed_map(assigns), do: ~H"<.panel {%{class: @title_class}} />"

      attr :title_class, :any, default: nil
      def data_map(assigns), do: ~H"<.card {%{\"data-x\": @title_class}}>x</.card>"

      attr :a_class, :any, default: nil
      attr :b_class, :any, default: nil
      def dup_key(assigns), do: ~H"<.card {%{class: @a_class, class: @b_class}}>x</.card>"

      attr :rest, :global
      def rest_get(assigns), do: ~H"<.card class={@rest[:class]}>x</.card>"

      attr :other, :any, default: %{}
      def other_get(assigns), do: ~H"<.card class={@other[:class]}>x</.card>"

      attr :rest, :global
      def plain_then(assigns) do
        ~H"""
        <.plain {@rest} /><.card data-x={@title_class} {@rest}>x</.card>
        """
      end

      attr :rest, :global
      def plain(assigns), do: ~H"<p {@rest}>x</p>"
    end
    '''

    defp handed(dir, template),
      do: restyle(dir, template, [allow: ["layout"]], %{"lib/app_web/panels.ex" => @panels})

    test "a renamed map spread lands under its key", %{tmp_dir: dir} do
      assert [finding] = handed(dir, ~S|<.renamed_map title_class="bg-red-500" />|)
      assert finding.message =~ "forwards title_class to <.card>"
    end

    test "a map key that is no class attribute lands nowhere", %{tmp_dir: dir} do
      assert handed(dir, ~S|<.data_map title_class="bg-red-500" />|) == []
    end

    test "a repeated map key is its last value", %{tmp_dir: dir} do
      assert handed(dir, ~S|<.dup_key a_class="bg-red-500" b_class="mt-4" />|) == []
      assert [_] = handed(dir, ~S|<.dup_key a_class="mt-4" b_class="bg-red-500" />|)
    end

    test "a read of a global attribute follows it", %{tmp_dir: dir} do
      assert [finding] = handed(dir, ~S|<.rest_get class="bg-red-500" />|)
      assert finding.message =~ "forwards class to <.card>"
    end

    test "a read of another map's member does not", %{tmp_dir: dir} do
      assert handed(dir, ~S|<.other_get class="bg-red-500" />|) == []
    end

    test "a prop read on any attribute is named, and tries every spread", %{tmp_dir: dir} do
      assert [finding] = handed(dir, ~S|<.plain_then title_class="bg-red-500" />|)
      assert finding.message =~ "<.card>"
    end
  end

  test "a bare color in allow warns, where the vocabulary rules stop", %{tmp_dir: dir} do
    assert restyle(dir, ~s(<.button class="mt-4">Save</.button>), allow: ["layout", "blue-500"]) ==
             []

    assert %{warnings: warnings} =
             run(dir, %{"lib/app_web/live/page_live.ex" => live(~s(<div />))},
               rules: [no_restyle: {:error, allow: ["blue-500"]}]
             )

    assert Enum.any?(warnings, &(&1 =~ ~s(Contract entry "blue-500")))
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

  test "spacing on a slot does not offer the slot's owner again", %{tmp_dir: dir} do
    options = [allow: ["layout"], contracts: [[pattern: "^card$", allow: ["layout", "spacing"]]]]
    template = ~s(<.card><:title><.button class="p-4">x</.button></:title></.card>)

    [finding] = restyle(dir, template, options)
    assert finding.message =~ "margin here or spacing on <:title> for space around it."
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

  describe "{{sizes}}" do
    @sizes [message: "Sizes: {{sizes|none yet}}."]

    defp sized(dir, template) do
      options = @sizes ++ [allow: ["layout"], deny: ["w-*"]]
      [finding] = restyle(dir, template, options)
      finding.message
    end

    test "is the list on every finding kind", %{tmp_dir: dir} do
      # Denied, color, typography, spacing, and a name the grammar cannot read.
      for class <- ~w(w-full bg-pink-500 font-bold p-4 not-a-class) do
        assert sized(dir, ~s(<.button class="#{class}">Go</.button>)) == "Sizes: sm, lg."
      end
    end

    test "is on a closed contract's layout finding too", %{tmp_dir: dir} do
      options = @sizes ++ [allow: []]
      [finding] = restyle(dir, ~s(<.button class="mt-4">Go</.button>), options)
      assert finding.message == "Sizes: sm, lg."
    end

    test "takes the fallback on a component without sizes", %{tmp_dir: dir} do
      assert sized(dir, ~s(<.card class="font-bold">x</.card>)) == "Sizes: none yet."
      assert sized(dir, ~s(<.card class="w-full">x</.card>)) == "Sizes: none yet."
    end

    test "is empty rather than literal without a fallback", %{tmp_dir: dir} do
      [finding] =
        restyle(dir, ~s(<.card class="font-bold">x</.card>),
          allow: ["layout"],
          message: "Sizes: [{{sizes}}]."
        )

      assert finding.message == "Sizes: []."
    end

    test "comes from the wrapped component on a forwarding wrapper", %{tmp_dir: dir} do
      wrapper =
        component_module("Widgets", "danger_button", "attr :rest, :global", """
        <.button variant="destructive" {@rest}>Delete</.button>
        """)

      [finding] =
        restyle(
          dir,
          ~s(<AppWeb.Widgets.danger_button class="bg-pink-500" />),
          @sizes ++ [allow: ["layout"]],
          %{"lib/app_web/widgets.ex" => wrapper}
        )

      assert finding.message == "Sizes: sm, lg."
    end
  end

  describe "a component from deps/" do
    @salad """
    defmodule SaladUI.Button do
      use Phoenix.Component

      attr :variant, :string, values: ~w(default ghost), default: "default"
      attr :size, :string, values: ~w(sm lg), default: "sm"
      attr :class, :any, default: nil
      def button(assigns), do: ~H"<button class={@class} />"

      attr :class, :any, default: nil
      def badge(assigns), do: ~H"<span class={@class} />"
    end
    """

    defp salad_page(template) do
      """
      defmodule AppWeb.ShopLive do
        use Phoenix.LiveView
        import SaladUI.Button

        def render(assigns) do
          ~H\"\"\"
          #{template}
          \"\"\"
        end
      end
      """
    end

    defp salad(dir, template, options \\ [allow: ["layout"]], extra \\ %{}) do
      files =
        Map.merge(
          %{
            "deps/salad_ui/lib/salad_ui/button.ex" => @salad,
            "lib/app_web/live/shop_live.ex" => salad_page(template)
          },
          extra
        )

      lint(dir, files,
        rules: [no_restyle: {:error, options}],
        settings: [component_imports: ["^SaladUI\\."]]
      )
    end

    test "an appearance finding adds the variant to the component", %{tmp_dir: dir} do
      [finding] = salad(dir, ~s(<.button class="bg-pink-500">Go</.button>))

      assert finding.message ==
               ~s|"bg-pink-500" is not allowed on <.button>: <.button> owns its color. Use a variant: default, ghost. Add a new variant to <.button> only if the design explicitly calls for a treatment none of these provides.|
    end

    test "without variants too", %{tmp_dir: dir} do
      [finding] = salad(dir, ~s(<.badge class="bg-pink-500">Go</.badge>))

      assert finding.message ==
               ~s|"bg-pink-500" is not allowed on <.badge>: <.badge> owns its color. Add a variant to <.badge> only if the design explicitly calls for this treatment.|
    end

    test "a spacing finding adds the size to the component", %{tmp_dir: dir} do
      [finding] = salad(dir, ~s(<.button class="p-4">Go</.button>))

      assert finding.message ==
               ~s|"p-4" is not allowed on <.button>: <.button> owns its spacing. Use a size (sm, lg), or margin here or gap on the parent for space around it. Add a size to <.button> only if the design explicitly calls for one.|
    end

    test "a wrapper over it names the component it forwards to", %{tmp_dir: dir} do
      wrapper = """
      defmodule AppWeb.Widgets do
        use Phoenix.Component
        import SaladUI.Button

        attr :rest, :global
        def danger_button(assigns), do: ~H"<.button variant=\\"ghost\\" {@rest}>Delete</.button>"
      end
      """

      extra = %{"lib/app_web/widgets.ex" => wrapper}

      [color] =
        salad(
          dir,
          ~s(<AppWeb.Widgets.danger_button class="bg-pink-500" />),
          [allow: ["layout"]],
          extra
        )

      assert color.message ==
               ~s|"bg-pink-500" is not allowed on <.danger_button>: <.danger_button> forwards class to <.button>, which owns its color. Use a variant: default, ghost. Add a new variant to <.button> only if the design explicitly calls for a treatment none of these provides.|

      [spacing] =
        salad(dir, ~s(<AppWeb.Widgets.danger_button class="p-4" />), [allow: ["layout"]], extra)

      assert spacing.message =~
               "Add a size to <.button> only if the design explicitly calls for one."

      refute spacing.message =~ "deps/"
    end

    test "{{file}} is empty and {{where}} names the component", %{tmp_dir: dir} do
      options = [allow: ["layout"], message: "[{{file}}] [{{file|no file}}] [{{where}}]"]

      for class <- ~w(bg-pink-500 p-4 not-a-class) do
        [finding] = salad(dir, ~s(<.button class="#{class}">Go</.button>), options)
        assert finding.message == "[] [no file] [to <.button>]"
      end
    end

    test "no finding on it names the dependency's path", %{tmp_dir: dir} do
      options = [allow: ["mt-4"], deny: ["w-*"]]
      classes = "bg-pink-500 p-4 font-bold shadow-sm w-full flex not-a-class"
      findings = salad(dir, ~s(<.button class="#{classes}">Go</.button>), options)

      assert length(findings) == 7
      for finding <- findings, do: refute(finding.message =~ "deps/")
    end
  end

  test "a project component's own file fills {{file}} and {{where}}", %{tmp_dir: dir} do
    options = [allow: ["layout"], message: "[{{file}}] [{{where}}]"]
    file = "lib/app_web/components/core_components.ex"

    # On every finding kind, not only the ones whose built-in text names it.
    for class <- ~w(bg-pink-500 p-4 not-a-class) do
      [finding] = restyle(dir, ~s(<.button class="#{class}">Go</.button>), options)
      assert finding.message == "[#{file}] [in #{file}]"
    end
  end
end

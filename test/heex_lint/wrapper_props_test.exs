defmodule HeexLint.WrapperPropsTest do
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  alias HeexLint.{Messages, Project}

  @moduletag :tmp_dir
  # A walk that doubles with every wrapper does not fail, it just never returns.
  @moduletag timeout: 30_000

  @panels """
  defmodule AppWeb.Panels do
    use AppWeb, :html

    attr :class, :any, default: nil
    attr :title_class, :any, default: nil
    slot :inner_block

    def panel(assigns) do
      ~H\"""
      <.card class={@class}>
        <.card_title class={@title_class}>{render_slot(@inner_block)}</.card_title>
      </.card>
      \"""
    end

    def members(assigns) do
      ~H\"""
      <.card class={assigns.class}>
        <.card_content class={[assigns[:body_class]]}>x</.card_content>
      </.card>
      \"""
    end

    def by_map(assigns) do
      ~H\"""
      <.card class={Map.get(assigns, :class)}>
        <.card_title class={Map.get(assigns, :title_class, nil)}>x</.card_title>
        <.card_content class={Map.fetch!(assigns, :body_class)}>x</.card_content>
      </.card>
      \"""
    end

    attr :rest, :global

    def passed(assigns) do
      ~H"<.panel {@rest} />"
    end

    attr :heading_class, :any, default: nil

    def renamed(assigns) do
      ~H"<.panel title_class={@heading_class} />"
    end

    attr :title_class, :any, default: nil

    def title_only(assigns) do
      ~H"<.card_title class={@title_class}>x</.card_title>"
    end

    attr :class, :any, default: nil
    attr :title_class, :any, default: nil

    def dropped(assigns) do
      ~H"<.card class={@class}>x</.card>"
    end

    attr :class, :any, default: nil
    attr :title_class, :any, default: nil

    def plain(assigns) do
      ~H\"""
      <.card class={@class}><h2 class={@title_class}>x</h2></.card>
      \"""
    end
  end
  """

  @contracts [
    allow: ["layout"],
    contracts: [
      [pattern: "^card$", allow: ["layout"]],
      [pattern: "^card_title$", allow: ["typography"]],
      [pattern: "^button$", allow: ["spacing"]]
    ]
  ]

  defp restyle(dir, template, options \\ @contracts, extra \\ %{}) do
    files =
      Map.merge(
        %{"lib/app_web/panels.ex" => @panels, "lib/app_web/live/page_live.ex" => live(template)},
        extra
      )

    lint(dir, files, rules: [no_restyle: {:error, options}])
  end

  # The project after writing `files`, without linting it.
  defp project(dir, files) do
    run(dir, files)
    sources = dir |> Path.join("lib/**/*.ex") |> Path.wildcard()
    Project.load(dir, sources, %{})
  end

  defp target(project, module, name, attribute \\ "class") do
    component = Project.module(project, module).components[name]

    case Project.wrapped(project, component, attribute) do
      nil -> nil
      target -> target.name
    end
  end

  describe "Project.wrapped by prop" do
    setup %{tmp_dir: dir} do
      %{project: project(dir, %{"lib/app_web/panels.ex" => @panels})}
    end

    test "each class prop follows its own forwarding", %{project: project} do
      assert target(project, "AppWeb.Panels", "panel") == "card"
      assert target(project, "AppWeb.Panels", "panel", "title_class") == "card_title"
    end

    test "props read off assigns follow theirs", %{project: project} do
      assert target(project, "AppWeb.Panels", "members") == "card"
      assert target(project, "AppWeb.Panels", "members", "body_class") == "card_content"
      assert target(project, "AppWeb.Panels", "by_map") == "card"
      assert target(project, "AppWeb.Panels", "by_map", "title_class") == "card_title"
      assert target(project, "AppWeb.Panels", "by_map", "body_class") == "card_content"
    end

    test "a prop read through Map is judged against what it reaches", %{tmp_dir: dir} do
      files = %{"lib/app_web/panels.ex" => @panels}

      for attribute <- ["class", "title_class", "body_class"] do
        template = ~s(<AppWeb.Panels.by_map #{attribute}="bg-red-500" />)
        files = Map.put(files, "lib/app_web/live/page_live.ex", live(template))
        assert [_] = lint(dir, files, rules: [no_restyle: {:error, allow: ["layout"]}]), attribute
      end
    end

    test "a prop stays itself through global attributes", %{project: project} do
      assert target(project, "AppWeb.Panels", "passed") == "card"
      assert target(project, "AppWeb.Panels", "passed", "title_class") == "card_title"
    end

    test "a prop handed on under another name follows that name", %{project: project} do
      assert target(project, "AppWeb.Panels", "renamed", "heading_class") == "card_title"
    end

    test "a prop the wrapper does not hand on has no target", %{project: project} do
      assert target(project, "AppWeb.Panels", "title_only") == nil
      assert target(project, "AppWeb.Panels", "dropped", "title_class") == nil
      assert target(project, "AppWeb.Panels", "panel", "footer_class") == nil
      assert target(project, "AppWeb.Panels", "passed", "footer_class") == nil
    end

    test "a prop handed to a plain element has no target", %{project: project} do
      assert target(project, "AppWeb.Panels", "plain") == "card"
      assert target(project, "AppWeb.Panels", "plain", "title_class") == nil
    end

    test "a design-system component is not a wrapper", %{project: project} do
      button = Project.module(project, "AppWeb.CoreComponents").components["button"]

      assert Project.wrapped(project, button) == nil
      assert Project.wrapped(project, button, "title_class") == nil
    end

    test "the attribute defaults to class", %{project: project} do
      component = Project.module(project, "AppWeb.Panels").components["panel"]
      assert Project.wrapped(project, component).name == "card"
      assert Project.wrapped(project, nil) == nil
    end
  end

  describe "global attributes" do
    defp spread_module(attrs, template) do
      %{"lib/app_web/w.ex" => component_module("W", "w", attrs, template)}
    end

    test "carry a prop nothing in the project names", %{tmp_dir: dir} do
      project = project(dir, spread_module("attr :rest, :global", "<.button {@rest}>x</.button>"))

      assert target(project, "AppWeb.W", "w", "anything_class") == "button"
    end

    test "do not carry a prop the component declares", %{tmp_dir: dir} do
      project =
        project(
          dir,
          spread_module(
            "attr :class, :any, default: nil\nattr :title_class, :any, default: nil\nattr :rest, :global",
            ~s(<div class={@class} title={@title_class}><.button {@rest}>x</.button></div>)
          )
        )

      assert target(project, "AppWeb.W", "w") == nil
      assert target(project, "AppWeb.W", "w", "title_class") == nil
      assert target(project, "AppWeb.W", "w", "other_class") == "button"
    end

    test "only spread when the assign is global", %{tmp_dir: dir} do
      project =
        project(dir, spread_module("attr :rest, :map", "<.button {@rest}>x</.button>"))

      assert target(project, "AppWeb.W", "w") == nil
      assert target(project, "AppWeb.W", "w", "other_class") == nil
    end

    test "reach the first component they land on, not a plain element", %{tmp_dir: dir} do
      project =
        project(
          dir,
          spread_module("attr :rest, :global", ~s(<div {@rest} /><.card {@rest}>x</.card>))
        )

      assert target(project, "AppWeb.W", "w", "other_class") == "card"
    end

    test "take a prop nothing names to the first component they reach", %{tmp_dir: dir} do
      files = %{
        "lib/app_web/w.ex" => """
        defmodule AppWeb.W do
          use AppWeb, :html

          def nowhere(assigns), do: ~H"<div />"

          attr :rest, :global

          def w(assigns) do
            ~H\"\"\"
            <.nowhere {@rest} />
            <.card {@rest}>x</.card>
            \"\"\"
          end
        end
        """
      }

      project = project(dir, files)

      # `class` looks at each tag it lands on; a prop nothing names goes to the
      # first component the spread reaches, as in @shadcn/lint.
      assert target(project, "AppWeb.W", "w") == "card"
      assert target(project, "AppWeb.W", "w", "other_class") == nil
    end
  end

  describe "which tag wins" do
    test "a tag's children come before it, as @shadcn/lint reads a template", %{tmp_dir: dir} do
      project =
        project(
          dir,
          spread_module(
            "attr :class, :any, default: nil",
            ~s(<.card class={@class}><.card_title class={@class}>x</.card_title></.card>)
          )
        )

      assert target(project, "AppWeb.W", "w") == "card_title"
    end

    test "siblings go in template order", %{tmp_dir: dir} do
      project =
        project(
          dir,
          spread_module(
            "attr :class, :any, default: nil",
            ~s(<.button class={@class}>x</.button><.card class={@class}>x</.card>)
          )
        )

      assert target(project, "AppWeb.W", "w") == "button"
    end

    test "a wrapper later in the chain still wins by template order", %{tmp_dir: dir} do
      files = %{
        "lib/app_web/w.ex" => """
        defmodule AppWeb.W do
          use AppWeb, :html
          attr :class, :any, default: nil

          def outer(assigns) do
            ~H\"\"\"
            <.middle class={@class} />
            <.card class={@class}>x</.card>
            \"\"\"
          end

          attr :class, :any, default: nil
          def middle(assigns), do: ~H"<.inner class={@class} />"

          attr :class, :any, default: nil
          def inner(assigns), do: ~H"<.button class={@class}>x</.button>"
        end
        """
      }

      assert target(project(dir, files), "AppWeb.W", "outer") == "button"
    end

    test "a tag that goes nowhere passes to the next", %{tmp_dir: dir} do
      files = %{
        "lib/app_web/w.ex" => """
        defmodule AppWeb.W do
          use AppWeb, :html
          attr :class, :any, default: nil

          def w(assigns) do
            ~H\"\"\"
            <.nowhere class={@class} />
            <.card class={@class}>x</.card>
            \"\"\"
          end

          attr :class, :any, default: nil
          def nowhere(assigns), do: ~H"<div class={@class} />"
        end
        """
      }

      assert target(project(dir, files), "AppWeb.W", "w") == "card"
    end

    test "reading another class assign does not forward class", %{tmp_dir: dir} do
      project =
        project(
          dir,
          spread_module(
            "attr :title_class, :any, default: nil",
            ~s(<.card class={@title_class}>x</.card>)
          )
        )

      assert target(project, "AppWeb.W", "w") == nil
      assert target(project, "AppWeb.W", "w", "title_class") == "card"
    end

    test "a value mentioning the assign in text does not forward it", %{tmp_dir: dir} do
      project =
        project(dir, spread_module("", ~S|<.card class={"@class assigns.class"}>x</.card>|))

      assert target(project, "AppWeb.W", "w") == nil
    end

    test "an interpolated assign does", %{tmp_dir: dir} do
      project = project(dir, spread_module("", ~S|<.card class={"p-1 #{@class}"}>x</.card>|))

      assert target(project, "AppWeb.W", "w") == "card"
    end

    test "a map spread onto the tag forwards what it reads", %{tmp_dir: dir} do
      project = project(dir, spread_module("", ~S|<.card {%{class: @class}}>x</.card>|))

      assert target(project, "AppWeb.W", "w") == "card"
      assert target(project, "AppWeb.W", "w", "title_class") == nil
    end

    test "a wrapper passing all its assigns is not followed", %{tmp_dir: dir} do
      project = project(dir, spread_module("", ~S|<.card {assigns}>x</.card>|))

      assert target(project, "AppWeb.W", "w") == nil
    end

    test "a non-class attribute reading the assign does not forward it", %{tmp_dir: dir} do
      project = project(dir, spread_module("", ~S|<.card title={@class}>x</.card>|))

      assert target(project, "AppWeb.W", "w") == nil
    end
  end

  describe "chains" do
    # A wrapper `w<i>` handing `class` on to the next, and the last to a button.
    defp chain(depth) do
      links =
        for i <- 1..depth do
          next = if i == depth, do: ".button", else: ".w#{i + 1}"

          """
            attr :class, :any, default: nil
            def w#{i}(assigns), do: ~H"<#{next} class={@class}>x</#{next}>"
          """
        end

      %{
        "lib/app_web/w.ex" => """
        defmodule AppWeb.W do
          use AppWeb, :html
        #{Enum.join(links, "\n")}
        end
        """
      }
    end

    test "resolve at any depth, whatever order the wrappers are in", %{tmp_dir: dir} do
      project = project(dir, chain(40))

      assert target(project, "AppWeb.W", "w1") == "button"
      assert target(project, "AppWeb.W", "w40") == "button"
    end

    test "carry a renamed prop across modules", %{tmp_dir: dir} do
      files = %{
        "lib/app_web/panels.ex" => @panels,
        "lib/app_web/outer.ex" => """
        defmodule AppWeb.Outer do
          use AppWeb, :html
          attr :label_class, :any, default: nil
          def outer(assigns), do: ~H"<AppWeb.Panels.renamed heading_class={@label_class} />"
        end
        """
      }

      assert target(project(dir, files), "AppWeb.Outer", "outer", "label_class") == "card_title"
    end

    test "a long chain stays linear", %{tmp_dir: dir} do
      project = project(dir, chain(2000))

      assert target(project, "AppWeb.W", "w1") == "button"
    end
  end

  describe "wrappers that render each other" do
    test "a component rendering itself still reaches its other tags", %{tmp_dir: dir} do
      files = %{
        "lib/app_web/tree.ex" => """
        defmodule AppWeb.Tree do
          use AppWeb, :html
          attr :class, :any, default: nil

          def tree(assigns) do
            ~H\"\"\"
            <.card class={@class}><.tree class={@class} /></.card>
            \"\"\"
          end
        end
        """
      }

      assert target(project(dir, files), "AppWeb.Tree", "tree") == "card"
    end

    test "each is asked on its own route, whichever comes first", %{tmp_dir: dir} do
      files = %{
        "lib/app_web/w.ex" => """
        defmodule AppWeb.W do
          use AppWeb, :html
          attr :class, :any, default: nil

          def a(assigns) do
            ~H\"\"\"
            <.b class={@class} />
            <.card class={@class}>x</.card>
            \"\"\"
          end

          attr :class, :any, default: nil
          def b(assigns), do: ~H"<.a class={@class} />"
        end
        """
      }

      project = project(dir, files)

      assert target(project, "AppWeb.W", "a") == "card"
      assert target(project, "AppWeb.W", "b") == "card"
    end

    test "a different prop on the same component is not a cycle", %{tmp_dir: dir} do
      files = %{
        "lib/app_web/w.ex" => """
        defmodule AppWeb.W do
          use AppWeb, :html
          attr :class, :any, default: nil
          attr :title_class, :any, default: nil

          def w(assigns) do
            ~H\"\"\"
            <.w title_class={@class} />
            <.card_title class={@title_class}>x</.card_title>
            \"\"\"
          end
        end
        """
      }

      assert target(project(dir, files), "AppWeb.W", "w") == "card_title"
    end

    test "a cycle that reaches nothing has no target", %{tmp_dir: dir} do
      files = %{
        "lib/app_web/w.ex" => """
        defmodule AppWeb.W do
          use AppWeb, :html
          attr :class, :any, default: nil
          def a(assigns), do: ~H"<.b class={@class} />"
          attr :class, :any, default: nil
          def b(assigns), do: ~H"<.a class={@class} />"
          attr :class, :any, default: nil
          def c(assigns), do: ~H"<.c class={@class} />"
        end
        """
      }

      project = project(dir, files)

      assert target(project, "AppWeb.W", "a") == nil
      assert target(project, "AppWeb.W", "b") == nil
      assert target(project, "AppWeb.W", "c") == nil
    end

    # Every wrapper hands `class` to every other, then `last` if there is one.
    defp all_to_all(count, last) do
      wrappers =
        for i <- 1..count do
          tags = for j <- 1..count, j != i, do: ~s(<.w#{j} class={@class} />)

          """
            attr :class, :any, default: nil
            attr :rest, :global
            def w#{i}(assigns) do
              ~H\"\"\"
              #{Enum.join(tags, " ")} <.w#{rem(i, count) + 1} {@rest} /> #{last}
              \"\"\"
            end
          """
        end

      %{
        "lib/app_web/w.ex" => """
        defmodule AppWeb.W do
          use AppWeb, :html
        #{Enum.join(wrappers, "\n")}
        end
        """
      }
    end

    test "many cycles reaching nothing finish", %{tmp_dir: dir} do
      project = project(dir, all_to_all(30, ""))

      assert target(project, "AppWeb.W", "w1") == nil
      assert target(project, "AppWeb.W", "w1", "other_class") == nil
    end

    test "many cycles reaching a component finish, and reach it", %{tmp_dir: dir} do
      project = project(dir, all_to_all(30, ~s(<.card class={@class}>x</.card>)))

      for i <- 1..30, do: assert(target(project, "AppWeb.W", "w#{i}") == "card")
    end
  end

  describe "no_restyle" do
    test "title_class is checked against card_title's contract", %{tmp_dir: dir} do
      assert restyle(dir, ~s(<AppWeb.Panels.panel title_class="text-lg" />)) == []

      [finding] = restyle(dir, ~s(<AppWeb.Panels.panel title_class="w-full" />))

      assert finding.message ==
               ~s("w-full" is not allowed on <.card_title>: its contract allows typography. Use one of those, or put layout classes on a parent element.)
    end

    test "class stays on card's contract", %{tmp_dir: dir} do
      assert restyle(dir, ~s(<AppWeb.Panels.panel class="w-full" />)) == []
      assert [_] = restyle(dir, ~s(<AppWeb.Panels.panel class="text-lg" />))
    end

    test "a contract on the wrong component does not excuse a class", %{tmp_dir: dir} do
      options = [allow: ["layout"], contracts: [[pattern: "^card$", allow: ["spacing"]]]]

      [finding] = restyle(dir, ~s(<AppWeb.Panels.panel title_class="p-4" />), options)

      assert finding.message =~
               "<.panel> forwards title_class to <.card_title>, which owns its spacing."
    end

    test "the props reach through a passing wrapper", %{tmp_dir: dir} do
      assert restyle(dir, ~s(<AppWeb.Panels.passed class="w-full" title_class="text-lg" />)) == []

      [finding] = restyle(dir, ~s(<AppWeb.Panels.passed class="p-4" />))

      assert finding.message =~ "<.passed> forwards class to <.card>, which owns its spacing."
    end

    test "the message names the prop", %{tmp_dir: dir} do
      [color] =
        restyle(dir, ~s(<AppWeb.Panels.panel title_class="bg-red-500" />), allow: ["layout"])

      assert color.message ==
               ~s("bg-red-500" is not allowed on <.panel>: <.panel> forwards title_class to <.card_title>, which owns its color. Use a variant. Add a new variant in lib/app_web/components/core_components.ex only if the design explicitly calls for a treatment none of these provides.)

      [spacing] = restyle(dir, ~s(<AppWeb.Panels.panel title_class="p-4" />), allow: ["layout"])

      assert spacing.message =~
               ~s("p-4" is not allowed on <.panel>: <.panel> forwards title_class to <.card_title>, which owns its spacing.)
    end

    test "a class attribute's message stays as it was", %{tmp_dir: dir} do
      [color] = restyle(dir, ~s(<AppWeb.Panels.panel class="bg-red-500" />), allow: ["layout"])

      assert color.message ==
               ~s("bg-red-500" is not allowed on <.panel>: <.panel> forwards class to <.card>, which owns its color. Use a variant. Add a new variant in lib/app_web/components/core_components.ex only if the design explicitly calls for a treatment none of these provides.)
    end

    test "{{prop}} is the attribute, or class", %{tmp_dir: dir} do
      options = [allow: ["layout"], message: "{{prop}} of {{wrapper}} on {{component}}"]

      [panel] = restyle(dir, ~s(<AppWeb.Panels.panel class="bg-red-500" />), options)
      assert panel.message == "class of .panel on .card"

      [title] = restyle(dir, ~s(<AppWeb.Panels.panel title_class="bg-red-500" />), options)
      assert title.message == "title_class of .panel on .card_title"

      [direct] = restyle(dir, ~s(<.button input_class="bg-red-500">x</.button>), options)
      assert direct.message == "input_class of  on .button"
    end

    test "a prop the wrapper does not forward is not checked", %{tmp_dir: dir} do
      assert restyle(dir, ~s(<AppWeb.Panels.title_only class="bg-red-500" />)) == []
      assert restyle(dir, ~s(<AppWeb.Panels.dropped title_class="bg-red-500" />)) == []
      assert restyle(dir, ~s(<AppWeb.Panels.plain title_class="bg-red-500" />)) == []
      assert restyle(dir, ~s(<AppWeb.Panels.panel footer_class="bg-red-500" />)) == []
    end

    test "a wrapper in the linted file is followed by prop too", %{tmp_dir: dir} do
      page = """
      defmodule AppWeb.PageLive do
        use AppWeb, :live_view

        attr :class, :any, default: nil
        attr :title_class, :any, default: nil

        def local(assigns) do
          ~H\"\"\"
          <.card class={@class}><.card_title class={@title_class}>x</.card_title></.card>
          \"\"\"
        end

        def render(assigns) do
          ~H\"\"\"
          <.local title_class="w-full" />
          \"\"\"
        end
      end
      """

      [finding] =
        restyle(dir, "", @contracts, %{"lib/app_web/live/page_live.ex" => page})

      assert finding.message =~ "<.card_title>: its contract allows typography"
    end

    test "a readable map on the wrapper is judged key by key", %{tmp_dir: dir} do
      assert restyle(dir, ~s|<AppWeb.Panels.panel {%{title_class: "text-lg"}} />|) == []

      [title] = restyle(dir, ~s|<AppWeb.Panels.panel {%{title_class: "w-full"}} />|)
      assert title.message =~ "<.card_title>: its contract allows typography"

      [main] =
        restyle(dir, ~s|<AppWeb.Panels.panel {[class: "text-lg", title_class: "text-lg"]} />|)

      assert main.message =~ "<.panel> forwards class to <.card>"
    end

    test "classes on a wrapper's slot use its class target", %{tmp_dir: dir} do
      options = [allow: ["layout"]]

      [class] =
        restyle(
          dir,
          ~s(<AppWeb.Panels.panel><:title class="bg-red-500">x</:title></AppWeb.Panels.panel>),
          options
        )

      [other] =
        restyle(
          dir,
          ~s(<AppWeb.Panels.panel><:title title_class="bg-red-500">x</:title></AppWeb.Panels.panel>),
          options
        )

      assert class.message =~ "<.panel> forwards class to <.card>"
      assert other.message == class.message
    end

    test "a parent wrapper is placed by its class target", %{tmp_dir: dir} do
      options = [
        allow: ["layout"],
        contracts: [[pattern: "^card$", allow: ["layout", "spacing"]]]
      ]

      template = ~s(<AppWeb.Panels.panel><.button class="p-4">x</.button></AppWeb.Panels.panel>)

      [finding] = restyle(dir, template, options)

      # As @shadcn/lint does, the parent is shown as written, and the component
      # behind it is still a place to offer.
      assert finding.message =~ "spacing on <AppWeb.Panels.panel>, or .card for space around it."

      # A parent whose class goes nowhere is not a place.
      template =
        ~s(<AppWeb.Panels.title_only><.button class="p-4">x</.button></AppWeb.Panels.title_only>)

      [finding] = restyle(dir, template, options)
      refute finding.message =~ "spacing on <AppWeb.Panels.title_only>"
    end
  end

  test "a parent written with its module is shown so, and offered by name", %{tmp_dir: dir} do
    options = [
      allow: ["layout"],
      contracts: [[pattern: "^card$", allow: ["layout", "spacing"]]]
    ]

    template =
      ~s(<AppWeb.CoreComponents.card><.button class="p-4">x</.button></AppWeb.CoreComponents.card>)

    [finding] = restyle(dir, template, options)

    assert finding.message =~
             "margin here, spacing on <AppWeb.CoreComponents.card>, or .card for space around it."

    [finding] = restyle(dir, ~s(<.card><.button class="p-4">x</.button></.card>), options)
    assert finding.message =~ "margin here or spacing on <.card> for space around it."
  end

  describe "other rules read the same target" do
    test "a contract applies through the prop it arrives by", %{tmp_dir: dir} do
      contract = [contracts: [[pattern: "^card_title$", allow: ["bg-red-500"]]]]

      files = fn template ->
        %{"lib/app_web/panels.ex" => @panels, "lib/app_web/live/page_live.ex" => live(template)}
      end

      assert lint(dir, files.(~s(<AppWeb.Panels.panel title_class="bg-red-500" />)),
               rules: [no_raw_colors: {:error, contract}]
             ) == []

      assert [_] =
               lint(dir, files.(~s(<AppWeb.Panels.panel class="bg-red-500" />)),
                 rules: [no_raw_colors: {:error, contract}]
               )
    end

    test "require_static_classes checks a prop that reaches a component", %{tmp_dir: dir} do
      files = fn template ->
        %{"lib/app_web/panels.ex" => @panels, "lib/app_web/live/page_live.ex" => live(template)}
      end

      [finding] =
        lint(dir, files.(~s(<AppWeb.Panels.panel title_class={@dynamic} />)),
          rules: [require_static_classes: :error]
        )

      assert finding.message ==
               "Dynamically built class on <.card_title> cannot be checked. Use static class strings."

      assert lint(dir, files.(~s(<AppWeb.Panels.dropped title_class={@dynamic} />)),
               rules: [require_static_classes: :error]
             ) == []
    end
  end

  test "{{prop}} is a known placeholder, so it raises no typo warning" do
    assert Messages.check("{{prop}}", "no_restyle") == []
    assert [warning] = Messages.check("{{props}}", "no_restyle")
    assert warning =~ ~s(Did you mean "{{prop}}"?)
  end
end

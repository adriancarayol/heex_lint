defmodule HeexLint.Rules.RequireStaticClassesTest do
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  @moduletag :tmp_dir

  defp static(dir, template, extra \\ %{}) do
    files = Map.merge(%{"lib/app_web/live/page_live.ex" => live(template)}, extra)
    lint(dir, files, rules: [require_static_classes: :error])
  end

  test "static strings and choices between complete classes pass", %{tmp_dir: dir} do
    template = """
    <.button class="mt-4">Save</.button>
    <.button class={if @wide, do: "w-full", else: "w-auto"}>Save</.button>
    <.button class={["mt-4", @wide && "w-full"]}>Save</.button>
    """

    assert static(dir, template) == []
  end

  test "classes built from runtime values are reported", %{tmp_dir: dir} do
    [finding] = static(dir, ~S|<.button class={"bg-#{@color}"}>Save</.button>|)

    assert finding.message ==
             "Dynamically built class on <.button> cannot be checked. Use static class strings."

    # At the string that cannot be read.
    assert {finding.line, finding.column} == {6, 21}
  end

  test "socket assigns and unknown calls cannot be read", %{tmp_dir: dir} do
    template = """
    <.button class={@tone}>Save</.button>
    <.button class={classes_for(@tone)}>Save</.button>
    """

    assert [_, _] = static(dir, template)
  end

  test "only the unreadable part of a list is reported", %{tmp_dir: dir} do
    [finding] = static(dir, ~s(<.button class={["mt-4", @extra]}>Save</.button>))
    assert {finding.line, finding.column} == {6, 30}
  end

  test "plain elements are outside the rule", %{tmp_dir: dir} do
    assert static(dir, ~S|<div class={"bg-#{@color}"} />|) == []
  end

  test "a component forwarding its received class is allowed", %{tmp_dir: dir} do
    wrapper =
      component_module("Widgets", "save_button", "attr :class, :any, default: nil", """
      <.button class={["w-full", @class]}>Save</.button>
      """)

    assert lint(dir, %{"lib/app_web/widgets.ex" => wrapper},
             rules: [require_static_classes: :error]
           ) == []
  end

  test "assigns set in the rendering function are read", %{tmp_dir: dir} do
    module = """
    defmodule AppWeb.StatusLive do
      use AppWeb, :live_view

      def render(assigns) do
        assigns = assign(assigns, :tone, if(assigns.ok, do: "mt-2", else: "mt-4"))

        ~H\"\"\"
        <.button class={@tone}>x</.button>
        \"\"\"
      end
    end
    """

    assert lint(dir, %{"lib/app_web/live/status_live.ex" => module},
             rules: [require_static_classes: :error]
           ) == []
  end

  test "custom messages name the component", %{tmp_dir: dir} do
    files = %{"lib/app_web/live/page_live.ex" => live(~s(<.button class={@tone}>x</.button>))}
    options = [message: "Use complete class names on {{component}} so the linter can check them."]
    [finding] = lint(dir, files, rules: [require_static_classes: {:error, options}])
    assert finding.message == "Use complete class names on .button so the linter can check them."
  end
end

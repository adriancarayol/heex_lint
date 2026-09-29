defmodule HeexLint.IntegrationTest do
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  @moduletag :tmp_dir

  test "suppression comments, with or without rule names", %{tmp_dir: dir} do
    template = """
    <%!-- heex-lint-disable-next-line no_raw_colors -- partner brand color --%>
    <span class="bg-amber-400">Sponsor</span>
    <span class="bg-amber-400">Sponsor</span> <%!-- heex-lint-disable-line --%>
    <span class="bg-amber-400">Sponsor</span>
    """

    files = %{"lib/app_web/live/page_live.ex" => live(template)}
    [finding] = lint(dir, files, rules: [no_raw_colors: :error])
    assert finding.line == 9
  end

  test "file-wide suppression in Elixir comments", %{tmp_dir: dir} do
    module = "# heex-lint-disable-file no_raw_colors\n" <> live(~s(<div class="bg-pink-500" />))

    assert lint(dir, %{"lib/app_web/live/page_live.ex" => module}, rules: [no_raw_colors: :error]) ==
             []
  end

  test "--fix applies single suggestions to the literal", %{tmp_dir: dir} do
    files = %{
      "lib/app_web/live/page_live.ex" => live(~s(<div class="flex p-[12px] text-primry" />))
    }

    result = run(dir, files, rules: [no_arbitrary_values: :error, no_raw_colors: :error])
    assert HeexLint.Fixer.apply(result.diagnostics) == 1

    assert File.read!(Path.join(dir, "lib/app_web/live/page_live.ex")) =~
             ~s(class="flex p-3 text-primry")
  end

  test "unparsable templates are failures, not crashes", %{tmp_dir: dir} do
    files = %{"lib/app_web/live/page_live.ex" => live(~s(<div class="a></div>))}
    result = run(dir, files, rules: [no_raw_colors: :error])
    assert [{path, _message}] = result.failures
    assert String.ends_with?(path, "page_live.ex")
  end

  test "components resolve through use, import and aliases", %{tmp_dir: dir} do
    module = """
    defmodule AppWeb.Other do
      use Phoenix.Component
      alias AppWeb.CoreComponents, as: UI

      def page(assigns) do
        ~H\"\"\"
        <UI.button class="bg-pink-500">x</UI.button>
        \"\"\"
      end
    end
    """

    [finding] =
      lint(dir, %{"lib/app_web/other.ex" => module},
        rules: [no_restyle: {:error, allow: ["layout"]}]
      )

    assert finding.message =~ "is not allowed on <.button>"
  end

  test "embedded .heex templates and colocated LiveView templates are read", %{tmp_dir: dir} do
    files = %{
      "lib/app_web/controllers/page_html.ex" => """
      defmodule AppWeb.PageHTML do
        use AppWeb, :html
        embed_templates "page_html/*"
      end
      """,
      "lib/app_web/controllers/page_html/home.html.heex" =>
        ~s(<.button class="p-4">Go</.button>\n),
      "lib/app_web/live/dash_live.ex" => """
      defmodule AppWeb.DashLive do
        use AppWeb, :live_view
      end
      """,
      "lib/app_web/live/dash_live.html.heex" => ~s(<.button class={@tone}>Go</.button>\n)
    }

    findings =
      lint(dir, files,
        rules: [no_restyle: {:error, allow: ["layout"]}, require_static_classes: :error]
      )

    assert Enum.map(findings, &{Path.basename(&1.file), &1.rule}) == [
             {"home.html.heex", :no_restyle},
             {"dash_live.html.heex", :require_static_classes}
           ]
  end

  test "ui and component_imports add to the design system; ignore_imports removes", %{
    tmp_dir: dir
  } do
    files = %{
      "lib/app_web/live/page_live.ex" => live(~s(<.button class="bg-pink-500">x</.button>)),
      "lib/app_web/components/core_components.ex" => core_components()
    }

    rules = [no_restyle: {:error, allow: ["layout"]}]
    assert [_] = lint(dir, files, rules: rules, settings: [ui: "AppWeb.CoreComponents"])
    # ui adds to the components directory; it does not replace it.
    assert [_] = lint(dir, files, rules: rules, settings: [ui: "AppWeb.Other"])

    assert lint(dir, files,
             rules: rules,
             settings: [ignore_imports: ["^AppWeb\\.CoreComponents$"]]
           ) == []
  end
end

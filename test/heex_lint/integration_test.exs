defmodule HeexLint.IntegrationTest do
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  @moduletag :tmp_dir

  test "each app of an umbrella uses its own theme", %{tmp_dir: dir} do
    app = fn name, token ->
      %{
        "apps/#{name}/mix.exs" => "defmodule #{Macro.camelize(name)}.MixProject do\nend\n",
        "apps/#{name}/assets/css/app.css" =>
          ~s(@import "tailwindcss";\n@theme { --color-#{token}: #123456; }\n),
        "apps/#{name}/lib/#{name}_web/live/page_live.ex" =>
          live(~s(<div class="bg-shop bg-admin" />), Macro.camelize(name) <> "Live")
      }
    end

    files =
      Map.merge(app.("shop", "shop"), app.("admin", "admin"))
      |> Map.put("mix.exs", "defmodule Umbrella.MixProject do\nend\n")
      |> Map.put("assets/css/app.css", nil)

    result =
      run(dir, files, rules: [no_raw_colors: :error], inputs: ["apps/*/lib/**/*.{ex,heex}"])

    assert result.diagnostics
           |> Enum.map(
             &{&1.file |> Path.relative_to(dir) |> Path.split() |> Enum.at(1),
              hd(Regex.run(~r/"[^"]+"/, &1.message))}
           )
           |> Enum.sort() == [{"admin", ~s("bg-shop")}, {"shop", ~s("bg-admin")}]
  end

  test "components you don't own: dependencies named by component_imports", %{tmp_dir: dir} do
    salad = """
    defmodule SaladUI.Button do
      use Phoenix.Component

      attr :variant, :string, values: ~w(default secondary ghost), default: "default"
      attr :class, :any, default: nil

      def button(assigns) do
        ~H\"\"\"
        <button class={["inline-flex", @class]} />
        \"\"\"
      end
    end
    """

    page = """
    defmodule AppWeb.ShopLive do
      use Phoenix.LiveView
      import SaladUI.Button

      def render(assigns) do
        ~H\"\"\"
        <.button class="bg-pink-500">Buy</.button>
        \"\"\"
      end
    end
    """

    files = %{
      "deps/salad_ui/lib/salad_ui/button.ex" => salad,
      "lib/app_web/live/shop_live.ex" => page
    }

    rules = [no_restyle: {:error, allow: ["layout"]}]

    # Imported from the dependency, so not CoreComponents' button, and not
    # the design system until the settings say so.
    assert lint(dir, files, rules: rules) == []

    [finding] = lint(dir, files, rules: rules, settings: [component_imports: ["^SaladUI\\."]])

    assert finding.message ==
             ~s|"bg-pink-500" is not allowed on <.button>: <.button> owns its color. Use a variant: default, secondary, ghost. Add a new variant in deps/salad_ui/lib/salad_ui/button.ex only if the design explicitly calls for a treatment none of these provides.|
  end

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

  test "--fix applies only suggestions that generate the same CSS", %{tmp_dir: dir} do
    template = """
    <div class="flex p-[12px]" />
    <div class="bg-neutral-900" />
    <div class="text-[14px]" />
    <div class="hover:px-[var(--gutter)]" />
    """

    files = %{"lib/app_web/live/page_live.ex" => live(template)}

    result =
      run(dir, files, rules: [no_arbitrary_values: :error, no_raw_colors: :error])

    # The nearest color and the font size (which adds a line height) stay
    # suggestions; the spacing step and the variable shorthand apply.
    assert HeexLint.Fixer.apply(result.diagnostics) == 2
    contents = File.read!(Path.join(dir, "lib/app_web/live/page_live.ex"))
    assert contents =~ ~s(class="flex p-3")
    assert contents =~ ~s(class="bg-neutral-900")
    assert contents =~ ~s(class="text-[14px]")
    assert contents =~ ~s|class="hover:px-(--gutter)"|
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

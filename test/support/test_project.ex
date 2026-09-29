defmodule HeexLint.TestProject do
  @moduledoc false

  # Builds a small Phoenix project on disk and lints it.

  alias HeexLint.Config

  @theme """
  @import "tailwindcss";

  @custom-variant dark (&:where(.dark, .dark *));

  @theme inline {
    --color-background: var(--background);
    --color-foreground: var(--foreground);
    --color-primary: var(--primary);
    --color-primary-foreground: var(--primary-foreground);
    --color-muted: var(--muted);
    --color-muted-foreground: var(--muted-foreground);
    --color-destructive: var(--destructive);
    --color-border: var(--border);
    --radius-lg: 10px;
  }

  :root {
    --background: #ffffff;
    --foreground: #0a0a0a;
    --primary: #171717;
    --primary-foreground: #fafafa;
    --muted: #f5f5f5;
    --muted-foreground: #737373;
    --destructive: #e7000b;
    --border: #e5e5e5;
  }

  .dark {
    --background: #0a0a0a;
    --foreground: #fafafa;
  }

  @utility tap-target {
    min-height: 44px;
  }

  .legacy-card {
    border: 1px solid var(--border);
  }
  """

  @core_components """
  defmodule AppWeb.CoreComponents do
    use Phoenix.Component

    attr :variant, :string, values: ~w(default destructive outline), default: "default"
    attr :size, :string, values: ~w(sm lg), default: "sm"
    attr :class, :any, default: nil
    attr :rest, :global
    slot :inner_block

    def button(assigns) do
      ~H\"\"\"
      <button class={["inline-flex rounded-md", @class]} {@rest}>{render_slot(@inner_block)}</button>
      \"\"\"
    end

    attr :class, :any, default: nil
    slot :inner_block

    def card(assigns) do
      ~H\"\"\"
      <div class={["rounded-lg border", @class]}>{render_slot(@inner_block)}</div>
      \"\"\"
    end

    attr :class, :any, default: nil
    slot :inner_block

    def card_title(assigns) do
      ~H\"\"\"
      <h3 class={["font-semibold", @class]}>{render_slot(@inner_block)}</h3>
      \"\"\"
    end

    attr :class, :any, default: nil
    slot :inner_block

    def card_content(assigns) do
      ~H\"\"\"
      <div class={["p-6", @class]}>{render_slot(@inner_block)}</div>
      \"\"\"
    end

    attr :name, :string, required: true
    attr :class, :any, default: "size-4"

    def icon(assigns) do
      ~H\"\"\"
      <span class={[@name, @class]} />
      \"\"\"
    end
  end
  """

  @web """
  defmodule AppWeb do
    def live_view do
      quote do
        use Phoenix.LiveView
        unquote(html_helpers())
      end
    end

    def html do
      quote do
        use Phoenix.Component
        unquote(html_helpers())
      end
    end

    defp html_helpers do
      quote do
        import AppWeb.CoreComponents
        alias AppWeb.Layouts
      end
    end

    defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
  end
  """

  @doc "The default theme CSS."
  def theme, do: @theme

  @doc "The default core components module."
  def core_components, do: @core_components

  @doc """
  A LiveView module rendering `template` (HEEx source).
  """
  def live(template, name \\ "PageLive") do
    """
    defmodule AppWeb.#{name} do
      use AppWeb, :live_view

      def render(assigns) do
        ~H\"\"\"
    #{indent(template, 4)}
        \"\"\"
      end
    end
    """
  end

  @doc """
  A function-component module with one component `name` rendering `template`,
  preceded by `attrs` (Elixir source).
  """
  def component_module(module, name, attrs, template, body \\ "") do
    """
    defmodule AppWeb.#{module} do
      use AppWeb, :html

    #{indent(attrs, 2)}
      def #{name}(assigns) do
    #{indent(body, 4)}
        ~H\"\"\"
    #{indent(template, 4)}
        \"\"\"
      end
    end
    """
  end

  defp indent(text, n) do
    pad = String.duplicate(" ", n)

    text
    |> String.trim_trailing()
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> pad <> line
    end)
  end

  @doc """
  Writes `files` (path => contents) into `dir`, with the default theme,
  web module and core components unless overridden, and lints it.
  Returns the diagnostics.
  """
  def lint(dir, files, config \\ []) do
    result = run(dir, files, config)
    result.diagnostics
  end

  @doc "Like `lint/3`, returning the whole result."
  def run(dir, files, config \\ []) do
    files =
      Map.merge(
        %{
          "assets/css/app.css" => @theme,
          "lib/app_web.ex" => @web,
          "lib/app_web/components/core_components.ex" => @core_components
        },
        Map.new(files)
      )

    files = Map.reject(files, fn {_path, contents} -> contents == nil end)

    for {path, contents} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, contents)
    end

    config = Keyword.put_new(config, :rules, [])
    HeexLint.run(Config.new(config), nil, root: dir)
  end

  @doc """
  Links the fixture's node_modules (Tailwind) into `dir`, for oracle tests.
  """
  def with_tailwind(dir) do
    source = Path.expand("../fixtures/node/node_modules", __DIR__)
    File.ln_s!(source, Path.join(dir, "node_modules"))
    dir
  end

  @doc "The standalone Tailwind binary for CLI-path tests."
  def standalone_bin, do: Path.expand("../fixtures/bin/tailwindcss", __DIR__)

  @doc "The messages of diagnostics for `rule`."
  def messages(diagnostics, rule \\ nil) do
    for d <- diagnostics, rule == nil or d.rule == rule, do: d.message
  end
end

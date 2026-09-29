defmodule HeexLint.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/adriancarayol/heex_lint"

  def project do
    [
      app: :heex_lint,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      description:
        "An agent-first linter for Tailwind classes in Phoenix HEEx templates, with rule parity with @shadcn/lint.",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def application do
    [extra_applications: [:logger, :eex]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [precommit: ["compile --warnings-as-errors", "format --check-formatted", "test"]]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib priv docs mix.exs README.md SETUP.md CHANGELOG.md LICENSE .formatter.exs),
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "SETUP.md",
        "docs/rules.md",
        "docs/design-systems.md",
        "docs/how-it-works.md",
        "docs/adoption.md",
        "docs/troubleshooting.md",
        "docs/api.md",
        "docs/parity.md",
        "CHANGELOG.md"
      ],
      source_ref: "v#{@version}"
    ]
  end
end

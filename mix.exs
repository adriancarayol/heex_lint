defmodule HeexLint.MixProject do
  use Mix.Project

  @version "0.1.0"
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
      description: "An agent-first linter for Tailwind classes in Phoenix HEEx templates.",
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
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs),
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [main: "readme", extras: ["README.md"], source_ref: "v#{@version}"]
  end
end

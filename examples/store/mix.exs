defmodule Store.MixProject do
  use Mix.Project

  def project do
    [
      app: :store,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {Store.Application, []}
    ]
  end

  defp deps do
    [
      {:ector, path: "../../"},
      {:ecto_sql, "~> 3.14.0"},
      {:postgrex, "~> 0.22.2"},
      {:ecto_sqlite3, "~> 0.24.0"},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:plug_cowboy, "~> 2.7"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:benchee, "~> 1.5", only: [:dev, :test]}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end

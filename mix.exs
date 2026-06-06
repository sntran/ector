defmodule Ector.MixProject do
  use Mix.Project

  def project do
    [
      app: :ector,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [
        ignore_modules: [Ector.TestRepo, Ector.TestRepo.SQLite, Ector.TestRepo.Postgres]
      ],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto_sql, "~> 3.14.0"},
      {:postgrex, "~> 0.22.2"},
      {:ecto_sqlite3, "~> 0.24.0"},
      {:stream_data, "~> 1.3", only: :test},
      {:benchee, "~> 1.5", only: [:dev, :test]}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

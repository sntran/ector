defmodule Ector.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/sntran/ector"

  def project do
    [
      app: :ector,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      name: "Ector",
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs(),
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
      {:benchee, "~> 1.5", only: [:dev, :test]},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp description do
    "The Dynamic Schema Engine for Elixir. Zero-migration, JSONB-backed graph " <>
      "topology behind pure Ecto.Schema, Ecto.Changeset, and Ecto.Query mechanics."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib guides .formatter.exs mix.exs README.md LICENSE CHANGELOG.md STABILITY.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md": [title: "Overview"],
        "guides/getting-started.md": [title: "Getting Started"],
        "STABILITY.md": [title: "API Stability"],
        "CHANGELOG.md": [title: "Changelog"]
      ],
      groups_for_extras: [
        Guides: ~r{guides/.*}
      ],
      groups_for_modules: [
        "Public API": [
          Ector,
          Ector.Node,
          Ector.Edge,
          Ector.Changeset,
          Ector.Repo,
          Ector.Migration,
          Ector.Query
        ],
        "Mix Tasks": [
          Mix.Tasks.Ector.Migrate
        ],
        "Internal (Storage Engine)": [
          Ector.Schema,
          Ector.Translator,
          Ector.Translator.Postgres,
          Ector.Translator.SQLite
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

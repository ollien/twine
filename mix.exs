defmodule Twine.MixProject do
  use Mix.Project

  def project do
    [
      app: :twine,
      version: "0.3.0",
      elixir: "~> 1.15",
      description: "Ergonomically trace calls in Elixir with recon_trace",
      package: package(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      preferred_cli_env: ["mneme.test": :test, "mneme.watch": :test]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def package do
    [
      licenses: ["BSD-3-Clause"],
      links: %{"repostitory" => "https://github.com/ollien/twine"}
    ]
  end

  def docs do
    [
      name: "Twine",
      extras: [
        "docs/twine.md"
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:recon, "~> 2.5.6"},
      {:temp, "~> 0.4.9", only: :test},
      {:mneme, ">= 0.10.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end

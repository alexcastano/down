defmodule ExDown.MixProject do
  use Mix.Project

  def project do
    [
      app: :down,
      version: "0.0.1",
      elixir: "~> 1.8",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Down.Application, []}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      canonical: "http://hexdocs.pm/down",
      source_url: "https://github.com/alexcastano/down"
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:httpotion, "~> 3.1", optional: true},
      {:hackney, "~> 1.15", optional: true},
      {:castore, "~> 0.1.0", optional: true},
      {:mint, "~> 1.0", optional: true},
      {:jason, "~> 1.1", only: :test},
      {:benchee, "~> 1.0.0", only: :dev},
      # {:sweet_xml, ">= 0.0.0"},
      {:ex_doc, "~> 0.19", only: :dev, runtime: false}
    ]
  end
end

defmodule Down.MixProject do
  use Mix.Project

  def project do
    [
      app: :down,
      version: "0.0.1",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: dialyzer(),
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp dialyzer() do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_ignore_apps: [:benchee]
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
      {:ibrowse, "~> 4.4", optional: true},
      {:hackney, "~> 1.15", optional: true},
      {:castore, "~> 0.1", optional: true},
      {:mint, "~> 1.0", optional: true},
      {:jason, "~> 1.1", only: :test},
      {:benchee, "~> 1.0.0", only: :dev},
      {:tesla, "~> 1.3.3", only: :dev},
      # {:sweet_xml, ">= 0.0.0"},
      {:dialyxir, "~> 1.0", only: :dev, runtime: false},
      {:bypass, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.19", only: :dev, runtime: false}
    ]
  end
end

defmodule ExDown.MixProject do
  use Mix.Project

  def project do
    [
      app: :down,
      version: "0.0.1",
      elixir: "~> 1.8",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
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

  defp description do
    "Library for streaming, flexible and safe downloading of remote files"
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
      {:httpotion, "~> 3.1.0", optional: true},
      {:hackney, "~> 1.15.1", optional: true},
      {:castore, "~> 0.1.0", optional: true},
      {:mint, "~> 0.2.0", optional: true},
      {:jason, "~> 1.1", only: :test},
      {:benchee, "~> 0.11", only: :dev},
      {:ex_doc, "~> 0.19", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      # This option is only needed when you don't want to use the OTP application name
      name: "down",
      maintainers: ["Alex Castaño"],
      licenses: ["Apache 2.0"],
      links: %{
        "GitHub" => "https://github.com/alexcastano/down",
        "Author" => "https://alexcastano.com"
      }
    ]
  end
end

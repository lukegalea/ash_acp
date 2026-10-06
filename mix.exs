# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/lukegalea/ash_acp"

  def project do
    [
      app: :ash_acp,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "Agent Client Protocol (ACP) server wire adapter for Ash. JSON-RPC 2.0 over ndjson " <>
          "stdio or HTTP — sessions, streamed updates and permission requests mapped onto " <>
          "host-declared behaviours. Transport and mapping only: no business logic and no " <>
          "second authorization model.",
      package: package(),
      name: "AshAcp",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # test/support carries the fake host: the Simple-data-layer resources and
  # the ETS-coordinated seam implementations every protocol test runs
  # against.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      # Rides in via `ash`, but this library encodes and decodes every wire
      # message with it directly -- a transitive dependency the suite leans on
      # is one `mix deps.update` away from disappearing, so it is declared.
      {:jason, "~> 1.4"},
      # Optional deliberately: only `AshAcp.Plug` (the HTTP transport) needs
      # it, and it is guarded with `Code.ensure_compiled?/1` so a consumer on
      # bare stdio does not drag Plug into their tree.
      {:plug, "~> 1.16", optional: true},
      # Test-only: backs the `Ash.Policy.Authorizer` checks in the fake host
      # resources the lifecycle and permission tests run against.
      {:simple_sat, "~> 0.1", only: [:dev, :test]},
      # Test-only: validates the golden wire fixtures (and a constructed
      # session/update) against the vendored ACP v1 JSON schema, so protocol
      # drift cannot merge silently.
      {:ex_json_schema, "~> 0.10", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      maintainers: ["Luke Galea <luke@ideaforge.org>"],
      licenses: ["MIT"],
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE usage-rules.md),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Agent Client Protocol" => "https://agentclientprotocol.com"
      }
    ]
  end
end

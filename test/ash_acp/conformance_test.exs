# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.ConformanceTest do
  @moduledoc """
  Spec conformance: every golden fixture's wire output — and the inbound
  inputs that produced it — validates against the vendored ACP v1 schema,
  plus a constructed `session/update` exercising the `_meta.a2ui` carrier.
  """
  use ExUnit.Case, async: true

  @fixtures_dir "priv/acp_fixtures"

  test "the vendored schema is provenanced" do
    source = AshAcp.TestSupport.SchemaConformance.provenance()
    assert source["source"] == "agentclientprotocol/agent-client-protocol"
    assert source["path"] == "schema/v1/schema.json"
    assert File.exists?(Path.join(["priv", "acp_schema", "schema.json"]))
  end

  test "every golden fixture validates against the ACP v1 schema" do
    @fixtures_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.sort()
    |> Enum.each(fn file ->
      fixture =
        @fixtures_dir
        |> Path.join(file)
        |> File.read!()
        |> Jason.decode!()

      problems =
        AshAcp.TestSupport.SchemaConformance.validate_fixture(
          fixture["expected"],
          fixture["input"]
        )

      assert problems == [],
             "fixture #{file} drifted from the ACP v1 schema:\n#{Enum.join(problems, "\n")}"
    end)
  end

  test "a constructed session/update carrying _meta.a2ui is schema-valid" do
    message = AshAcp.TestSupport.SchemaConformance.constructed_session_update()

    problems =
      AshAcp.TestSupport.SchemaConformance.validate_outbound(message, %{})

    assert problems == [], "constructed session/update drifted:\n#{Enum.join(problems, "\n")}"
  end
end

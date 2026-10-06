# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.FixturesTest do
  @moduledoc """
  Golden-fixture conformance: every file in `priv/acp_fixtures` records the
  exact wire output (responses + notifications, in order) for a scripted
  input against the fake host. The suite compares actual output to the
  recorded output, byte-for-byte at the decoded-map level.

  Regenerate with `REGEN_FIXTURES=1 mix test test/ash_acp/fixtures_test.exs`
  — then diff the files: they are the spec-conformance record.
  """
  use ExUnit.Case, async: false

  @fixtures_dir "priv/acp_fixtures"

  setup do
    FakeHost.start()
    :ok
  end

  test "recorded fixtures match actual server output" do
    @fixtures_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.sort()
    |> Enum.each(&run_fixture/1)
  end

  defp run_fixture(file) do
    path = Path.join(@fixtures_dir, file)
    fixture = path |> File.read!() |> Jason.decode!()

    # every scenario starts from a pristine fake host: deterministic session
    # ids ("sess-1"), counters and transcript
    FakeHost.start()

    apply_setup(fixture["setup"] || %{})
    state = AshAcp.Server.new(FakeHost.config())

    {actual, _final_state} =
      Enum.reduce(fixture["input"], {[], state}, fn line, {acc, st} ->
        {wire, st2} = AshAcp.Server.handle_line(line, st)
        {acc ++ wire, st2}
      end)

    if System.get_env("REGEN_FIXTURES") do
      File.write!(
        path,
        Jason.encode!(
          %{
            "description" => fixture["description"],
            "setup" => fixture["setup"] || %{},
            "input" => fixture["input"],
            "expected" => actual
          },
          pretty: true
        ) <> "\n"
      )
    else
      assert actual == fixture["expected"], """
      Golden fixture mismatch in #{file}.

      --- expected (recorded) ---
      #{Jason.encode!(fixture["expected"], pretty: true)}

      --- actual ---
      #{Jason.encode!(actual, pretty: true)}
      """
    end
  end

  defp apply_setup(setup) do
    case setup["prompt"] do
      "summarize" -> FakeHost.set_prompt_mode({:ok, :summarize})
      "publish" -> FakeHost.set_prompt_mode({:ok, :publish})
      "restricted" -> FakeHost.set_prompt_mode({:ok, :restricted})
      "unresolvable" -> FakeHost.set_prompt_mode({:ok, :unresolvable})
      _ -> :ok
    end

    case setup["permission"] do
      "approved" -> FakeHost.set_permission_mode({:approved, nil})
      "denied" -> FakeHost.set_permission_mode({:denied})
      "pending" -> FakeHost.set_permission_mode({:pending, "approval-ref-1"})
      _ -> :ok
    end

    if Map.has_key?(setup, "actor") do
      FakeHost.set_actor(actor_term(setup["actor"]))
    end

    if setup["surface"] == false do
      FakeHost.set_surface(nil)
    end

    :ok
  end

  defp actor_term(nil), do: nil
  defp actor_term(name) when is_binary(name), do: String.to_atom(name)
end

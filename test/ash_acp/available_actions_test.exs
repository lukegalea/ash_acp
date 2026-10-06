# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.AvailableActionsTest do
  @moduledoc "The Ash.can?/3 pruning that feeds available_commands_update."
  use ExUnit.Case, async: true

  alias AshAcp.AvailableActions

  test "tuples derive name and description from the action" do
    commands = AvailableActions.for_actor(:anyone, [{FakeHost.Note, :summarize}])

    assert [%{"name" => "FakeHost.Note.summarize", "description" => "Summarize the given text"}] =
             commands
  end

  test "actors denied by policy lose the action" do
    commands = AvailableActions.for_actor(nil, [{FakeHost.Note, :restricted}])
    assert commands == []

    commands = AvailableActions.for_actor(:operator, [{FakeHost.Note, :restricted}])
    assert [%{"name" => "FakeHost.Note.restricted"}] = commands
  end

  test "maps may override name, description and input" do
    commands =
      AvailableActions.for_actor(:operator, [
        %{
          action: {FakeHost.Note, :summarize},
          name: "summarize",
          description: "custom",
          input: %{"type" => "unstructured"}
        }
      ])

    assert [
             %{
               "name" => "summarize",
               "description" => "custom",
               "input" => %{"type" => "unstructured"}
             }
           ] = commands
  end

  test "unknown candidate shapes are skipped, not raised" do
    assert [] = AvailableActions.for_actor(:operator, [:junk, {%FakeHost.Note{}, :nope}, "nope"])
  end
end

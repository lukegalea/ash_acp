# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.Updates do
  @moduledoc """
  Builders for ACP `SessionUpdate` objects (the `update` inside a
  `session/update` notification), shaped to the vendored ACP v1 schema.

  The server builds its own updates with these; hosts use them for the
  `updates` an `AshAcp.ExtMethods` handler returns (and an agent loop for
  its thinking and plan):

      {:ok, result, [AshAcp.Updates.agent_thought("Checking the calendar")]}

  `notification/2` wraps an update for a session.
  """

  alias AshAcp.JsonRpc

  @type update :: %{required(String.t()) => term()}

  @doc "An agent message chunk (`agent_message_chunk`)."
  @spec agent_message(String.t()) :: update()
  def agent_message(text), do: chunk("agent_message_chunk", text)

  @doc "An agent thought chunk (`agent_thought_chunk`) — the agent's visible reasoning."
  @spec agent_thought(String.t()) :: update()
  def agent_thought(text), do: chunk("agent_thought_chunk", text)

  @doc "A user message chunk (`user_message_chunk`), used for transcript replay."
  @spec user_message(String.t()) :: update()
  def user_message(text), do: chunk("user_message_chunk", text)

  @doc """
  The agent's plan (`plan`). Each entry is a map with `:content` (string),
  `:priority` (`:high | :medium | :low`, default `:medium`) and `:status`
  (`:pending | :in_progress | :completed`, default `:pending`). Per ACP, every
  plan update carries the complete list — the client replaces the whole plan.
  """
  @spec plan([map()]) :: update()
  def plan(entries) when is_list(entries) do
    %{"sessionUpdate" => "plan", "entries" => Enum.map(entries, &plan_entry/1)}
  end

  @doc "The available commands (`available_commands_update`)."
  @spec available_commands([map()]) :: update()
  def available_commands(commands) when is_list(commands) do
    %{"sessionUpdate" => "available_commands_update", "availableCommands" => commands}
  end

  @doc "Session metadata (`session_info_update`), e.g. a title."
  @spec session_info(String.t()) :: update()
  def session_info(title) when is_binary(title) do
    %{"sessionUpdate" => "session_info_update", "title" => title}
  end

  @doc "Wraps an update as a `session/update` notification for `session_id`."
  @spec notification(String.t(), update()) :: map()
  def notification(session_id, update) do
    JsonRpc.notification("session/update", %{"sessionId" => session_id, "update" => update})
  end

  defp chunk(kind, text) do
    %{"sessionUpdate" => kind, "content" => %{"type" => "text", "text" => to_string(text)}}
  end

  defp plan_entry(entry) do
    %{
      "content" => to_string(fetch(entry, :content)),
      "priority" => to_string(fetch(entry, :priority) || :medium),
      "status" => to_string(fetch(entry, :status) || :pending)
    }
  end

  defp fetch(entry, key), do: Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
end

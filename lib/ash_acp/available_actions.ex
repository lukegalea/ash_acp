# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.AvailableActions do
  @moduledoc """
  Per-actor action surface pruning with `Ash.can?/3`.

  Given the session's actor and the host's candidate action list, returns the
  actions the actor may actually run. The result feeds the
  `available_commands_update` of a `session/update` — the ACP client renders
  it, so the operator only ever sees what their policies allow.

  This is the AST-84 pattern (prune the agent tool surface per actor) applied
  at the wire: the *only* authorization authority is Ash. A host that wants an
  action hidden from everyone declares a policy that denies everyone; there is
  no separate exposure list to keep in sync.

  ## Candidates

  Each candidate is one of:

  * `{MyApp.Resource, :action_name}` — name and description are derived from
    the action (`"MyApp.Resource.action_name"` and the action's description).
  * a map with `action: {MyApp.Resource, :action_name}` and optional
    `name:`/`description:`/`input:` overrides.

  `Ash.can?/3` options (`:maybe_is`, `:run_queries?`, ...) pass through
  unchanged.
  """

  @spec for_actor(term(), candidates :: list(), keyword()) :: [map()]
  def for_actor(actor, candidates, opts \\ []) when is_list(candidates) do
    candidates
    |> Enum.map(&normalize/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn candidate ->
      Ash.can?(candidate.action, actor, opts)
    end)
    |> Enum.map(&to_command/1)
  end

  defp normalize({resource, action} = pair) when is_atom(resource) and is_atom(action),
    do: %{
      action: pair,
      name: default_name(resource, action),
      description: description(resource, action),
      input: nil
    }

  defp normalize(%{action: {resource, action}} = candidate) do
    %{
      action: {resource, action},
      name: Map.get(candidate, :name) || default_name(resource, action),
      description: Map.get(candidate, :description) || description(resource, action),
      input: Map.get(candidate, :input)
    }
  end

  defp normalize(%{"action" => {resource, action}} = candidate) do
    %{
      action: {resource, action},
      name: Map.get(candidate, "name") || default_name(resource, action),
      description: Map.get(candidate, "description") || description(resource, action),
      input: Map.get(candidate, "input")
    }
  end

  defp normalize(_other), do: nil

  defp default_name(resource, action) do
    resource
    |> Module.split()
    |> Enum.join(".")
    |> Kernel.<>(".#{action}")
  end

  defp description(resource, action) do
    case Ash.Resource.Info.action(resource, action) do
      %{description: description} when is_binary(description) -> description
      _ -> ""
    end
  end

  defp to_command(%{name: name, description: description, input: nil}),
    do: %{"name" => name, "description" => description}

  defp to_command(%{name: name, description: description, input: input}),
    do: %{"name" => name, "description" => description, "input" => input}
end

# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp do
  @moduledoc """
  Agent Client Protocol (ACP) server wire adapter for Ash.

  AshAcp is to ACP what `ash_graphql` is to GraphQL: a **transport and a
  mapping**. It speaks JSON-RPC 2.0 over ndjson (stdio, or HTTP through
  `AshAcp.Plug`) and maps the protocol onto host-declared behaviours. It ships
  no Ash resources, generates no A2UI payloads, and — the one rule that must
  never be broken — **runs no authorization model of its own**: every action is
  executed through Ash with the session's actor and `authorize?: true`, so
  policies are defined exactly once, on the resources.

  ## The wire

  ACP v1 (`AshAcp.acp_version/0`) over newline-delimited JSON-RPC:

  * `initialize` — capability and version negotiation, agent info from config.
  * `session/new` — delegates to the host `AshAcp.SessionStore`.
  * `session/load` — resumes from the host store, replaying the transcript.
  * `session/prompt` — `AshAcp.PromptTarget` resolves the prompt to a declared
    Ash action; the library executes it with the session actor and
    `authorize?: true`, streaming `session/update` notifications.
  * `session/cancel` — cancels the in-flight prompt (`stopReason: "cancelled"`).
  * `session/request_permission` — outbound request mapped onto the host
    `AshAcp.PermissionRequest` seam (ADR 0015: approvals live in Ash).

  ## Host seams

  | Behaviour | Purpose |
  |---|---|
  | `AshAcp.SessionStore` | Session persistence (the host's session resource). |
  | `AshAcp.PromptTarget` | Prompt text → Ash action + inputs. |
  | `AshAcp.PermissionRequest` | Approvals mapped onto the host approval resource. |
  | `AshAcp.SurfaceProvider` (optional) | Opaque A2UI surface descriptors carried under the update's `surface` field. |

  Configure them in application env:

      config :ash_acp,
        session_store: MyApp.AcpSessionStore,
        prompt_target: MyApp.AcpPromptTarget,
        permission_request: MyApp.AcpPermissionRequest,
        surface_provider: MyApp.AcpSurfaceProvider,
        agent_info: %{name: "my_app", version: "1.0.0"}

  Then run on stdio (see `AshAcp.run_stdio/1` and `mix ash_acp.stdio`) or mount
  `AshAcp.Plug` in a Phoenix endpoint.

  The pure protocol core lives in `AshAcp.Server`:

      {response, notifications, new_state} =
        AshAcp.Server.handle_message(message, state)

  Both transports are thin shells over it.
  """

  @acp_version 1

  @doc """
  The ACP protocol version this library implements and pins.

  `1` — the v1 wire protocol (integer `protocolVersion`, methods
  `initialize`, `session/new`, `session/load`, `session/prompt`,
  `session/cancel`, agent→client `session/update` and
  `session/request_permission`). Tests assert the initialize handshake
  reports exactly this value.
  """
  @spec acp_version() :: pos_integer()
  def acp_version, do: @acp_version

  @version "0.1.0"

  @doc false
  @spec library_version() :: String.t()
  def library_version, do: @version

  @config_keys [
    :session_store,
    :prompt_target,
    :permission_request,
    :surface_provider,
    :agent_info,
    :authenticate
  ]

  @doc """
  Resolves the effective configuration: the given overrides on top of
  `:ash_acp` application env.
  """
  @spec config(keyword() | map()) :: %{
          optional(:session_store) => module() | nil,
          optional(:prompt_target) => module() | nil,
          optional(:permission_request) => module() | nil,
          optional(:surface_provider) => module() | nil,
          optional(:agent_info) => map() | nil
        }
  def config(overrides \\ []) do
    overrides = Map.new(overrides)

    Enum.reduce(@config_keys, %{}, fn key, acc ->
      Map.put(acc, key, Map.get(overrides, key) || Application.get_env(:ash_acp, key))
    end)
    |> Map.update(:agent_info, default_agent_info(), fn
      nil -> default_agent_info()
      info when is_map(info) -> info
    end)
  end

  @doc """
  Boots `AshAcp.Endpoint` on stdio: reads ndjson JSON-RPC from
  `:standard_io`, writes every response and notification back as ndjson,
  until EOF.

  Backs `mix ash_acp.stdio` and host release usage:

      config :ash_acp, session_store: MyApp.AcpSessionStore, ...

      # in a release, or:
      $ mix ash_acp.stdio
  """
  @spec run_stdio(keyword()) :: :ok
  def run_stdio(opts \\ []) do
    AshAcp.Endpoint.run_stdio(opts)
  end

  defp default_agent_info, do: %{name: "ash_acp", version: @version}
end

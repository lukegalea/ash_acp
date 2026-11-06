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
  * `session/list` — lists the host's sessions, when the store exports `list/1`.
  * `session/cancel` — cancels the in-flight prompt (`stopReason: "cancelled"`).
  * `session/request_permission` — outbound request mapped onto the host
    `AshAcp.PermissionRequest` seam (ADR 0015: approvals live in Ash).
  * `_`-prefixed extension methods — routed to the host's
    `AshAcp.ExtMethods` and advertised under `agentCapabilities._meta.ash`.

  ## Host seams

  | Behaviour | Purpose |
  |---|---|
  | `AshAcp.SessionStore` | Session persistence (the host's session resource). |
  | `AshAcp.PromptTarget` | Prompt text → Ash action + inputs. |
  | `AshAcp.PermissionRequest` | Approvals mapped onto the host approval resource. |
  | `AshAcp.SurfaceProvider` (optional) | Opaque A2UI surface descriptors carried under the update's `_meta.a2ui`. |
  | `AshAcp.ExtMethods` (optional) | `_`-prefixed extension methods (`_ash/surface/open`, `_a2ui/action`, ...). |
  | `AshAcp.Authenticator` (optional) | The connection's actor. |

  Configure them in application env:

      config :ash_acp,
        session_store: MyApp.AcpSessionStore,
        prompt_target: MyApp.AcpPromptTarget,
        permission_request: MyApp.AcpPermissionRequest,
        surface_provider: MyApp.AcpSurfaceProvider,
        ext_methods: MyApp.AcpExt,
        agent_info: %{name: "my_app", version: "1.0.0"},
        # the command palette, pruned per actor with Ash.can?/3 — a list, or
        # {m, f, a} / a zero-arity fun evaluated whenever a palette is built
        # (for a palette derived at runtime, e.g. from a surface registry)
        candidate_actions: [{MyApp.Helpdesk.Ticket, :summarize}]

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

  @version "0.5.0"

  @doc false
  @spec library_version() :: String.t()
  def library_version, do: @version

  @config_keys [
    :session_store,
    :prompt_target,
    :permission_request,
    :surface_provider,
    :ext_methods,
    :agent_info,
    :authenticate,
    :candidate_actions,
    :permission_options,
    :kind_resolver
  ]

  @permission_option_names %{
    "allow_once" => "Allow once",
    "allow_always" => "Allow always",
    "reject_once" => "Reject once",
    "reject_always" => "Reject always"
  }

  @default_permission_options ["allow_once", "allow_always", "reject_once"]

  @doc """
  Resolves the effective configuration: the given overrides on top of
  `:ash_acp` application env. Every documented key is carried —
  `:candidate_actions` defaults to `[]`, `:agent_info` to this library's.
  An `{m, f, a}` or zero-arity function `:candidate_actions` is carried as
  is and evaluated by the server each time it builds a palette — the way a
  host whose palette is computed at runtime configures every transport,
  `mix ash_acp.stdio` included, from app env alone.

  `:permission_options` names the ACP `PermissionOptionKind`s a
  `session/request_permission` offers, in order (strings or atoms), and
  defaults to `allow_once`, `allow_always`, `reject_once`. A host whose
  approval resource has nowhere to remember a standing grant leaves
  `allow_always` out. An unknown kind raises `ArgumentError`.

  `:kind_resolver` is an optional `AshAcp.KindResolver` that names the ACP
  tool kind of an action whose spec does not set `:kind`. Without one, the
  kinds are the library defaults.
  """
  @spec config(keyword() | map()) :: %{
          optional(:session_store) => module() | nil,
          optional(:prompt_target) => module() | nil,
          optional(:permission_request) => module() | nil,
          optional(:surface_provider) => module() | nil,
          optional(:ext_methods) => module() | nil,
          optional(:authenticate) => module() | nil,
          optional(:agent_info) => map(),
          optional(:candidate_actions) => list() | {module(), atom(), list()} | (-> list()),
          optional(:permission_options) => [String.t()],
          optional(:kind_resolver) => module() | nil
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
    |> Map.update(:candidate_actions, [], &(&1 || []))
    |> Map.update(:permission_options, @default_permission_options, fn kinds ->
      kinds |> permission_options() |> Enum.map(& &1["kind"])
    end)
  end

  @doc """
  The `PermissionOption`s a `session/request_permission` offers for `kinds`
  (the `:permission_options` config; `nil` for the default), as wire maps
  whose `optionId` is the kind. Raises `ArgumentError` for an unknown kind.
  """
  @spec permission_options([String.t() | atom()] | nil) :: [map()]
  def permission_options(nil), do: permission_options(@default_permission_options)

  def permission_options(kinds) when is_list(kinds) do
    Enum.map(kinds, fn kind ->
      kind = to_string(kind)

      case Map.fetch(@permission_option_names, kind) do
        {:ok, name} ->
          %{"optionId" => kind, "name" => name, "kind" => kind}

        :error ->
          raise ArgumentError,
                "unknown ACP permission option #{inspect(kind)}; expected one of " <>
                  Enum.join(Map.keys(@permission_option_names), ", ")
      end
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

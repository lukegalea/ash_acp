# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.ExtMethods do
  @moduledoc """
  Optional host-implemented seam for ACP **extension methods** — JSON-RPC
  methods whose names start with `_` (ACP "Extensibility": custom methods are
  underscore-prefixed, and an agent advertises them through `_meta`).

  Configure it with `config :ash_acp, ext_methods: MyApp.AcpExt`. The library
  routes every inbound `_`-prefixed method the module lists in `methods/0` to
  `handle/3`; an unlisted `_` method is `-32601` like any unknown method, and
  an extension *notification* (no `id`) is dispatched with its result
  discarded.

  The library still owns no business logic and no authorization model: it
  resolves the session, hands the handler the session's actor, carries the
  handler's result verbatim (string-keyed, wire-safe), and — when the handler
  says an operation is consequential — runs the host's own
  `AshAcp.PermissionRequest` seam and, if that pends, the standard
  `session/request_permission` round trip.

  ## Advertisement

  `initialize` advertises the methods under the ACP `_meta` extension point:

      "agentCapabilities": {"_meta": {"ash": {"extMethods": [...], ...}}}

  mirrored at the result's top-level `_meta.ash`. `capabilities/1` (optional)
  merges extra keys into that `ash` object — e.g. a `"surfaces"` index.

  ## The handler context

  `handle/3` and `capabilities/1` receive a map:

  * `:session` — the host session (from `AshAcp.SessionStore`) when the
    params carry a `sessionId`, else `nil`. Unknown or foreign sessions
    never reach the handler (`-32002`).
  * `:session_id` — the `sessionId` string, or `nil`.
  * `:actor` — the session's actor, else the connection's authenticated
    actor (`AshAcp.Authenticator`), else `nil` (trusted-boundary hosts
    supply their own operator). Run every Ash call with it and
    `authorize?: true`.
  * `:permission` — `nil` on the first call; `{:approved, approval}` or
    `:denied` on the call that follows a `{:request_permission, spec}`.

  ## Return values

  * `{:ok, result}` — `result` is the JSON-RPC result (any JSON value).
  * `{:ok, result, updates}` — additionally emits each `updates` entry (an
    ACP `SessionUpdate` object such as those built by `AshAcp.Updates`) as a
    `session/update` notification for the session, before the response.
    Requires a session.
  * `{:request_permission, spec}` — the operation is consequential. `spec`
    is handed to `AshAcp.PermissionRequest.request/3` exactly like a prompt's
    action spec (`:title`, optional `:kind` (default `:execute`), `:inputs`,
    plus whatever the host's seam reads, e.g. `:resource`/`:action`); the
    library adds `ext: %{method: m, params: p}`. Approved or denied — at once
    or after the client answers a `session/request_permission` — the library
    calls `handle/3` **again** with `:permission` set, and that second
    return answers the request. Requires a session. Approval never bypasses
    Ash policies: the second call still runs as the actor with
    `authorize?: true`.
  * `{:error, code, message}` / `{:error, code, message, data}` — a
    JSON-RPC error with an integer code (`-32602` invalid params, `-32002`
    resource not found, ...).
  * `{:error, reason}` — `-32603` with `reason` inspected into `data`.

  Anything else is a contract violation: `-32603` plus a `Logger.error`
  naming the module, never a silent hang.

  ## The `ash` conventions

  The method names this library's hosts share (the shapes are fixed by
  `priv/acp_schema/ash_ext.json` and checked by the conformance suite):

  | Method | Params | Result |
  |---|---|---|
  | `_ash/surfaces/list` | `{sessionId?}` | `{surfaces: [{id, title, description?, group?, recordScoped?}]}` — pruned for the actor |
  | `_ash/surface/open` | `{sessionId, surface, recordId?, query?}` | `{surfaceId, a2ui}` — `a2ui` has the `update._meta.a2ui` shape |
  | `_a2ui/action` | `{sessionId, surfaceId, action}` | `{outcome: "applied" \\| "denied", a2ui}` — `a2ui` usually `updateDataModel` messages |

  `_ash/surface/open` is a direct open (no prompt turn): hosts record it in
  their session store so `AshAcp.SurfaceProvider` re-emits it on
  `session/load`. `_a2ui/action` runs the A2UI action as the session actor
  and returns `{:request_permission, spec}` for consequential actions.
  """

  @type ctx :: %{
          session: term() | nil,
          session_id: String.t() | nil,
          actor: term(),
          permission: nil | {:approved, term()} | :denied
        }

  @type result ::
          {:ok, term()}
          | {:ok, term(), [map()]}
          | {:request_permission, map()}
          | {:error, integer(), String.t()}
          | {:error, integer(), String.t(), term()}
          | {:error, term()}

  @doc "The `_`-prefixed method names this host implements."
  @callback methods() :: [String.t()]

  @doc "Extra keys merged into the advertised `_meta.ash` object (e.g. `\"surfaces\"`)."
  @callback capabilities(ctx :: map()) :: map()

  @doc "Handles one extension method call. See the moduledoc for the contract."
  @callback handle(method :: String.t(), params :: map(), ctx :: ctx()) :: result()

  @optional_callbacks capabilities: 1

  @doc "The conventional `ash` extension method names (see the moduledoc)."
  @spec conventional_methods() :: [String.t()]
  def conventional_methods, do: ["_ash/surfaces/list", "_ash/surface/open", "_a2ui/action"]
end

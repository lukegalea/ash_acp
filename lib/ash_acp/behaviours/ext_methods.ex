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
  * `:denied_by` — with `permission: :denied`, who said no: `:policy` (Ash's
    policies refuse the actor, decided up front — nobody was asked),
    `:host` (`AshAcp.PermissionRequest.request/3` returned `{:denied}`) or
    `:client` (the person rejected or cancelled the
    `session/request_permission`, or `resolve/3` denied it). `nil`
    otherwise. A policy refusal is a *failed* write, not a declined one —
    `_a2ui/action` answers it with `action_failed(:forbidden, ...)`.

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
    library adds `ext: %{method: m, params: p}`. When the spec names the
    Ash call the handler will make — `:resource` and `:action`, plus the
    `:inputs` and `:tenant` it will pass, and for an update or destroy the
    `:record` it will change (without one, an update or destroy is not
    checked up front: a filter policy cannot be judged against a blank
    record) — the library first checks it with
    `Ash.can/3` as the handler's `:actor`: a definite refusal skips the
    approval seam and the client entirely (`permission: :denied,
    denied_by: :policy`); `:maybe` or an error proceeds as below. Approved
    or denied — at once or after the client answers a
    `session/request_permission` — the library calls `handle/3` **again**
    with `:permission` set, and that second return answers the request.
    Requires a session. Approval never bypasses Ash policies: the second
    call still runs as the actor with `authorize?: true`. A second return
    whose result is `%{"outcome" => "failed"}` settles the client's pending
    tool call as failed.
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
  | `_a2ui/action` | `{sessionId, surfaceId, action}` | `{outcome: "applied" \\| "denied" \\| "failed", error?, a2ui}` — `a2ui` usually `updateDataModel` messages |

  `_ash/surface/open` is a direct open (no prompt turn): hosts record it in
  their session store so `AshAcp.SurfaceProvider` re-emits it on
  `session/load`. `_a2ui/action` runs the A2UI action as the session actor
  and returns `{:request_permission, spec}` for consequential actions.

  ### `_a2ui/action` outcomes

  * `"applied"` — the action ran and succeeded. Only then.
  * `"denied"` — an approval was declined (`denied_by: :host | :client`);
    nothing ran.
  * `"failed"` — the action was refused by policy (up front or at
    execution), its input was invalid, or it errored. Carries
    `error: {kind, message}`: `kind` is `"forbidden"`, `"invalid"` or
    `"error"`, `message` a short human sentence. Never record contents,
    input values, stack traces or credentials — build it with
    `action_failed/2`, which classifies an Ash error and writes a safe
    message.
  """

  @type ctx :: %{
          session: term() | nil,
          session_id: String.t() | nil,
          actor: term(),
          permission: nil | {:approved, term()} | :denied,
          denied_by: nil | :policy | :host | :client
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

  @failure_kinds [:forbidden, :invalid, :error]

  @doc """
  The `_a2ui/action` result for a write that did not happen:
  `%{"outcome" => "failed", "error" => failure(error), "a2ui" => a2ui}`.

  `error` is an Ash error (any exception or error term `Ash.Error.to_error_class/1`
  accepts) or one of the kinds `:forbidden`, `:invalid`, `:error`. See
  `failure/2` for what reaches the wire. `opts` pass through to it.

      {:error, error} -> {:ok, AshAcp.ExtMethods.action_failed(error, status_messages)}
  """
  @spec action_failed(term(), [map()] | map(), keyword()) :: map()
  def action_failed(error, a2ui \\ [], opts \\ []) do
    %{"outcome" => "failed", "error" => failure(error, opts), "a2ui" => a2ui}
  end

  @doc """
  A wire-safe description of a failed write: `%{"kind" => kind, "message" =>
  message}`.

  `kind` follows the Ash error class — `"forbidden"`, `"invalid"`, else
  `"error"`. `message` is fixed text per kind; for `"invalid"` it names the
  offending fields (attribute and argument names, never their values). No
  part of the error's own message is used: Ash messages can carry input
  values, bread crumbs and stack traces. Pass `message:` to supply your own
  (already safe, e.g. localized) sentence.
  """
  @spec failure(term(), keyword()) :: %{String.t() => String.t()}
  def failure(error, opts \\ []) do
    {kind, fields} = classify(error)

    %{
      "kind" => Atom.to_string(kind),
      "message" => opts[:message] || failure_message(kind, fields)
    }
  end

  defp classify(kind) when kind in @failure_kinds, do: {kind, []}

  defp classify(error) do
    case Ash.Error.to_error_class(error) do
      %{class: :forbidden} -> {:forbidden, []}
      %{class: :invalid} = class -> {:invalid, invalid_fields(class)}
      _other -> {:error, []}
    end
  rescue
    _ -> {:error, []}
  end

  defp invalid_fields(%{errors: errors}) when is_list(errors) do
    errors
    |> Enum.flat_map(fn error ->
      List.wrap(Map.get(error, :fields)) ++ List.wrap(Map.get(error, :field))
    end)
    |> Enum.filter(&(is_atom(&1) or is_binary(&1)))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp invalid_fields(_class), do: []

  defp failure_message(:forbidden, _fields), do: "You are not allowed to do this."
  defp failure_message(:invalid, []), do: "The input is invalid."
  defp failure_message(:invalid, fields), do: "Invalid input: #{Enum.join(fields, ", ")}."
  defp failure_message(:error, _fields), do: "The action could not be completed."

  @doc "The conventional `ash` extension method names (see the moduledoc)."
  @spec conventional_methods() :: [String.t()]
  def conventional_methods, do: ["_ash/surfaces/list", "_ash/surface/open", "_a2ui/action"]
end

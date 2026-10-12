# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.SessionStore do
  @moduledoc """
  Host-implemented seam for session persistence.

  The library never declares a session resource. The host backs this behaviour
  with its own Ash resource (or anything else) and owns retention, tenancy and
  auditing for sessions.

  A **session** is whatever the host returns from `create/1` and `load/1` —
  typically a resource record or a map. The server reads exactly three things
  from it, by key `:session_id`/`"session_id"`, `:actor`/`"actor"` and
  `:messages`/`"messages"`:

  * `session_id` — the ACP `sessionId` string handed back from `session/new`
    and used to route `session/load`, `session/prompt` and `session/cancel`.
  * `actor` — the Ash actor every prompt action is executed with
    (`authorize?: true`). This is the *only* source of authorization
    identity in the whole library; there is no second model. When an
    `AshAcp.Authenticator` is configured, `create/1` receives it under
    `"actor"` in `init` — record it: `session/load` rejects loads by a
    different authenticated actor with `-32002`.
  * `messages` — the transcript, a list of `%{role: :user | :agent, text: binary}`
    (extra keys allowed). Replayed as `session/update` chunks on
    `session/load` and appended through `append_message/3`.

  ## Listing (optional)

  Export `list/1` to support ACP `session/list` (advertised as
  `sessionCapabilities.list` only when exported). It receives
  `%{"cwd" => cwd | nil, "cursor" => cursor | nil, "actor" => actor | nil}`
  — `actor` is the connection's authenticated actor; list only what it may
  see — and returns `{:ok, sessions}` or `{:ok, sessions, next_cursor}`.
  Each session is read like any other (`session_id`, `actor`) plus the
  optional `cwd` (absolute path; `"/"` when absent), `title` and
  `updated_at` (`DateTime` or ISO8601 string). Sessions owned by another
  actor are dropped by the server as defense in depth.

  All callbacks run inside `AshAcp.Server.handle_message/2`, so they must not
  write to the wire themselves.
  """

  @callback create(init :: map()) ::
              {:ok, session :: term()} | {:error, term()}

  @callback load(session_id :: String.t()) ::
              {:ok, session :: term()} | {:error, term()}

  @callback append_message(session :: term(), role :: :user | :agent, message :: String.t()) ::
              {:ok, session :: term()} | {:error, term()}

  @callback close(session_id :: String.t()) :: :ok

  @callback list(filter :: map()) ::
              {:ok, [session :: term()]}
              | {:ok, [session :: term()], next_cursor :: String.t() | nil}
              | {:error, term()}

  @optional_callbacks list: 1
end

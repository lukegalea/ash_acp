<!-- SPDX-FileCopyrightText: 2026 Luke Galea -->

<!-- SPDX-License-Identifier: MIT -->

# Changelog

## 0.2.0 (2026-10-12)

* **Extension methods.** `AshAcp.ExtMethods` (optional, `config :ash_acp,
  ext_methods: ...`) routes `_`-prefixed JSON-RPC methods to the host with
  the session's actor. Consequential calls return `{:request_permission,
  spec}`: the host's `AshAcp.PermissionRequest` decides, a pending decision
  becomes `session/request_permission`, and the handler answers once the
  outcome is known. Advertised under `agentCapabilities._meta.ash`
  (mirrored at the initialize result's `_meta.ash`). The shared `ash`
  conventions (`_ash/surfaces/list`, `_ash/surface/open`, `_a2ui/action`)
  are specified in `priv/acp_schema/ash_ext.json` and conformance-tested.
* `available_commands_update` is sent right after `session/new` and after the
  `session/load` transcript replay, not only at turn end. On `session/load`
  it carries the session's last surface (`_meta.a2ui`); the provider is told
  why it is asked (`meta.reason`: `:session_new | :session_load | :turn_end`).
* `session/list` when the store exports the optional `list/1`, advertised as
  `sessionCapabilities.list`; foreign sessions are dropped.
* `AshAcp.Updates` — builders for `agent_message_chunk`,
  `agent_thought_chunk`, `user_message_chunk`, `plan`,
  `available_commands_update` and `session_info_update`.
* Fix: `AshAcp.config/0` carries `candidate_actions` (default `[]`),
  `ext_methods` and `authenticate`; previously the documented
  `candidate_actions` was silently dropped.
* Fix: the stdio log handler. `level` was passed inside `logger_std_h`'s own
  config, which rejects it — the default handler was removed and never
  re-added. It is now a handler key; `mix ash_acp.stdio` diverts logging
  before the host boots. `AshAcp.Endpoint.keep_stdout_pure/0` is public.
* Hardening: a prompt or extension call naming a session that is not cached
  on the connection is loaded and refused (`-32002`) when it belongs to
  another authenticated actor.
* **Breaking:** the deprecated `update.surface` alias is gone; read
  `update._meta.a2ui`.

## 0.1.2 (2026-10-06)

* Decimals serialize as exact strings (`Decimal.to_string/1`) — never as
  floats, which silently change money values (iron law #04). Money-shaped
  structs (ash_money) serialize as `{"amount": string, "currency": string}`.
* `session/load` is owner-checked: with `AshAcp.Authenticator` configured,
  a session whose stored actor differs from the authenticated actor is
  rejected with `-32002` ("Resource not found"). `session/new` passes the
  authenticated actor to the store under `"actor"` in `init`.

## 0.1.1 (2026-10-06)

Live-verification hardening.

* Read actions are dispatched as reads: `Ash.Query.for_read` + `Ash.read/2`
  with the session actor and `authorize?: true`; results stream as a
  `session/update` carrying the first 50 rows plus the total count.
  `tenant:` on the action spec passes through to Ash. `:create`/`:update`/
  `:destroy` answer with a `-32603` wire error instead of crashing.
* `handle_message/2` never raises: seam crashes become `-32603` plus a
  `Logger.error` with the stacktrace.
* Contract-violating `AshAcp.PermissionRequest.request/3` / `resolve/3`
  returns fail the affected prompt with `-32603` and log the misbehaving
  module (previously a bare `:approved` left the turn silently unresolved).
* `AshAcp.Authenticator` (optional): `authenticate/1` gates
  `initialize`/`session/new`/`session/load` and its actor becomes the
  session's actor; `{:error, _}` rejects with `-32000`.
* `AshAcp.Plug` requires `secret_key_base` and a signed
  `x-acp-connection` token (`Plug.Crypto.MessageVerifier`); invalid tokens
  get `401`.
* stdio: `run_stdio/1` diverts logger output and the group leader to
  stderr — stdout carries nothing but ndjson.
* A2UI payloads are carried under `update._meta.a2ui` (`update.surface`
  kept as a deprecated alias for one release).
* Golden fixtures validate against the vendored ACP v1 schema
  (`priv/acp_schema/`, ex_json_schema).

## 0.1.0 (2026-10-06)

Initial release.

* ACP v1 server wire adapter: `initialize`, `session/new`, `session/load`,
  `session/prompt`, `session/cancel`; streamed `session/update` and
  outbound `session/request_permission` (`AshAcp.acp_version/0` pins the
  protocol version).
* Pure protocol core (`AshAcp.Server.handle_message/2`), testable without IO.
* Transports: `AshAcp.Endpoint` (ndjson stdio) and `AshAcp.Plug` (ndjson
  HTTP for host Phoenix endpoints).
* Host seams: `AshAcp.SessionStore`, `AshAcp.PromptTarget`,
  `AshAcp.PermissionRequest` (ADR 0015), optional `AshAcp.SurfaceProvider`.
* Per-actor action-surface pruning with `Ash.can?/3`
  (`AshAcp.AvailableActions`).
* Golden wire fixtures under `priv/acp_fixtures/`.

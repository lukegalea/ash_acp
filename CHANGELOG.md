<!-- SPDX-FileCopyrightText: 2026 Luke Galea -->

<!-- SPDX-License-Identifier: MIT -->

# Changelog

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

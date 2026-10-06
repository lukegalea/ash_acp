<!-- SPDX-FileCopyrightText: 2026 Luke Galea -->

<!-- SPDX-License-Identifier: MIT -->

# Changelog

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

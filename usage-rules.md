<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Rules for working with AshAcp

AshAcp is the ACP server wire adapter for Ash. It owns framing, JSON-RPC
taxonomy, method dispatch and wire shapes. It owns nothing else.

**There is no second authorization model anywhere in this library.** If you
find yourself adding an allowlist, a role check, a permission cache, or an
option-id sniff that decides an authorization question — stop. The actor
comes from the session, actions run with `authorize?: true`, surfaces prune
with `Ash.can?/3`. That is the whole story. ADR 0015 approvals are *workflow*
data on the host's approval resource, never an authorization authority.

## Host integration steps

1. **Implement the four seams** (behaviours, host-side modules):
   * `AshAcp.SessionStore` — back it with your session resource. The session
     must carry `session_id`, `actor`, and `messages` (list of
     `%{role: :user | :agent, text: binary}`). The **actor is the only
     authorization identity** the wire ever sees.
   * `AshAcp.PromptTarget` — map prompt text to a declared action:
     `{:ok, %{resource:, action:, inputs:, title:, kind:}}`. This is the
     only place business routing logic belongs, and it belongs in the host.
   * `AshAcp.PermissionRequest` — `request/3` consults your approval
     resource (ADR 0015): `{:approved, record}`, `{:denied}`, or
     `{:pending, ref}` + optional `resolve/3` mapping the client's outcome
     back onto that resource.
   * `AshAcp.SurfaceProvider` (optional) — return your A2UI descriptor JSON;
     it is carried verbatim under `update.surface`. AshAcp never generates,
     validates or re-defines A2UI payloads.
2. **Configure** `:ash_acp` application env (`session_store`,
   `prompt_target`, `permission_request`, `surface_provider`, `agent_info`),
   and optionally `candidate_actions` — the list your clients see, pruned
   per actor by `Ash.can?/3`. Hide an action with a policy, not with this
   list.
3. **Pick a transport**: `AshAcp.run_stdio/0` / `mix ash_acp.stdio` for the
   ACP-native stdio loop, or mount `AshAcp.Plug` under your Phoenix
   endpoint. Neither contains business logic; do not add any there.
4. **On protocol bumps**: `AshAcp.acp_version/0` is the pin. Change it only
   with a schema revision, regenerate `priv/acp_fixtures/`
   (`REGEN_FIXTURES=1 mix test test/ash_acp/fixtures_test.exs`) and diff the
   golden files — they are the conformance record.

## Rules of thumb

* **Pure core, thin transports.** `AshAcp.Server.handle_message/2` does no
  IO — and never raises: any seam crash or contract violation becomes a
  `-32603` for the affected request plus a `Logger.error`. If a change needs
  the Endpoint or Plug to make a protocol decision, the decision belongs in
  the Server.
* **Seam returns are contracts.** `request/3` must return
  `{:approved, _} | {:denied} | {:pending, _}`; `resolve/3` must return
  `{:approved, _} | {:denied}`. Anything else fails the affected prompt with
  `-32603` and logs the misbehaving module — a bare `:approved` is the bug
  that hung a live client once; it will never pass silently again.
* **Wire shapes follow the schema.** Field names on the wire are the ACP
  schema's (`availableCommands`, `sessionId`, `stopReason`); Elixir-side
  names may read naturally (`available_actions`). Do not invent new
  `sessionUpdate` types — unknown ones degrade clients.
* **Ordering is part of the contract**: a turn's notifications precede the
  response that closes it; `handle_message` returns them in that order and
  transports write them in that order.
* **Cancellation is the server's decision.** The transport only arranges
  concurrency; the cancelled response, its request id, and the no-op case
  all come from `Server` state.

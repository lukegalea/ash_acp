<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# AshAcp

**The Agent Client Protocol, wired to Ash — transport and mapping, nothing else.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## What this is

[ACP](https://agentclientprotocol.com) is how operator consoles talk to agents:
JSON-RPC 2.0 over ndjson on stdio, with sessions, streamed updates, and
permission requests. `AshAcp` is the server side of that for an Ash
application — the role `ash_graphql` plays for GraphQL. It speaks the wire
protocol, maps each method onto a host-declared seam, and gets out of the way.

It ships **no Ash resources**, **no business logic**, and — the rule that
shapes everything else — **no second authorization model**:

> Every action executes through Ash with the session's actor and
> `authorize?: true`. There is no exposure list to keep in sync, no
> permission cache, no bypass. Approval unblocks the attempt; Ash policy
> still decides it. `AshAcp.AvailableActions` prunes the client's action
> surface with `Ash.can?/3` — the same authority, read side.

## The mapping (dogfood §7)

| ACP v1 | Ash |
|---|---|
| Session (`session/new`, `session/load`) | the host's session resource, via `AshAcp.SessionStore` |
| Prompt (`session/prompt`) | a declared Ash action, resolved by `AshAcp.PromptTarget`, executed with `Ash.run_action/2` (generic action) or `Ash.read/2` (read action), actor from the session, `authorize?: true`; create/update/destroy are answered `-32603` |
| Permission request (`session/request_permission`) | the host's approval resource (ADR 0015), via `AshAcp.PermissionRequest` |
| `session/update` — transcript chunks | the session resource's messages, replayed and appended through the store |
| `session/update` — `availableCommands` | `Ash.can?/3` pruned action surface (`AshAcp.AvailableActions`) — sent after `session/new`, after the `session/load` replay, and closing every turn |
| `session/update` — `_meta.a2ui` | opaque A2UI descriptors from `AshAcp.SurfaceProvider`, carried verbatim — never generated or re-defined here; re-emitted on `session/load` (the session's last surface) |
| `session/list` | `AshAcp.SessionStore.list/1` (optional), advertised as `sessionCapabilities.list` |
| `_`-prefixed extension methods | `AshAcp.ExtMethods` (optional), advertised under `agentCapabilities._meta.ash`; consequential calls go through `AshAcp.PermissionRequest` and `session/request_permission` |
| `session/update` — rows | read actions stream bounded rows (first 50) + total count as a `session/update`; `tenant:` on the action spec passes through to Ash |
| `session/update` — pending approvals | `tool_call` updates with `status: "pending"`, bound to the approval resource record |

The long-form mapping table lives in the host repo's documentation area
(`docs/dogfood_enterprise.md` §7, Productivity OS program).

## Host seams

Host-implemented behaviours; the library ships none of them:

| Behaviour | Callbacks | Purpose |
|---|---|---|
| `AshAcp.SessionStore` | `create/1, load/1, append_message/3, close/1` (+ optional `list/1`) | sessions backed by the host's own resource |
| `AshAcp.PromptTarget` | `resolve/3` | prompt text → Ash action + inputs |
| `AshAcp.PermissionRequest` | `request/3` (+ optional `resolve/3`) | approvals mapped onto the host approval resource |
| `AshAcp.Authenticator` (optional) | `authenticate/1` | `{:ok, actor}` on `initialize` / `session/new` / `session/load`; the actor becomes the session's actor; `{:error, _}` rejects with `-32000`. Unconfigured, the server must run behind a trusted boundary only |
| `AshAcp.SurfaceProvider` (optional) | `surface/2` | A2UI surface descriptors carried under `update._meta.a2ui`; `meta.reason` is `:session_new`, `:session_load` or `:turn_end` |
| `AshAcp.ExtMethods` (optional) | `methods/0, handle/3` (+ optional `capabilities/1`) | `_`-prefixed extension methods — see below |

Configure in application env:

```elixir
config :ash_acp,
  session_store: MyApp.AcpSessionStore,
  prompt_target: MyApp.AcpPromptTarget,
  permission_request: MyApp.AcpPermissionRequest,
  surface_provider: MyApp.AcpSurfaceProvider,
  ext_methods: MyApp.AcpExt,
  authenticate: MyApp.AcpAuth,          # optional AshAcp.Authenticator
  agent_info: %{name: "my_app", version: "1.0.0"},
  # a list, or {m, f, a} / a zero-arity fun evaluated per palette
  candidate_actions: [{MyApp.Helpdesk.Ticket, :summarize}]
```

**Policy refusals are never put to the client.** Before a consequential
action reaches `AshAcp.PermissionRequest`, the server checks it with
`Ash.can/3` (same actor, input and tenant as the run). A definite refusal
ends the turn `refusal` with a failed `Not permitted` tool call — no
approval is recorded and no `session/request_permission` goes out. When the
check cannot decide up front, the flow is unchanged, and the run itself is
always authorized with `authorize?: true`. A consequential extension call
gets the same check when its spec names the call it will make (`:resource`,
`:action`, `:inputs`, `:tenant`, and for an update or destroy the `:record`
it will change — without a record, an update or destroy goes to the
approval seam unchecked).

## Extension methods

ACP lets an agent expose custom methods whose names start with `_`. A host
implements `AshAcp.ExtMethods`; the library routes the listed methods to
`handle/3` with `%{session, session_id, actor, permission, denied_by}`, carries the
result verbatim, emits any returned `AshAcp.Updates` as `session/update`s,
and turns `{:request_permission, spec}` into the host's own
`AshAcp.PermissionRequest` decision — pending ones become a
`session/request_permission` round trip, after which `handle/3` is called
again with the outcome. Initialize advertises them:

```json
"agentCapabilities": {"_meta": {"ash": {"extMethods": ["_ash/surfaces/list", "_ash/surface/open", "_a2ui/action"], "surfaces": [...]}}}
```

(mirrored at the result's top-level `_meta.ash`). The shared `ash`
conventions — `_ash/surfaces/list`, `_ash/surface/open`, `_a2ui/action` —
are specified by `priv/acp_schema/ash_ext.json`, and the golden fixtures are
validated against it.

`_a2ui/action` answers one of three outcomes: `applied` (the write
succeeded — only then), `denied` (an approval was declined) or `failed`
(refused by policy, invalid input, or an error), which carries
`error: {kind: "forbidden" | "invalid" | "error", message}`. Build it with
`AshAcp.ExtMethods.action_failed/2`, which classifies an Ash error and
writes a message free of record contents, input values and stack traces.

## Transports

**stdio** — the ACP-native transport:

```elixir
AshAcp.run_stdio()          # library call, e.g. from a release
$ mix ash_acp.stdio         # or the mix task in dev
```

**HTTP** — for a host Phoenix endpoint, with no web-server dependency added
(uses the Plug the host already has):

```elixir
forward "/acp", to: AshAcp.Plug, init_opts: [secret_key_base: secret]
```

POST bodies carry ndjson JSON-RPC; responses and notifications come back as
ndjson lines. The `x-acp-connection` header must carry a token minted with
`AshAcp.Plug.connection_token/2` (signed with the secret); unsigned or
invalid tokens get `401`, and the token names the connection's state — see
`AshAcp.Plug` moduledoc.

## Protocol pin

`AshAcp.acp_version/0` is the pinned ACP protocol version (v1: integer
`protocolVersion` `1`). `initialize` echoes a matching client version or
answers with this pin, and the golden fixtures in `priv/acp_fixtures/` assert
the exact wire output of every flow, including error taxonomy (`-32700`,
`-32601`, `-32602`), and validate against the vendored ACP v1 schema
(`priv/acp_schema/`), so a protocol drift cannot merge silently.

Two robustness guarantees: `handle_message/2` never raises (a crash in any
seam becomes a `-32603` for the offending request plus a `Logger.error` with
the stacktrace), and contract-violating returns from
`AshAcp.PermissionRequest.request/3` / `resolve/3` fail the affected prompt
loudly instead of stranding the client. On stdio, `run_stdio/1` diverts
logger output to stderr (the group leader is left alone) — stdout carries
nothing but ndjson.

## What is deliberately not here

`terminal/*` and filesystem methods (deferred), streaming updates *during* a
long action (updates are emitted when a turn or extension call settles), A2UI generation (that is
`ash_a2ui`'s job — this library only carries the payloads), any host resource
or migration, and any authorization decision that Ash policies did not make.

## License

MIT — see [LICENSE](LICENSE).

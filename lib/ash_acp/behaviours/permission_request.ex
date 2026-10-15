# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.PermissionRequest do
  @moduledoc """
  Host-implemented seam for approvals (ADR 0015: approvals live in Ash).

  A prompt whose action needs approval — because the host says so — is
  surfaced to the ACP client as a `session/request_permission` request. The
  host maps that flow onto its own approval resource through this behaviour;
  the library holds no approval model of its own and derives no
  authorization decisions from option ids.

  An action Ash's policies refuse the actor never reaches this seam: the
  server checks it with `Ash.can/3` first (same actor, input and tenant as
  the run) and ends the turn refused, so nobody is asked to approve
  something that cannot run. Only a definite refusal short-circuits; when
  `Ash.can/3` cannot decide up front, `request/3` is called as usual. A run
  that Ash still refuses after approval ends the turn refused too — it is
  not put back to the client.

  ## Flow

  1. The server calls `request/3` before executing a resolved action that
     the up-front check did not refuse:
     * `{:approved, approval}` — already approved (e.g. `allow_always` was
       recorded on the host's approval resource). The library executes the
       action immediately; `approval` is opaque host metadata carried in the
       `tool_call` update's `rawInput`-adjacent `approval` field.
     * `{:denied}` — the host's approval resource already denied it. No
       execution; the turn ends `refusal` with a `failed` tool call update.
     * `{:pending, request_ref}` — an approval request was recorded. The
       library emits `session/request_permission` and waits for the client's
       outcome.
  2. When the client answers, the server calls `resolve/3` with the same
     `request_ref`. Implement it to consult the approval resource; the
     default implementation (used when the host does not export `resolve/3`)
     maps `allow_once`/`allow_always` to `{:approved, nil}` and
     `reject_once`/`reject_always`/cancelled to `{:denied}`.
  3. `{:approved, _}` executes the action — with the session actor and
     `authorize?: true`. Approval never bypasses Ash policies; it only
     unblocks the attempt.

  `resolve/3` is only ever called with a `request_ref` your `request/3`
  returned (since 0.3.0 the library no longer issues the synthetic
  `{:ash_denied, resource, action}` ref). Denying any ref you do not
  recognise remains the right catch-all.
  """

  @callback request(session :: term(), action_spec :: map(), inputs :: map()) ::
              {:approved, approval :: term()}
              | {:denied}
              | {:pending, request_ref :: term()}

  @optional_callbacks [resolve: 3]

  @callback resolve(request_ref :: term(), outcome :: map(), session :: term()) ::
              {:approved, approval :: term()} | {:denied}

  @doc """
  Default `resolve/3` for hosts that do not implement it: maps the ACP
  outcome's option id onto approved/denied.

  The client's outcome is `{"outcome" => "selected", "optionId" => id}` or
  `{"outcome" => "cancelled"}` (sent when the prompt turn was cancelled before
  the user responded).
  """
  @spec default_resolve(term(), map()) :: {:approved, nil} | {:denied}
  def default_resolve(_request_ref, %{"outcome" => "selected"} = outcome) do
    case outcome["optionId"] do
      id when id in ["allow_once", "allow_always"] -> {:approved, nil}
      _other -> {:denied}
    end
  end

  def default_resolve(_request_ref, _outcome), do: {:denied}
end

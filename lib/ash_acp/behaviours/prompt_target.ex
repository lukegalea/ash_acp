# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.PromptTarget do
  @moduledoc """
  Host-implemented seam that maps a prompt onto a declared Ash action.

  This is the whole of the "intelligence" seam: the library decides *how* to
  run an action (actor from the session, `authorize?: true`, streamed updates,
  permissions); the host decides *which* action a prompt means. Like the
  `AshAcp.SessionStore` seam, it exists so that no business logic ever lands in
  this library.

  ## Action specs

  `resolve/3` returns `{:ok, spec}` where `spec` is one of:

      # a declared generic action and its inputs:
      %{
        resource: MyApp.Helpdesk.Ticket,
        action: :summarize,
        inputs: %{text: "..."},
        title: "Summarize ticket",   # optional, becomes the tool_call title
        kind: :read                  # optional ACP tool kind; default :execute
      }

      # or a prebuilt input, when the host needs templates/load statements:
      %{action_input: input, title: "Summarize ticket"}

  The library executes the action with `Ash.run_action/2`, the session's actor
  and `authorize?: true`. Authorization failures are *not* errors: they are
  converted into `session/request_permission` (see `AshAcp.PermissionRequest`).

  Returning `{:error, term}` resolves to a prompt turn ending with
  `stopReason: "refusal"` — the host refused to map the prompt to any action.
  """

  @callback resolve(session_id :: String.t(), prompt_text :: String.t(), ctx :: map()) ::
              {:ok, action_spec :: map()} | {:error, term()}
end

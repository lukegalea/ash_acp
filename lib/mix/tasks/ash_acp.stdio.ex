# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAcp.Stdio do
  @shortdoc "Runs the ash_acp ACP server on stdio"
  @moduledoc """
  Boots `AshAcp.Endpoint` on stdio: reads ndjson JSON-RPC from stdin, writes
  responses and notifications to stdout, until EOF.

  Requires the host's `:ash_acp` application env to name the behaviour
  implementations (`session_store`, `prompt_target`,
  `permission_request`, optional `surface_provider`, `agent_info`).

      $ mix ash_acp.stdio

  For release usage without mix, call `AshAcp.run_stdio/0` from a host
  module instead.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    # Host application logs must never reach stdout — it is the ACP wire.
    # Divert them before the host boots, so boot-time logs land on stderr
    # too (run_stdio/1 re-asserts it, idempotently).
    AshAcp.Endpoint.keep_stdout_pure()

    # The whole host, deliberately (iron law #23's exception): every ACP
    # method runs the host's Ash actions, repos and policies.
    Mix.Task.run("app.start")

    AshAcp.run_stdio()
  end
end

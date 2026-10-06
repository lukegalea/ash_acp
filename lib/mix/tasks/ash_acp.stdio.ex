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
    Mix.Task.run("app.start")

    # Host application logs must never reach stdout — it is the ACP wire.
    # Silence at the task level; `AshAcp.Endpoint.run_stdio/1` additionally
    # diverts the default Logger handler to stderr. Do NOT remove the
    # handler: `:logger.remove_handler(:default)` makes logger_std_h close
    # the stdout io server, and every later write dies with :terminated.
    Logger.configure(level: :error)

    AshAcp.run_stdio()
  end
end

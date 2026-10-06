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
    # Replace the default handler with one writing to stderr at :error: a
    # chatty dev host (Ecto SQL debug, monitor heartbeats) is capped by the
    # handler level even when the primary level does not hold, and genuine
    # errors land on stderr. Two landmines, both bisected live:
    #   * `:logger.update_handler_config(:default, :set, ...)` silently
    #     no-ops under Elixir's Logger integration;
    #   * changing `type` on a started handler raises :illegal_config_change,
    #     so the handler must be removed and re-added. Removal is safe here —
    #     the stdout io server survives it (verified under a Port parent).
    :logger.remove_handler(:default)

    :logger.add_handler(:default, :logger_std_h, %{
      config: %{type: :standard_error, level: :error}
    })

    AshAcp.run_stdio()
  end
end

# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.Authenticator do
  @moduledoc """
  Optional host-implemented authentication seam.

  When configured (`config :ash_acp, authenticate: MyApp.AcpAuth`), the server
  invokes `authenticate/1` with the inbound params of `initialize`,
  `session/new` and `session/load`:

  * `{:ok, actor}` admits the message — and the actor **becomes the session's
    actor** for every action the connection runs (overriding whatever the
    `AshAcp.SessionStore` put on the session).
  * `{:error, term}` rejects the message with the ACP "Authentication
    required" error (`-32000`).

  When unconfigured the server performs no authentication and **must only run
  behind a trusted boundary** (a host process that has already authenticated
  the operator).
  """

  @callback authenticate(params :: map()) :: {:ok, actor :: term()} | {:error, term()}
end

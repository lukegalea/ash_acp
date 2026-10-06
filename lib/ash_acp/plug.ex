# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Plug.Conn) do
  defmodule AshAcp.Plug do
    @moduledoc """
    The HTTP transport: a minimal Plug that accepts POST bodies of ndjson
    JSON-RPC messages and returns the responses and notifications as ndjson
    lines in the response body.

    This exists so a host Phoenix endpoint can expose ACP over HTTP without
    this library growing a web-server dependency: the host already has Plug;
    this module only uses `Plug.Conn`. Mount it directly:

        forward "/acp", to: AshAcp.Plug

    or with overrides:

        forward "/acp", to: AshAcp.Plug, init_opts: [config: [...], store: MyApp.StateStore]

    ## State

    ACP is stateful per connection. HTTP is not. The Plug closes the gap with
    a small state registry keyed by the `x-acp-connection` request header (or
    `"default"` when absent), persisted in a public ETS table so subsequent
    POSTs on the same connection share the server's session cache, pending
    permission requests and id counters. Hosts that need their own story —
    e.g. a database or `:persistent_term` — pass `store: {module, fun, args}`
    returning `%{get: loader, put: storer}` closures, or run one Plug process
    per connection.

    Within one POST body, messages are processed strictly in order, so a
    whole `initialize` → `session/new` → `session/prompt` sequence can ride a
    single request. Prompts run synchronously here — a `session/cancel` in
    the same body after a prompt is a no-op, as the server's state machine
    dictates; cross-request cancellation needs the stdio transport or a
    stateful store the host provides.

    No business logic lives here either.
    """

    @behaviour Plug

    import Plug.Conn

    alias AshAcp.JsonRpc
    alias AshAcp.Server

    @connection_header "x-acp-connection"
    @content_type "application/x-ndjson"
    @default_connection "default"

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{method: method} = conn, opts) when method in ["POST"] do
      config = Keyword.get(opts, :config) || AshAcp.config()
      {get_state, put_state} = state_access(opts)
      key = connection_key(conn)

      state = get_state.(key) || Server.new(config)
      {:ok, body, conn} = read_body(conn)

      {wire, state} =
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map_reduce(state, fn
          "", st ->
            {[], st}

          trimmed, st ->
            {w, st2} = handle(trimmed, st, config)
            {w, st2}
        end)

      put_state.(key, state)

      conn
      |> put_resp_content_type(@content_type)
      |> send_resp(200, IO.iodata_to_binary(Enum.map(wire, &JsonRpc.encode_line/1)))
    end

    def call(conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(405, Jason.encode!(%{"error" => "ACP over HTTP is POST with an ndjson body"}))
    end

    defp handle(trimmed, state, _config) do
      Server.handle_line(trimmed, state)
    rescue
      e ->
        {[JsonRpc.error(nil, -32603, "internal error", %{"reason" => Exception.message(e)})],
         state}
    end

    defp connection_key(conn) do
      case get_req_header(conn, @connection_header) do
        [key | _] -> key
        [] -> @default_connection
      end
    end

    defp state_access(opts) do
      case Keyword.get(opts, :store) do
        nil -> {&plug_state_get/1, &plug_state_put/2}
        {get, put} when is_function(get, 1) and is_function(put, 2) -> {get, put}
      end
    end

    @table :ash_acp_plug_states

    defp plug_state_get(key) do
      ensure_table()

      case :ets.lookup(@table, key) do
        [{^key, state}] -> state
        [] -> nil
      end
    end

    defp plug_state_put(key, state) do
      ensure_table()
      :ets.insert(@table, {key, state})
    end

    defp ensure_table do
      if :ets.whereis(@table) == :undefined do
        try do
          :ets.new(@table, [:named_table, :public, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end
      end
    end
  end
end

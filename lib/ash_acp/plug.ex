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
    this module only uses `Plug.Conn`. Mount it with a signing secret:

        forward "/acp", to: AshAcp.Plug, init_opts: [secret_key_base: secret]

    ## Signed connections

    The header `x-acp-connection` must carry a token minted with
    `connection_token/2` (`Plug.Crypto.MessageVerifier` over the state key,
    signed with `secret_key_base`) — typically rendered into the operator
    console by the host. Unsigned, tampered or missing tokens get `401`; a
    valid token maps to the connection's ETS state, so the client can never
    address another connection's state by guessing a header. Hosts that need
    a different story pass `store: {get_fun, put_fun}`.

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

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{method: "POST"} = conn, opts) do
      secret = Keyword.get(opts, :secret_key_base)

      unless is_binary(secret) and byte_size(secret) > 0 do
        raise ArgumentError,
              "AshAcp.Plug requires a non-empty :secret_key_base option — " <>
                "connection tokens are signed with it (Plug.Crypto.MessageVerifier)"
      end

      case connection_key(conn, secret) do
        {:ok, key} ->
          serve(conn, opts, key)

        :error ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            401,
            Jason.encode!(%{"error" => "unauthorized: missing or invalid x-acp-connection token"})
          )
      end
    end

    def call(conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(405, Jason.encode!(%{"error" => "ACP over HTTP is POST with an ndjson body"}))
    end

    @doc """
    Mints the signed token a client presents in the `x-acp-connection` header.
    `key` is an opaque connection key of the host's choosing (e.g. a random
    string per operator session); it names the server-state entry.
    """
    @spec connection_token(String.t(), String.t()) :: String.t()
    def connection_token(key, secret_key_base)
        when is_binary(key) and is_binary(secret_key_base) do
      Plug.Crypto.MessageVerifier.sign(key, secret_key_base)
    end

    defp serve(conn, opts, key) do
      config = Keyword.get(opts, :config) || AshAcp.config()
      {get_state, put_state} = state_access(opts)

      state = get_state.(key) || Server.new(config)
      {:ok, body, conn} = read_body(conn)

      {wire, state} =
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map_reduce(state, fn
          "", st ->
            {[], st}

          trimmed, st ->
            {w, st2} = handle(trimmed, st)
            {w, st2}
        end)

      put_state.(key, state)

      conn
      |> put_resp_content_type(@content_type)
      |> send_resp(200, IO.iodata_to_binary(Enum.map(wire, &JsonRpc.encode_line/1)))
    end

    defp connection_key(conn, secret) do
      case get_req_header(conn, @connection_header) do
        [token | _] -> Plug.Crypto.MessageVerifier.verify(token, secret)
        [] -> :error
      end
    end

    defp handle(trimmed, state) do
      Server.handle_line(trimmed, state)
    rescue
      e ->
        {[JsonRpc.error(nil, -32603, "internal error", %{"reason" => Exception.message(e)})],
         state}
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

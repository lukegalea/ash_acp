# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.PlugTest do
  @moduledoc """
  HTTP transport: ndjson POST body in, ndjson response body out, with
  signed connection tokens mapping to per-connection state.
  """
  use ExUnit.Case, async: false

  @secret "test-secret-key-base-0123456789"

  setup do
    FakeHost.start()

    case :ets.whereis(:ash_acp_plug_states) do
      :undefined -> :ok
      _tid -> :ets.delete_all_objects(:ash_acp_plug_states)
    end

    :ok
  end

  @version AshAcp.acp_version()

  defp token(key), do: AshAcp.Plug.connection_token(key, @secret)

  defp post(body, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    secret = Keyword.get(opts, :secret, @secret)

    conn =
      Plug.Test.conn(:post, "/acp", body)
      |> Plug.Conn.put_req_header("content-type", "application/x-ndjson")
      |> then(fn conn ->
        Enum.reduce(headers, conn, fn {k, v}, acc ->
          Plug.Conn.put_req_header(acc, k |> to_string() |> String.replace("_", "-"), v)
        end)
      end)

    AshAcp.Plug.call(conn, config: FakeHost.config(), secret_key_base: secret)
  end

  defp decode_lines(body) do
    body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  test "a whole lifecycle rides one POST body" do
    body =
      Enum.join(
        [
          ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":#{@version}}}),
          ~s({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}),
          ~s({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"sess-1","prompt":[{"type":"text","text":"hello"}]}})
        ],
        "\n"
      )

    conn = post(body, headers: [x_acp_connection: token("conn-a")])

    assert conn.status == 200

    assert Plug.Conn.get_resp_header(conn, "content-type")
           |> hd()
           |> String.starts_with?("application/x-ndjson")

    lines = decode_lines(conn.resp_body)

    assert [%{"id" => 1}, %{"id" => 2, "result" => %{"sessionId" => "sess-1"}} | rest] = lines
    assert %{"id" => 3, "result" => %{"stopReason" => "end_turn"}} = List.last(rest)
    # a turn's updates precede its response
    assert length(rest) == 5
  end

  test "state persists across POSTs under the same signed token" do
    conn =
      post(
        ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":#{@version}}}),
        headers: [x_acp_connection: token("conn-1")]
      )

    assert conn.status == 200

    conn =
      post(~s({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}),
        headers: [x_acp_connection: token("conn-1")]
      )

    assert conn.status == 200

    conn =
      post(
        ~s({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"sess-1","prompt":[{"type":"text","text":"hi"}]}}),
        headers: [x_acp_connection: token("conn-1")]
      )

    assert [%{"id" => 3, "result" => %{"stopReason" => "end_turn"}}] =
             conn.resp_body |> decode_lines() |> Enum.filter(&(&1["id"] == 3))
  end

  test "different tokens map to different connection state" do
    post(
      ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":#{@version}}}),
      headers: [x_acp_connection: token("conn-1")]
    )

    # a fresh token has fresh state: its session/new creates sess-1 again,
    # untouched by conn-1's counter
    conn =
      post(~s({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}),
        headers: [x_acp_connection: token("conn-2")]
      )

    assert %{"result" => %{"sessionId" => "sess-1"}} = hd(decode_lines(conn.resp_body))
  end

  test "a missing token gets 401" do
    conn =
      post(
        ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":#{@version}}})
      )

    assert conn.status == 401
    assert %{"error" => "unauthorized" <> _rest} = Jason.decode!(conn.resp_body)
  end

  test "an unsigned or invalid token gets 401" do
    for bad <- ["conn-1", "garbage", token("conn-1") <> "x"] do
      conn =
        post(
          ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":#{@version}}}),
          headers: [x_acp_connection: bad]
        )

      assert conn.status == 401, "expected 401 for token #{inspect(bad)}"
    end
  end

  test "a token signed with a different secret is rejected" do
    conn =
      post(
        ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":#{@version}}}),
        headers: [x_acp_connection: token("conn-1")],
        secret: "a-completely-different-secret"
      )

    assert conn.status == 401
  end

  test "parse errors come back as -32700 ndjson with 200 status" do
    conn = post("{nope", headers: [x_acp_connection: token("conn-3")])
    assert conn.status == 200
    assert [%{"error" => %{"code" => -32700}}] = decode_lines(conn.resp_body)
  end

  test "non-POST is 405" do
    conn =
      AshAcp.Plug.call(Plug.Test.conn(:get, "/acp"),
        config: FakeHost.config(),
        secret_key_base: @secret
      )

    assert conn.status == 405
  end

  test "a missing secret_key_base option is a configuration error" do
    assert_raise ArgumentError, ~r/secret_key_base/, fn ->
      AshAcp.Plug.call(
        Plug.Test.conn(:post, "/acp", "{}"),
        config: FakeHost.config()
      )
    end
  end
end

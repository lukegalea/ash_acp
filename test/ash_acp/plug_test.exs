# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.PlugTest do
  @moduledoc """
  HTTP transport: ndjson POST body in, ndjson response body out, with
  connection-keyed state so multi-request ACP flows work.
  """
  use ExUnit.Case, async: false

  if Code.ensure_loaded?(Plug.Test) do
    setup do
      FakeHost.start()

      case :ets.whereis(:ash_acp_plug_states) do
        :undefined -> :ok
        _tid -> :ets.delete_all_objects(:ash_acp_plug_states)
      end

      :ok
    end

    @version AshAcp.acp_version()

    defp post(body, headers \\ []) do
      conn =
        Plug.Test.conn(:post, "/acp", body)
        |> Plug.Conn.put_req_header("content-type", "application/x-ndjson")
        |> then(fn conn ->
          Enum.reduce(headers, conn, fn {k, v}, acc ->
            Plug.Conn.put_req_header(acc, k |> to_string() |> String.replace("_", "-"), v)
          end)
        end)

      AshAcp.Plug.call(conn, config: FakeHost.config())
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

      conn = post(body)

      assert conn.status == 200

      assert Plug.Conn.get_resp_header(conn, "content-type")
             |> hd()
             |> String.starts_with?("application/x-ndjson")

      lines =
        conn.resp_body
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert [%{"id" => 1}, %{"id" => 2, "result" => %{"sessionId" => "sess-1"}} | rest] = lines
      assert %{"id" => 3, "result" => %{"stopReason" => "end_turn"}} = List.last(rest)
      # a turn's updates precede its response
      assert length(rest) == 5
    end

    test "state persists across POSTs under the connection header" do
      conn =
        post(
          ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":#{@version}}}),
          x_acp_connection: "c1"
        )

      assert conn.status == 200

      conn =
        post(~s({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}),
          x_acp_connection: "c1"
        )

      assert conn.status == 200

      # a prompt on the same connection id finds the session cache
      conn =
        post(
          ~s({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"sess-1","prompt":[{"type":"text","text":"hi"}]}}),
          x_acp_connection: "c1"
        )

      body_lines = String.split(conn.resp_body, "\n", trim: true)

      assert [%{"id" => 3, "result" => %{"stopReason" => "end_turn"}}] =
               body_lines |> Enum.map(&Jason.decode!/1) |> Enum.filter(&(&1["id"] == 3))
    end

    test "parse errors come back as -32700 ndjson with 200 status" do
      conn = post("{nope")
      assert conn.status == 200
      assert [%{"error" => %{"code" => -32700}}] = decode_lines(conn.resp_body)
    end

    test "non-POST is 405" do
      conn = AshAcp.Plug.call(Plug.Test.conn(:get, "/acp"), config: FakeHost.config())
      assert conn.status == 405
    end

    defp decode_lines(body) do
      body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    end
  end
end

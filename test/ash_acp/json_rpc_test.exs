# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.JsonRpcTest do
  use ExUnit.Case, async: true

  import AshAcp.JsonRpc

  describe "classify/1" do
    test "requests" do
      assert {:request, 5, "session/new", %{"cwd" => "/"}} =
               classify(%{
                 "jsonrpc" => "2.0",
                 "id" => 5,
                 "method" => "session/new",
                 "params" => %{"cwd" => "/"}
               })
    end

    test "notifications" do
      assert {:notification, "session/cancel", %{"sessionId" => "s"}} =
               classify(%{
                 "jsonrpc" => "2.0",
                 "method" => "session/cancel",
                 "params" => %{"sessionId" => "s"}
               })
    end

    test "client responses to our requests" do
      assert {:response, "srv-1", %{"outcome" => "selected"}} =
               classify(%{
                 "jsonrpc" => "2.0",
                 "id" => "srv-1",
                 "result" => %{"outcome" => "selected"}
               })

      assert {:response_error, 7, %{"code" => -32602}} =
               classify(%{
                 "jsonrpc" => "2.0",
                 "id" => 7,
                 "error" => %{"code" => -32602, "message" => "no"}
               })
    end

    test "wrong jsonrpc version is an invalid request, id echoed when detectable" do
      assert {:error, -32600, _msg, 1} =
               classify(%{"jsonrpc" => "1.0", "id" => 1, "method" => "x"})
    end

    test "non-object payloads (e.g. JSON-RPC batches) are invalid requests" do
      assert {:error, -32600, _msg, nil} = classify([%{"jsonrpc" => "2.0"}])
    end

    test "missing method is an invalid request" do
      assert {:error, -32600, _msg, 3} = classify(%{"jsonrpc" => "2.0", "id" => 3})
    end
  end

  describe "decode/1" do
    test "decodes a line" do
      assert {:ok, %{"method" => "initialize"}} =
               decode(~s({"jsonrpc":"2.0","id":1,"method":"initialize"}))
    end

    test "rejects invalid JSON as a parse error" do
      assert {:error, :parse} = decode("{nope")
    end
  end

  test "std_error uses canonical messages" do
    assert %{"error" => %{"code" => -32601, "message" => "Method not found"}} =
             std_error(9, -32601)
  end

  test "encode_line appends exactly one newline" do
    line = encode_line(response(1, %{}))

    assert String.ends_with?(line, "\n")

    assert String.trim_trailing(line) |> Jason.decode!() == %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{}
           }

    refute String.contains?(String.trim_trailing(line), "\n")
  end
end

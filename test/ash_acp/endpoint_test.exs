# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.EndpointTest do
  @moduledoc """
  Framing and transport: ndjson in/out over an IO device, parse/method/param
  errors, and cancel-during-prompt in both race orders.
  """
  use ExUnit.Case, async: false

  @version AshAcp.acp_version()

  setup do
    FakeHost.start()
    :ok
  end

  def run(input_lines, config_overrides \\ []) do
    input = Enum.map_join(input_lines, &(&1 <> "\n"))
    {:ok, device} = StringIO.open(input)

    task =
      Task.async(fn ->
        AshAcp.Endpoint.run_stdio(device: device, config: FakeHost.config(config_overrides))
      end)

    assert :ok = Task.await(task, 10_000)

    output = StringIO.flush(device)
    StringIO.close(device)

    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp initialize do
    ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":#{@version}}})
  end

  defp session_new do
    ~s({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}})
  end

  defp prompt(id \\ 3, text \\ "hello") do
    ~s({"jsonrpc":"2.0","id":#{id},"method":"session/prompt","params":{"sessionId":"sess-1","prompt":[{"type":"text","text":"#{text}"}]}})
  end

  defp cancel do
    ~s({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"sess-1"}})
  end

  # == framing ===============================================================

  test "a full round trip: initialize, session/new, session/prompt over ndjson" do
    wire = run([initialize(), session_new(), prompt()])

    assert [%{"id" => 1}, %{"id" => 2}, _tool_call, _chunk, _final, _completed, %{"id" => 3}] =
             wire

    assert %{"result" => %{"protocolVersion" => reported}} = Enum.fetch!(wire, 0)
    assert reported == @version
    assert %{"result" => %{"sessionId" => "sess-1"}} = Enum.fetch!(wire, 1)
    assert %{"result" => %{"stopReason" => "end_turn"}} = List.last(wire)
  end

  test "invalid JSON line answers -32700 with id null and keeps the connection alive" do
    wire = run(["{nope", initialize()])

    assert hd(wire) == %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{"code" => -32700, "message" => "Parse error"}
           }

    assert %{"id" => 1, "result" => %{"protocolVersion" => reported}} = List.last(wire)
    assert reported == @version
  end

  test "unknown method answers -32601" do
    wire = run([~s({"jsonrpc":"2.0","id":5,"method":"no/such","params":{}})])
    assert hd(wire)["error"]["code"] == -32601
  end

  test "bad params answer -32602" do
    wire = run([~s({"jsonrpc":"2.0","id":6,"method":"session/prompt","params":{"prompt":"no"}})])
    assert hd(wire)["error"]["code"] == -32602
  end

  test "notifications never produce wire output" do
    wire = run([initialize(), session_new(), ~s({"jsonrpc":"2.0","method":"x/y"})])
    # only the two request responses came back
    assert length(wire) == 2
  end

  test "blank lines are skipped" do
    wire = run(["", initialize(), "   "])
    assert length(wire) == 1
  end

  # == cancellation ==========================================================

  test "cancel mid-turn answers the prompt with stopReason cancelled and kills the turn" do
    wire =
      run([initialize(), session_new(), prompt(3, "hello"), cancel()],
        prompt_target: FakeHost.BlockingPromptTarget
      )

    responses = Enum.filter(wire, &(Map.has_key?(&1, "id") and Map.has_key?(&1, "result")))

    assert [%{"id" => 1}, %{"id" => 2}, %{"id" => 3, "result" => %{"stopReason" => "cancelled"}}] =
             responses

    refute Enum.any?(wire, &(&1["params"]["update"]["sessionUpdate"] == "agent_message_chunk"))
  end

  test "cancel for an idle session is a silent no-op on the wire" do
    # the pure-server no-op case, exercised through the transport: nothing
    # in flight, so the notification produces no output at all
    wire = run([initialize(), session_new(), cancel()])

    assert [%{"id" => 1}, %{"id" => 2}] = wire
  end

  test "a second prompt sent mid-turn replays after the first, in order" do
    wire = run([initialize(), session_new(), prompt(3, "hello"), prompt(4, "again")])

    ids = Enum.map(wire, & &1["id"])
    assert ids == [1, 2, nil, nil, nil, nil, 3, nil, nil, nil, nil, 4]
    assert %{"result" => %{"stopReason" => "end_turn"}} = List.last(wire)
  end
end

defmodule FakeHost.BlockingPromptTarget do
  @moduledoc false
  @behaviour AshAcp.PromptTarget

  @impl true
  def resolve(_session_id, prompt_text, _ctx) do
    # Hold the turn open until the transport kills the task (a live cancel),
    # with a bounded lifetime so a test bug cannot leak a sleeper forever.
    blocked_loop(200)

    {:ok,
     %{
       resource: FakeHost.Note,
       action: :summarize,
       inputs: %{text: prompt_text},
       title: "Blocked summarize",
       kind: :read
     }}
  end

  defp blocked_loop(0), do: :gave_up

  defp blocked_loop(n) do
    Process.sleep(10)
    blocked_loop(n - 1)
  end
end

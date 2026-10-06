# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.StdioSubprocessTest do
  @moduledoc """
  The regression test for the stdio-purity class of bug: `mix ash_acp.stdio`
  is spawned as a REAL subprocess with a stdin/stdout pipe, an `initialize`
  request is written to its stdin, and a `protocolVersion` response must come
  back on stdout. The in-process StringIO tests cannot catch group-leader or
  logger-routing mistakes — a diverted group leader makes `IO.read` see EOF
  instantly and the writer die with :epipe, and nothing in-process notices.
  """
  use ExUnit.Case, async: false

  @moduletag :subprocess

  @tag timeout: 120_000
  test "mix ash_acp.stdio answers initialize over a real pipe" do
    mix = System.find_executable("mix")
    assert mix, "mix must be on PATH for the subprocess regression test"

    port =
      Port.open(
        {:spawn_executable, mix},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          {:line, 4096},
          {:args, ["ash_acp.stdio"]},
          {:cd, File.cwd!()}
        ]
      )

    request =
      ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":#{AshAcp.acp_version()}}})

    Port.command(port, request <> "\n")

    line = await_matching_line(port, &(&1 =~ "protocolVersion"), 90_000)
    refute is_nil(line), "no protocolVersion response arrived on stdout"

    message = Jason.decode!(line)
    assert message["id"] == 1
    assert message["result"]["protocolVersion"] == AshAcp.acp_version()
    assert message["result"]["agentInfo"]

    Port.close(port)
  end

  # Collect stdout lines until one matches, distinguishing them from boot
  # noise (compile output etc.) that must never be mistaken for the wire.
  defp await_matching_line(port, predicate, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(port, predicate, deadline, [])
  end

  defp do_wait(port, predicate, deadline, buffer) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      fail("timed out waiting for a matching stdout line; got: #{inspect(Enum.reverse(buffer))}")
    end

    receive do
      {^port, {:data, {:eol, line}}} ->
        if predicate.(line) do
          line
        else
          do_wait(port, predicate, deadline, [line | buffer])
        end

      {^port, {:data, {:noeol, partial}}} ->
        # a line longer than the 4096 window; keep it with the next chunk
        do_wait(port, predicate, deadline, [partial | buffer])

      {^port, {:exit_status, status}} ->
        fail(
          "mix ash_acp.stdio exited with status #{status}; got: #{inspect(Enum.reverse(buffer))}"
        )
    after
      100 -> do_wait(port, predicate, deadline, buffer)
    end
  end

  defp fail(message) do
    ExUnit.Assertions.flunk(message)
  end
end

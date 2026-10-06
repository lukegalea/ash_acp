# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.StdioSubprocessTest do
  @moduledoc """
  The regression tests for the stdio-purity class of bug: the server runs as
  a REAL subprocess with a stdin/stdout pipe, and stdout must carry nothing
  but ndjson JSON-RPC.

  * `mix ash_acp.stdio` answers `initialize` over the pipe (the group-leader
    diversion bug made `IO.read` see EOF instantly and writes die with
    `:epipe` — invisible to in-process StringIO tests).
  * Under a chatty dev host (Logger at :debug, Ecto-style SQL and monitor
    noise ticking while the loop runs), stdout still parses as JSON lines
    only — the handler-level cap must hold even when the primary level does
    not.
  """
  use ExUnit.Case, async: false

  @moduletag :subprocess

  @tag timeout: 120_000
  test "mix ash_acp.stdio answers initialize over a real pipe" do
    mix = System.find_executable("mix")
    assert mix, "mix must be on PATH for the subprocess regression test"

    port = spawn_stdio_task()

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

  @tag timeout: 120_000
  test "stdout stays ndjson-only under a chatty dev host" do
    mix = System.find_executable("mix")
    assert mix, "mix must be on PATH for the subprocess regression tests"

    # Simulate the host that exposed the leak: Logger runs at :debug (dev),
    # "app start"-style code emits Ecto SQL debug and monitor noise from a
    # ticker WHILE the endpoint loop runs, and nothing caps the level before
    # the endpoint does. Every stdout byte must still parse as ndjson.
    chatty_code = """
    require Logger
    Logger.configure(level: :debug)

    spawn(fn ->
      for i <- 1..60 do
        Logger.debug("INSERT INTO \\"ash_projection_registry\\" (source, external_id) VALUES ($1, $2)")
        Logger.debug("[Projections.LeaderMonitor] leader elected, tick")
        Logger.info("[Projections.LeaderMonitor] heartbeat")

        # genuine :error-level logs must land on stderr, never stdout
        if i == 1, do: :logger.error("[Projections.LeaderMonitor] genuine error")

        Process.sleep(50)
      end
    end)

    AshAcp.run_stdio()
    """

    port = spawn_via(mix, ["run", "-e", chatty_code])

    request =
      ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":#{AshAcp.acp_version()}}})

    Port.command(port, request <> "\n")

    line = await_matching_line(port, &(&1 =~ "protocolVersion"), 90_000)
    message = Jason.decode!(line)
    assert message["id"] == 1
    assert message["result"]["protocolVersion"] == AshAcp.acp_version()

    # keep listening past the response: while the ticker is still firing,
    # nothing non-JSON may reach stdout
    trailing = drain_lines(port, 1_500)
    Port.close(port)

    problems = Enum.filter([line | trailing], &(!json_line?(&1)))

    assert problems == [], "stdout carried non-ndjson lines:\n#{Enum.join(problems, "\n")}"
  end

  # == plumbing ==============================================================

  defp spawn_stdio_task do
    mix = System.find_executable("mix")
    spawn_via(mix, ["ash_acp.stdio"])
  end

  defp spawn_via(executable, args) do
    Port.open(
      {:spawn_executable, executable},
      [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        {:line, 4096},
        {:args, args},
        {:cd, File.cwd!()}
      ]
    )
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
        fail("child exited with status #{status}; got: #{inspect(Enum.reverse(buffer))}")
    after
      100 -> do_wait(port, predicate, deadline, buffer)
    end
  end

  defp drain_lines(port, quiet_ms) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        [line | drain_lines(port, quiet_ms)]

      {^port, {:data, {:noeol, partial}}} ->
        [partial | drain_lines(port, quiet_ms)]
    after
      quiet_ms -> []
    end
  end

  defp json_line?(line) do
    case Jason.decode(line) do
      {:ok, %{"jsonrpc" => "2.0"}} -> true
      _ -> false
    end
  end

  defp fail(message) do
    ExUnit.Assertions.flunk(message)
  end
end

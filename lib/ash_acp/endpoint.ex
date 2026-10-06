# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.Endpoint do
  @moduledoc """
  The stdio transport: ndjson JSON-RPC in, ndjson JSON-RPC out.

  One message per line, until EOF. Every response and notification
  `AshAcp.Server.handle_message/2` produces is written back as its own line,
  in the order the server returned them — a turn's notifications always
  precede the response that closes it.

  No business logic lives here. The module has exactly three jobs:

  1. read lines from the device (`:standard_io` by default),
  2. hand each to the pure server,
  3. write what comes back.

  **stdout carries nothing but ndjson.** `run_stdio/1` diverts the default
  logger handler and its process tree's group leader to stderr before the
  loop starts, so host logging (including the loud seam-failure and crash
  logs from `AshAcp.Server`) can never interleave with the wire stream.

  ## Cancellation

  `session/prompt` runs in an unlinked, monitored process so the connection
  stays live for `session/cancel` while the host action executes. The
  prompt's request id is seeded into the transport state's `in_flight` map,
  so the pure server itself decides what a mid-turn cancel means: a response
  of `stopReason: "cancelled"` addressed to the prompt's request id. The
  transport then kills the turn process. A cancel that loses the race to a
  finished turn replays as a normal line — a no-op, exactly as the server's
  own state machine dictates. Any other message that arrives mid-turn
  replays through the server, in order, once the turn settles. If the reader
  hits EOF while a turn runs, nothing can follow it: the loop ends once the
  turn settles.
  """

  alias AshAcp.JsonRpc
  alias AshAcp.Server

  defstruct [:tag, :pid, :monitor]

  @type turn :: %__MODULE__{tag: reference(), pid: pid(), monitor: reference()}

  @doc """
  Runs the endpoint loop on the given device (default `:standard_io`) until
  EOF. Accepts `:device` and `:config` options; config defaults to
  `AshAcp.config/0`.
  """
  @spec run_stdio(keyword()) :: :ok
  def run_stdio(opts \\ []) do
    keep_stdout_pure()

    device = Keyword.get(opts, :device, :standard_io)
    config = Keyword.get(opts, :config) || AshAcp.config()
    parent = self()

    reader =
      spawn(fn ->
        read_lines(device, parent)
      end)

    loop(Server.new(config), reader, device)
  end

  # stdout is the ACP wire. Logger's default handler writes to stdout, and
  # seam callbacks (host code) may log or write to the group leader — both
  # would corrupt the ndjson stream mid-message. Divert the default logger
  # handler and this process tree's group leader to stderr, so stdout carries
  # nothing but ndjson.
  defp keep_stdout_pure do
    try do
      :logger.update_handler_config(:default, :set, %{config: %{type: :standard_error}})
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    case Process.whereis(:standard_error) do
      pid when is_pid(pid) -> Process.group_leader(self(), pid)
      _ -> :ok
    end

    :ok
  end

  defp read_lines(device, parent) do
    case IO.read(device, :line) do
      :eof ->
        send(parent, {:reader, self(), :eof})

      {:error, _reason} ->
        send(parent, {:reader, self(), :eof})

      line ->
        send(parent, {:reader, self(), {:line, line}})
        read_lines(device, parent)
    end
  end

  defp loop(state, reader, device) do
    receive do
      {:reader, ^reader, {:line, line}} ->
        case String.trim_trailing(line) do
          "" ->
            loop(state, reader, device)

          trimmed ->
            case dispatch(trimmed, state, reader, device) do
              {:continue, state} ->
                loop(state, reader, device)

              # the reader hit EOF while the turn ran: nothing can follow it
              :reader_done ->
                :ok
            end
        end

      {:reader, ^reader, _eof_or_error} ->
        :ok
    end
  end

  # == one line ==============================================================

  # `session/prompt` is the only line that needs concurrency: it runs in a
  # separate process while the loop keeps reading, so `session/cancel` can
  # land mid-turn.
  defp dispatch(trimmed, state, reader, device) do
    case JsonRpc.decode(trimmed) do
      {:error, :parse} ->
        write(device, [JsonRpc.std_error(nil, -32700)])
        {:continue, state}

      {:ok, %{"method" => "session/prompt"} = message} ->
        run_turn(message, state, reader, device)

      {:ok, message} ->
        {response, notifications, new_state} = handle_message(message, state)
        write(device, List.wrap(notifications) ++ List.wrap(response))
        {:continue, new_state}
    end
  end

  defp handle_message(message, state) do
    Server.handle_message(message, state)
  rescue
    e ->
      {JsonRpc.error(message["id"], -32603, "internal error", %{"reason" => Exception.message(e)}),
       [], state}
  end

  defp handle_line(trimmed, state) do
    Server.handle_line(trimmed, state)
  rescue
    e ->
      {[JsonRpc.error(nil, -32603, "internal error", %{"reason" => Exception.message(e)})], state}
  end

  # == the prompt turn =======================================================

  defp run_turn(message, state, reader, device) do
    request_id = message["id"]
    session_id = get_in(message, ["params", "sessionId"])

    # The turn process runs from the *unseeded* state — `session/prompt`
    # seeding and clearing of in_flight is the server's own business. The
    # transport's state carries the seed, so a mid-turn cancel is decided by
    # the pure server (which answers the prompt's request id), not here.
    transport_state =
      if is_binary(session_id) do
        put_in(state, [Access.key!(:in_flight), session_id], request_id)
      else
        state
      end

    turn = spawn_turn(message, state)

    {wire, state, queued, reader_done?} =
      await_turn(turn, request_id, session_id, reader, transport_state, queued: [])

    write(device, wire)

    # Anything that arrived mid-turn replays now, in order.
    {queued_wire, state} =
      Enum.reduce(queued, {[], state}, fn trimmed, {acc, st} ->
        {w, st2} = handle_line(trimmed, st)
        {acc ++ w, st2}
      end)

    write(device, queued_wire)

    if reader_done? do
      :reader_done
    else
      {:continue, state}
    end
  end

  defp spawn_turn(message, state) do
    parent = self()
    tag = make_ref()

    pid =
      spawn(fn ->
        send(parent, {tag, Server.handle_message(message, state)})
      end)

    %__MODULE__{tag: tag, pid: pid, monitor: Process.monitor(pid)}
  end

  # Receive loop for one prompt turn: the turn result, the reader's next
  # line, or EOF — whichever comes first.
  defp await_turn(%__MODULE__{} = turn, request_id, session_id, reader, state, opts) do
    %__MODULE__{tag: tag, monitor: monitor} = turn
    queued = Keyword.fetch!(opts, :queued)
    reader_done? = Keyword.get(opts, :reader_done?, false)

    receive do
      {^tag, triple} ->
        Process.demonitor(monitor, [:flush])
        {turn_wire(triple), state_of(triple), queued, reader_done?}

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        crash =
          JsonRpc.error(request_id, -32603, "internal error", %{
            "reason" => "prompt process crashed"
          })

        {[crash], state, queued, reader_done?}

      {:reader, ^reader, {:line, line}} ->
        trimmed = String.trim_trailing(line)

        cond do
          String.trim_leading(trimmed) == "" ->
            await_turn(turn, request_id, session_id, reader, state, opts)

          cancel_for_turn?(trimmed, session_id) ->
            handle_cancel(turn, state, queued, trimmed)

          true ->
            await_turn(turn, request_id, session_id, reader, state,
              queued: queued ++ [trimmed],
              reader_done?: reader_done?
            )
        end

      {:reader, ^reader, :eof} ->
        finish_at_eof(turn, request_id, queued)
    end
  end

  # The reader hit EOF mid-turn. A live cancel can no longer arrive (a
  # cancel after EOF is impossible), so wait for the turn result; a result
  # that completed before EOF is already in the mailbox.
  defp finish_at_eof(turn, request_id, queued) do
    case await_turn_result(turn) do
      {:ok, triple} ->
        {turn_wire(triple), state_of(triple), queued, true}

      :crashed ->
        crash =
          JsonRpc.error(request_id, -32603, "internal error", %{
            "reason" => "prompt process crashed"
          })

        {[crash], nil, queued, true}
    end
  end

  defp handle_cancel(%__MODULE__{} = turn, state, queued, trimmed) do
    case pop_turn_result(turn) do
      {:done, triple} ->
        # The turn finished first: the cancel replays as a normal line after
        # the turn (where the server treats it as the no-op it now is).
        {turn_wire(triple), state_of(triple), queued ++ [trimmed], false}

      :none ->
        # Live cancel: the server answers the prompt's request id and clears
        # in_flight; the still-running turn process is killed.
        {wire, state} = handle_line(trimmed, state)
        Process.exit(turn.pid, :kill)
        Process.demonitor(turn.monitor, [:flush])
        {wire, state, queued, false}
    end
  end

  # Non-blocking check for the turn's result.
  defp pop_turn_result(%__MODULE__{} = turn) do
    %__MODULE__{tag: tag, monitor: monitor} = turn

    receive do
      {^tag, triple} ->
        Process.demonitor(monitor, [:flush])
        {:done, triple}
    after
      0 -> :none
    end
  end

  # Blocking check (used at EOF, where nothing else can arrive).
  defp await_turn_result(%__MODULE__{} = turn) do
    %__MODULE__{tag: tag, monitor: monitor} = turn

    receive do
      {^tag, triple} ->
        Process.demonitor(monitor, [:flush])
        {:ok, triple}

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :crashed
    end
  end

  defp cancel_for_turn?(trimmed, session_id) do
    match?(
      {:ok, %{"method" => "session/cancel", "params" => %{"sessionId" => ^session_id}}},
      JsonRpc.decode(trimmed)
    )
  end

  defp turn_wire({response, notifications, _state}),
    do: List.wrap(notifications) ++ List.wrap(response)

  defp state_of({_response, _notifications, state}), do: state

  defp write(device, wire) do
    Enum.each(wire, fn msg ->
      IO.write(device, JsonRpc.encode_line(msg))
    end)
  end
end

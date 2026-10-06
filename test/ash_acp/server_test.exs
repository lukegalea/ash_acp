# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.ServerTest do
  @moduledoc """
  The full protocol lifecycle against the fake host behaviours — no IO, no
  processes. This is the acceptance surface of the contract: initialize →
  session/new → session/prompt → session/load → session/cancel, plus the
  JSON-RPC error taxonomy.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshAcp.Server

  setup do
    FakeHost.start()
    :ok
  end

  def new_state, do: Server.new(FakeHost.config())

  # == initialize ============================================================

  test "initialize reports the pinned @acp_version, capabilities and agent info" do
    {response, [], _state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => 1}
        },
        new_state()
      )

    assert response["id"] == 1
    result = response["result"]
    assert result["protocolVersion"] == AshAcp.acp_version()

    assert result["agentInfo"] == %{
             "name" => "fake_host",
             "version" => "1.0.0",
             "title" => "Fake Host"
           }

    assert %{"loadSession" => true, "promptCapabilities" => %{"image" => false, "audio" => false}} =
             result["agentCapabilities"]

    assert result["authMethods"] == []
  end

  test "initialize negotiates down to our version when the client asks for another" do
    {response, [], _} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => 99}
        },
        new_state()
      )

    assert response["result"]["protocolVersion"] == AshAcp.acp_version()
  end

  test "initialize without protocolVersion is invalid params" do
    {response, [], _} =
      Server.handle_message(
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}},
        new_state()
      )

    assert %{"error" => %{"code" => -32602}} = response
  end

  # == session/new ===========================================================

  test "session/new delegates to the host store and returns its sessionId" do
    {response, [], state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "session/new",
          "params" => %{"cwd" => "/tmp", "mcpServers" => []}
        },
        new_state()
      )

    session_id = response["result"]["sessionId"]
    assert session_id == "sess-1"

    # the created session is cached in state with its actor
    session = Map.fetch!(state.sessions, session_id)
    assert session.actor == :operator
  end

  # == session/prompt ========================================================

  test "session/prompt runs the resolved action with authorize?: true and streams updates" do
    {_, _, state} = session_new()

    {response, notifications, state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "session/prompt",
          "params" => %{
            "sessionId" => "sess-1",
            "prompt" => [%{"type" => "text", "text" => "hello"}]
          }
        },
        state
      )

    # turn closed with end_turn after its notifications
    assert response["result"] == %{"stopReason" => "end_turn"}

    assert [
             %{
               "method" => "session/update",
               "params" => %{"update" => %{"sessionUpdate" => "tool_call"}}
             } = tool_call,
             %{
               "params" => %{
                 "update" => %{
                   "sessionUpdate" => "agent_message_chunk",
                   "content" => %{"text" => text}
                 }
               }
             } =
               _chunk,
             %{"params" => %{"update" => %{"sessionUpdate" => "available_commands_update"}}} =
               final,
             completed_tool_call
           ] = notifications

    assert tool_call["params"]["sessionId"] == "sess-1"
    assert tool_call["params"]["update"]["status"] == "in_progress"
    assert tool_call["params"]["update"]["title"] == "Summarize"
    assert tool_call["params"]["update"]["kind"] == "read"

    assert text == "Summary: hello"

    # the closing update carries Ash.can?-pruned actions plus the surface passthrough
    update = final["params"]["update"]

    assert [
             %{"name" => "FakeHost.Note.summarize", "description" => "Summarize the given text"},
             %{"name" => "FakeHost.Note.restricted", "description" => "Only actors may run this"}
           ] = update["availableCommands"]

    assert update["surface"] == %{"type" => "list", "title" => "Notes"}
    assert update["_meta"]["a2ui"] == %{"type" => "list", "title" => "Notes"}
    assert completed_tool_call["params"]["update"]["status"] == "completed"

    # in-flight bookkeeping cleared; transcript recorded in the host store
    assert state.in_flight == %{}
    {:ok, session} = FakeHost.SessionStore.load("sess-1")

    assert [%{role: :user, text: "hello"}, %{role: :agent, text: "Summary: hello"}] =
             session.messages
  end

  test "available actions are pruned per actor with Ash.can?" do
    # :restricted requires an actor; the anonymous actor loses it from the surface
    FakeHost.set_actor(nil)
    {_, _, state} = session_new()

    {_, notifications, _} = prompt(state)

    final = Enum.find(notifications, &update_type(&1, "available_commands_update"))
    names = Enum.map(final["params"]["update"]["availableCommands"], & &1["name"])

    assert "FakeHost.Note.summarize" in names
    refute "FakeHost.Note.restricted" in names
  end

  test "unresolvable prompt ends the turn with refusal" do
    FakeHost.set_prompt_mode({:ok, :unresolvable})
    {_, _, state} = session_new()

    {response, [chunk], _} = prompt(state)

    assert response["result"] == %{"stopReason" => "refusal"}
    assert %{"sessionUpdate" => "agent_message_chunk"} = chunk["params"]["update"]
  end

  test "prompt for an unknown session is resource not found, not invalid params" do
    {response, [], _} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 9,
          "method" => "session/prompt",
          "params" => %{
            "sessionId" => "missing",
            "prompt" => [%{"type" => "text", "text" => "x"}]
          }
        },
        new_state()
      )

    assert %{"error" => %{"code" => -32002}} = response
  end

  test "prompt while one is in flight is an invalid request" do
    state = %{new_state() | in_flight: %{"sess-1" => 99}}

    {response, [], _} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 10,
          "method" => "session/prompt",
          "params" => %{"sessionId" => "sess-1", "prompt" => [%{"type" => "text", "text" => "x"}]}
        },
        state
      )

    assert %{"error" => %{"code" => -32600}} = response
  end

  # == session/load ==========================================================

  test "session/load restores the transcript as update notifications" do
    {_, _, _state} = session_new()
    {:ok, session} = FakeHost.SessionStore.load("sess-1")

    {:ok, session} = FakeHost.SessionStore.append_message(session, :user, "hello")
    {:ok, _session} = FakeHost.SessionStore.append_message(session, :agent, "Summary: hello")

    # a reconnect arrives with a fresh connection state: the transcript must
    # come from the host store, not from any cache
    {response, notifications, _} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "session/load",
          "params" => %{"sessionId" => "sess-1", "cwd" => "/tmp"}
        },
        new_state()
      )

    assert response["result"] == %{}

    assert [
             %{
               "params" => %{
                 "update" => %{
                   "sessionUpdate" => "user_message_chunk",
                   "content" => %{"text" => "hello"}
                 }
               }
             },
             %{
               "params" => %{
                 "update" => %{
                   "sessionUpdate" => "agent_message_chunk",
                   "content" => %{"text" => "Summary: hello"}
                 }
               }
             }
           ] = notifications
  end

  test "session/load of an unknown session is resource not found" do
    {response, [], _} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 5,
          "method" => "session/load",
          "params" => %{"sessionId" => "nope"}
        },
        new_state()
      )

    assert %{"error" => %{"code" => -32002}} = response
  end

  # == session/cancel ========================================================

  test "session/cancel answers the in-flight prompt with stopReason cancelled" do
    state = %{new_state() | in_flight: %{"sess-1" => 42}}

    {response, [], state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "method" => "session/cancel",
          "params" => %{"sessionId" => "sess-1"}
        },
        state
      )

    # addressed to the prompt's request id — that is the call still open
    assert response == %{
             "jsonrpc" => "2.0",
             "id" => 42,
             "result" => %{"stopReason" => "cancelled"}
           }

    assert state.in_flight == %{}
  end

  test "session/cancel with nothing in flight is a silent no-op" do
    {response, [], _} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "method" => "session/cancel",
          "params" => %{"sessionId" => "sess-1"}
        },
        new_state()
      )

    assert response == nil
  end

  # == JSON-RPC taxonomy =====================================================

  test "unknown method request is -32601" do
    {response, [], _} =
      Server.handle_message(
        %{"jsonrpc" => "2.0", "id" => 6, "method" => "fs/read_text_file", "params" => %{}},
        new_state()
      )

    assert %{"error" => %{"code" => -32601, "message" => "Method not found"}} = response
  end

  test "unknown method notification gets no response at all" do
    {response, [], _} =
      Server.handle_message(
        %{"jsonrpc" => "2.0", "method" => "totally/bogus", "params" => %{}},
        new_state()
      )

    assert response == nil
  end

  test "bad params shapes are -32602" do
    {response, [], _} =
      Server.handle_message(
        %{"jsonrpc" => "2.0", "id" => 7, "method" => "session/new", "params" => "not-a-map"},
        new_state()
      )

    assert %{"error" => %{"code" => -32602}} = response

    {response, [], _} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 8,
          "method" => "session/prompt",
          "params" => %{"prompt" => []}
        },
        new_state()
      )

    assert %{"error" => %{"code" => -32602}} = response
  end

  test "handle_line turns unparseable lines into -32700 with id null" do
    {[error], _} = Server.handle_line("{nope", new_state())

    assert error == %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{"code" => -32700, "message" => "Parse error"}
           }
  end

  test "handle_line orders a turn's notifications before its response" do
    {[new_response], state} =
      Server.handle_line(
        ~s({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}),
        new_state()
      )

    assert new_response["result"] == %{"sessionId" => "sess-1"}

    {[tool_call, _chunk, _final, completed, response], _state} =
      Server.handle_line(
        ~s({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"sess-1","prompt":[{"type":"text","text":"x"}]}}),
        state
      )

    assert tool_call["method"] == "session/update"
    assert tool_call["params"]["update"]["sessionUpdate"] == "tool_call"
    assert completed["params"]["update"]["status"] == "completed"
    assert response == %{"jsonrpc" => "2.0", "id" => 3, "result" => %{"stopReason" => "end_turn"}}
  end

  # == helpers ===============================================================

  defp session_new do
    Server.handle_message(
      %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "session/new",
        "params" => %{"cwd" => "/tmp", "mcpServers" => []}
      },
      new_state()
    )
  end

  defp prompt(state) do
    Server.handle_message(
      %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "session/prompt",
        "params" => %{
          "sessionId" => "sess-1",
          "prompt" => [%{"type" => "text", "text" => "hello"}]
        }
      },
      state
    )
  end

  describe "session/load ownership" do
    test "an authenticated actor cannot load another actor's session" do
      FakeHost.set_auth_actor(:actor_a)
      config = FakeHost.config(authenticate: FakeHost.Authenticator)

      {_, _, _} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "session/new",
            "params" => %{"cwd" => "/tmp"}
          },
          Server.new(config)
        )

      # actor B tries to load actor A's session
      FakeHost.set_auth_actor(:actor_b)

      {response, [], _} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => 4,
            "method" => "session/load",
            "params" => %{"sessionId" => "sess-1", "cwd" => "/tmp"}
          },
          Server.new(config)
        )

      assert %{"id" => 4, "error" => %{"code" => -32002, "data" => %{"reason" => reason}}} =
               response

      assert reason =~ "another actor"
    end

    test "the owning actor loads their session normally" do
      FakeHost.set_auth_actor(:actor_a)
      config = FakeHost.config(authenticate: FakeHost.Authenticator)

      {_, _, _} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "session/new",
            "params" => %{"cwd" => "/tmp"}
          },
          Server.new(config)
        )

      {:ok, session} = FakeHost.SessionStore.load("sess-1")
      {:ok, _} = FakeHost.SessionStore.append_message(session, :user, "hello")

      # still actor A, fresh connection state
      {response, notifications, _} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => 4,
            "method" => "session/load",
            "params" => %{"sessionId" => "sess-1", "cwd" => "/tmp"}
          },
          Server.new(config)
        )

      assert response["result"] == %{}

      assert [%{"params" => %{"update" => %{"sessionUpdate" => "user_message_chunk"}}}] =
               notifications
    end

    test "without an authenticator the check is skipped (trusted boundary rule)" do
      {_, _, _} = session_new()

      {response, [], _} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => 4,
            "method" => "session/load",
            "params" => %{"sessionId" => "sess-1", "cwd" => "/tmp"}
          },
          new_state()
        )

      assert response["result"] == %{}
    end
  end

  defp update_type(notification, type) do
    notification["params"]["update"]["sessionUpdate"] == type
  end

  # == read actions (the primary E3 surface) =================================

  describe "read action dispatch" do
    setup do
      ts = ~U[2026-10-06 08:30:15.123456Z]
      amount = Decimal.new("1.50")

      FakeHost.set_notes([
        %FakeHost.Note{
          id: "n-1",
          title: "alpha",
          body: "first",
          amount: amount,
          inserted_at: ts,
          updated_at: ts
        },
        %FakeHost.Note{
          id: "n-2",
          title: "beta",
          body: "second",
          amount: amount,
          inserted_at: ts,
          updated_at: ts
        },
        %FakeHost.Note{
          id: "n-3",
          title: "gamma",
          body: "third",
          amount: amount,
          inserted_at: ts,
          updated_at: ts
        }
      ])

      FakeHost.set_prompt_mode({:ok, :list_notes})
      :ok
    end

    test "a read prompt streams bounded rows plus total count, then ends the turn" do
      {_, _, state} = session_new()

      {response, notifications, _} = prompt(state)

      assert response["result"] == %{"stopReason" => "end_turn"}

      assert [
               _tool_call,
               rows_update,
               %{"params" => %{"update" => %{"sessionUpdate" => "available_commands_update"}}},
               _completed
             ] = notifications

      chunk = rows_update["params"]["update"]["content"]["text"] |> Jason.decode!()
      assert chunk["count"] == 3

      # rows are string-keyed public attributes only
      assert Enum.all?(chunk["rows"], fn row ->
               Map.keys(row) |> Enum.sort() == [
                 "amount",
                 "body",
                 "id",
                 "inserted_at",
                 "title",
                 "updated_at"
               ]
             end)

      assert %{
               "id" => "n-1",
               "title" => "alpha",
               "body" => "first",
               "amount" => "1.50",
               "inserted_at" => "2026-10-06T08:30:15.123456Z",
               "updated_at" => "2026-10-06T08:30:15.123456Z"
             } in chunk["rows"]
    end

    test "the row cap bounds output while the count reflects the total" do
      FakeHost.set_notes(
        for i <- 1..55 do
          %FakeHost.Note{id: "n-#{i}", title: "t#{i}", body: "b#{i}"}
        end
      )

      {_, _, state} = session_new()

      {response, notifications, _} = prompt(state)

      assert response["result"] == %{"stopReason" => "end_turn"}
      rows_update = Enum.find(notifications, &update_type(&1, "agent_message_chunk"))
      chunk = rows_update["params"]["update"]["content"]["text"] |> Jason.decode!()

      assert chunk["count"] == 55
      assert length(chunk["rows"]) == 50
    end

    test "the transcript records the rows payload for session/load replay" do
      {_, _, state} = session_new()
      {_, _, _} = prompt(state)

      {:ok, session} = FakeHost.SessionStore.load("sess-1")
      assert [%{role: :user}, %{role: :agent, text: text}] = session.messages
      assert %{"count" => 3, "rows" => rows} = Jason.decode!(text)
      assert length(rows) == 3
    end

    test "timestamp columns stream as ISO8601 and the payload JSON round-trips" do
      # every platform table has inserted_at/updated_at; a DateTime cell must
      # serialize instead of crashing the turn (live E3 gate regression)
      FakeHost.set_notes([
        %FakeHost.Note{
          id: "n-ts",
          title: "dated",
          body: "with timestamps",
          amount: Decimal.new("12.34"),
          inserted_at: ~U[2026-10-06 08:30:15.123456Z],
          updated_at: ~U[2026-10-06 09:45:00.000000Z]
        }
      ])

      {_, _, state} = session_new()
      {response, notifications, _} = prompt(state)

      assert response["result"] == %{"stopReason" => "end_turn"}

      rows_update = Enum.find(notifications, &update_type(&1, "agent_message_chunk"))
      text = rows_update["params"]["update"]["content"]["text"]

      # full JSON round-trip — this is the assertion that used to crash on
      # the Enumerable protocol
      assert %{"count" => 1, "rows" => [row]} = Jason.decode!(text)
      assert row["inserted_at"] == DateTime.to_iso8601(~U[2026-10-06 08:30:15.123456Z])
      assert row["updated_at"] == DateTime.to_iso8601(~U[2026-10-06 09:45:00.000000Z])
      assert row["amount"] == "12.34"
    end

    test "decimals serialize as exact strings, never floats" do
      # 20 significant digits: a float round-trip would silently change the
      # value (iron law #04 — money), so the wire must carry the string
      exact = Decimal.new("12345678901234567890.123456789")

      FakeHost.set_notes([
        %FakeHost.Note{id: "n-dec", title: "big", body: "exact", amount: exact}
      ])

      {_, _, state} = session_new()
      {_, notifications, _} = prompt(state)

      rows_update = Enum.find(notifications, &update_type(&1, "agent_message_chunk"))

      assert %{"rows" => [row]} =
               Jason.decode!(rows_update["params"]["update"]["content"]["text"])

      assert row["amount"] == "12345678901234567890.123456789"
      assert is_binary(row["amount"])
    end

    test "money-shaped structs serialize as amount-string plus currency" do
      # duck-typed ash_money: any struct with amount + currency
      money = %{
        __struct__: AshMoneyTestMoney,
        amount: Decimal.new("1.99"),
        currency: :USD
      }

      assert AshAcp.Server.stringify_value(money) == %{"amount" => "1.99", "currency" => "USD"}

      assert AshAcp.Server.stringify_value(Decimal.new("12345678901234567890.5")) ==
               "12345678901234567890.5"
    end
  end

  describe "tenant passthrough" do
    test "the action spec's tenant reaches the Ash read as query tenant" do
      FakeHost.set_notes([
        %FakeHost.Note{id: "n-1", title: "a", body: "b", amount: Decimal.new("2.25")}
      ])

      FakeHost.set_tenant_probe(self())
      FakeHost.set_prompt_mode({:ok, :tenant_read})

      {_, _, state} = session_new()

      {response, _, _} = prompt(state)

      assert response["result"] == %{"stopReason" => "end_turn"}
      assert_received {:tenant, "acme"}
    end
  end

  describe "unsupported action types are wire errors" do
    test ":create answers the prompt with -32603 instead of crashing" do
      FakeHost.set_prompt_mode({:ok, :create_note})
      {_, _, state} = session_new()

      {response, notifications, _} = prompt(state)

      assert %{"id" => 3, "error" => %{"code" => -32603, "message" => "unsupported action type"}} =
               response

      assert response["error"]["data"]["actionType"] == ":create"

      failed = hd(notifications)
      assert failed["params"]["update"]["status"] == "failed"
    end
  end

  describe "handle_message never raises" do
    defmodule ExplodingPromptTarget do
      @moduledoc false
      @behaviour AshAcp.PromptTarget

      def resolve(_session_id, _text, _ctx), do: raise("prompt target blew up")
    end

    test "a seam crash becomes a -32603 response with a logged stacktrace" do
      FakeHost.set_prompt_mode({:ok, :summarize})

      log =
        capture_log(fn ->
          # a session cached from an earlier message, so the prompt reaches
          # the target instead of failing session lookup
          {_, _, state} = session_new()

          exploding_state = %{
            Server.new(FakeHost.config(prompt_target: ExplodingPromptTarget))
            | sessions: state.sessions
          }

          {response, [], _state} =
            Server.handle_message(
              %{
                "jsonrpc" => "2.0",
                "id" => 7,
                "method" => "session/prompt",
                "params" => %{
                  "sessionId" => "sess-1",
                  "prompt" => [%{"type" => "text", "text" => "x"}]
                }
              },
              exploding_state
            )

          assert %{"id" => 7, "error" => %{"code" => -32603}} = response
          assert response["error"]["data"]["reason"] =~ "blew up"
        end)

      assert log =~ "handle_message/2 crashed"
    end
  end
end

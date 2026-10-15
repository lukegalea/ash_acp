# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.PermissionTest do
  @moduledoc """
  The ADR 0015 seam: approvals live in Ash (the host's approval resource),
  surfaced through `session/request_permission`. Denial propagates; approval
  executes the action — with `authorize?: true`, never bypassing policies.
  """
  use ExUnit.Case, async: false

  alias AshAcp.Server

  setup do
    FakeHost.start()
    :ok
  end

  def new_state(config_overrides \\ []), do: Server.new(FakeHost.config(config_overrides))

  def session_new(config_overrides \\ []) do
    Server.handle_message(
      %{"jsonrpc" => "2.0", "id" => 2, "method" => "session/new", "params" => %{"cwd" => "/tmp"}},
      new_state(config_overrides)
    )
  end

  def publish_prompt(state) do
    FakeHost.set_prompt_mode({:ok, :publish})

    Server.handle_message(
      %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "session/prompt",
        "params" => %{
          "sessionId" => "sess-1",
          "prompt" => [%{"type" => "text", "text" => "ship it"}]
        }
      },
      state
    )
  end

  describe "host pre-decided approvals" do
    test "{:approved, approval} executes immediately and carries the approval metadata" do
      FakeHost.set_permission_mode({:approved, %{approval_id: "appr-7"}})
      {_, _, state} = session_new()

      {response, notifications, _} = publish_prompt(state)

      assert response["result"] == %{"stopReason" => "end_turn"}

      tool_call =
        Enum.find(notifications, &(&1["params"]["update"]["sessionUpdate"] == "tool_call"))

      assert tool_call["params"]["update"]["approval"] == %{"approval_id" => "appr-7"}

      chunk =
        Enum.find(
          notifications,
          &(&1["params"]["update"]["sessionUpdate"] == "agent_message_chunk")
        )

      assert chunk["params"]["update"]["content"]["text"] == "Bulletin published: ship it"
    end

    test "{:denied} never executes and ends the turn refused" do
      FakeHost.set_permission_mode({:denied})
      {_, _, state} = session_new()

      {response, notifications, _} = publish_prompt(state)

      assert response["result"] == %{"stopReason" => "refusal"}

      assert [
               %{"update" => %{"sessionUpdate" => "tool_call_update"}}
             ] = Enum.map(notifications, & &1["params"])

      update = hd(notifications)["params"]["update"]
      assert update["status"] == "failed"

      assert [
               %{
                 "type" => "content",
                 "content" => %{"type" => "text", "text" => "Permission denied"}
               }
             ] =
               update["content"]

      # nothing ran
      {:ok, session} = FakeHost.SessionStore.load("sess-1")
      assert Enum.any?(session.messages, &(&1.role == :user))
      assert Enum.any?(session.messages, &(&1.role == :agent and &1.text == "Permission denied."))
    end
  end

  describe "pending approvals keep the prompt turn open" do
    test "prompt emits session/request_permission with NO prompt response yet" do
      FakeHost.set_permission_mode({:pending, "approval-ref-1"})
      {_, _, state} = session_new()

      {response, [outbound], state} = publish_prompt(state)

      # the turn stays open: no response, in_flight still holds the prompt
      assert response == nil
      assert state.in_flight == %{"sess-1" => 3}

      assert outbound["id"] == "srv-1"
      assert outbound["method"] == "session/request_permission"
      params = outbound["params"]
      assert params["sessionId"] == "sess-1"
      assert params["toolCall"]["title"] == "Publish bulletin"
      assert params["toolCall"]["status"] == "pending"

      assert [
               %{"optionId" => "allow_once"},
               %{"optionId" => "allow_always"},
               %{"optionId" => "reject_once"}
             ] =
               params["options"]

      assert params["_meta"]["requestRef"] == "approval-ref-1"

      # the pending request is tracked in state
      assert %{session_id: "sess-1", request_ref: "approval-ref-1", prompt_request_id: 3} =
               Map.fetch!(state.pending_permissions, "srv-1")
    end

    test "client approval streams the result then completes the prompt with end_turn" do
      FakeHost.set_permission_mode({:pending, "approval-ref-2"})
      {_, _, state} = session_new()
      {nil, _, state} = publish_prompt(state)

      # the client answers "allow once"
      {response, notifications, _} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => "srv-1",
            "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}
          },
          state
        )

      # the updates stream first, then the prompt response completes the turn
      # addressed to the ORIGINAL prompt request id
      assert response == %{
               "jsonrpc" => "2.0",
               "id" => 3,
               "result" => %{"stopReason" => "end_turn"}
             }

      assert [
               %{"sessionUpdate" => "tool_call"},
               %{"sessionUpdate" => "agent_message_chunk"},
               %{"sessionUpdate" => "available_commands_update"},
               %{"sessionUpdate" => "tool_call_update"}
             ] =
               Enum.map(notifications, & &1["params"]["update"])

      chunk =
        Enum.find(
          notifications,
          &(&1["params"]["update"]["sessionUpdate"] == "agent_message_chunk")
        )

      assert chunk["params"]["update"]["content"]["text"] == "Bulletin published: ship it"
    end

    test "client rejection completes the prompt refused" do
      FakeHost.set_permission_mode({:pending, "approval-ref-3"})
      {_, _, state} = session_new()
      {nil, _, state} = publish_prompt(state)

      {response, notifications, _} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => "srv-1",
            "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "reject_once"}}
          },
          state
        )

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => 3,
               "result" => %{"stopReason" => "refusal"}
             }

      failed = hd(notifications)
      assert failed["params"]["update"]["status"] == "failed"

      assert failed["params"]["update"]["content"] == [
               %{
                 "type" => "content",
                 "content" => %{"type" => "text", "text" => "Permission denied"}
               }
             ]

      assert Enum.count(notifications) == 1
    end

    test "client cancellation of the permission request completes the prompt refused" do
      FakeHost.set_permission_mode({:pending, "approval-ref-4"})
      {_, _, state} = session_new()
      {nil, _, state} = publish_prompt(state)

      {response, notifications, _} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => "srv-1",
            "result" => %{"outcome" => %{"outcome" => "cancelled"}}
          },
          state
        )

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => 3,
               "result" => %{"stopReason" => "refusal"}
             }

      assert hd(notifications)["params"]["update"]["status"] == "failed"
    end

    test "a second prompt while the permission is pending is refused as in-flight" do
      FakeHost.set_permission_mode({:pending, "approval-ref-5"})
      {_, _, state} = session_new()
      {nil, _, state} = publish_prompt(state)

      {response, [], _} = publish_prompt(state)

      assert %{"error" => %{"code" => -32600}} = response
    end

    test "hosts without resolve/3 get the default outcome mapping" do
      defmodule BarePermissions do
        @moduledoc false
        @behaviour AshAcp.PermissionRequest

        # no resolve/3 — the server must fall back to
        # AshAcp.PermissionRequest.default_resolve/2
        def request(_s, _a, _i), do: {:pending, "bare-ref"}
      end

      FakeHost.set_prompt_mode({:ok, :publish})

      {_, _, state} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "session/new",
            "params" => %{"cwd" => "/tmp"}
          },
          Server.new(FakeHost.config(permission_request: BarePermissions))
        )

      {_, [outbound], state} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => 3,
            "method" => "session/prompt",
            "params" => %{
              "sessionId" => "sess-1",
              "prompt" => [%{"type" => "text", "text" => "x"}]
            }
          },
          state
        )

      assert outbound["id"] == "srv-1"

      # default resolve: allow_once → {:approved, nil} → the action runs and
      # the open prompt completes with end_turn
      {response, notifications, _} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => "srv-1",
            "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}
          },
          state
        )

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => 3,
               "result" => %{"stopReason" => "end_turn"}
             }

      chunk =
        Enum.find(
          notifications,
          &(&1["params"]["update"]["sessionUpdate"] == "agent_message_chunk")
        )

      assert chunk["params"]["update"]["content"]["text"] == "Bulletin published: x"
    end
  end

  describe "Ash policy refusals never ask the client" do
    defp prompt(state, text \\ "try") do
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "session/prompt",
          "params" => %{
            "sessionId" => "sess-1",
            "prompt" => [%{"type" => "text", "text" => text}]
          }
        },
        state
      )
    end

    defp not_permitted?(notification) do
      update = notification["params"]["update"]

      update["sessionUpdate"] == "tool_call_update" and update["status"] == "failed" and
        update["content"] == [
          %{"type" => "content", "content" => %{"type" => "text", "text" => "Not permitted"}}
        ]
    end

    test "a write the actor's policies refuse is refused up front: no approval, no prompt" do
      # anonymous actor cannot run :restricted; the host seam would pend
      FakeHost.set_actor(nil)
      FakeHost.set_prompt_mode({:ok, :restricted})
      FakeHost.set_permission_mode({:pending, "never-used"})
      FakeHost.set_request_probe(self())
      {_, _, state} = session_new()

      {response, notifications, state} = prompt(state)

      # the denial straight away: a refusal, no session/request_permission,
      # and the host's approval seam was never asked to record anything
      assert response["result"] == %{"stopReason" => "refusal"}
      assert [notification] = notifications
      assert not_permitted?(notification)
      refute Enum.any?(notifications, &(&1["method"] == "session/request_permission"))
      refute_received {:permission_requested, _}

      # the turn is over: nothing pending, nothing in flight
      assert state.pending_permissions == %{}
      assert state.in_flight == %{}

      {:ok, session} = FakeHost.SessionStore.load("sess-1")
      assert Enum.any?(session.messages, &(&1.role == :agent and &1.text == "Not permitted."))
    end

    test "the up-front check uses the action's own actor, input and tenant" do
      # the same prompt with an actor present is authorized: the host seam
      # decides as before (here: pends, so the client is asked)
      FakeHost.set_prompt_mode({:ok, :restricted})
      FakeHost.set_permission_mode({:pending, "ref-1"})
      FakeHost.set_request_probe(self())
      {_, _, state} = session_new()

      {nil, [outbound], state} = prompt(state)

      assert outbound["method"] == "session/request_permission"
      assert_received {:permission_requested, %{action: :restricted}}
      assert state.in_flight == %{"sess-1" => 3}
    end

    test "a policy refusal at execution ends the turn refused — the client is not asked again" do
      # authorization changes between the up-front check and the run (a
      # grant revoked while the approval was pending): the check passes,
      # the client approves, the run is forbidden.
      FakeHost.set_prompt_mode({:ok, :gated})
      FakeHost.set_permission_mode({:pending, "ref-1"})
      {_, _, state} = session_new()

      {nil, [%{"id" => "srv-1"}], state} = prompt(state)

      FakeHost.set_gate(false)

      {response, notifications, state} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => "srv-1",
            "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}
          },
          state
        )

      assert response["id"] == 3
      assert response["result"] == %{"stopReason" => "refusal"}
      refute Enum.any?(notifications, &(&1["method"] == "session/request_permission"))
      assert Enum.any?(notifications, &not_permitted?/1)
      assert state.pending_permissions == %{}
      assert state.in_flight == %{}

      {:ok, session} = FakeHost.SessionStore.load("sess-1")
      refute Enum.any?(session.messages, &(&1.role == :agent and &1.text =~ "gated ok"))
    end

    test "a host that approves everything still cannot get past Ash policies" do
      defmodule ApprovingPermissions do
        @moduledoc false
        @behaviour AshAcp.PermissionRequest

        def request(_s, _a, _i), do: {:approved, nil}
        def resolve(_ref, _outcome, _session), do: {:approved, nil}
      end

      FakeHost.set_actor(nil)
      FakeHost.set_prompt_mode({:ok, :restricted})
      {_, _, state} = session_new(permission_request: ApprovingPermissions)

      {response, notifications, _state} = prompt(state)

      assert response["result"] == %{"stopReason" => "refusal"}
      assert Enum.any?(notifications, &not_permitted?/1)

      # nothing ran
      refute inspect(notifications) =~ "restricted ok"
    end

    test "an undecidable up-front check (:maybe) asks as before" do
      # a read with run_queries?: false is :maybe for Ash.can — the library
      # never refuses on a maybe; the host seam decides as it always has
      FakeHost.set_actor(nil)
      FakeHost.set_prompt_mode({:ok, :list_notes})
      FakeHost.set_permission_mode({:pending, "ref-1"})
      FakeHost.set_request_probe(self())
      {_, _, state} = session_new()

      {nil, [outbound], _state} = prompt(state)

      assert outbound["method"] == "session/request_permission"
      assert_received {:permission_requested, %{action: :list_notes}}
    end
  end

  describe "contract violations fail loudly" do
    import ExUnit.CaptureLog

    test "resolve/3 returning a bare :approved answers the pending prompt with -32603" do
      defmodule BareAtomResolve do
        @moduledoc false
        @behaviour AshAcp.PermissionRequest

        # exactly the host-side bug that hung a live client
        def request(_s, _a, _i), do: {:pending, "ref"}
        def resolve(_ref, _outcome, _session), do: :approved
      end

      FakeHost.set_prompt_mode({:ok, :publish})
      {_, _, state} = session_new(permission_request: BareAtomResolve)

      {response, [outbound], state} = publish_prompt(state)

      # the turn stays open: no prompt response until the client resolves
      assert response == nil
      assert outbound["id"] == "srv-1"

      log =
        capture_log(fn ->
          {response, _notifications, _state} =
            Server.handle_message(
              %{
                "jsonrpc" => "2.0",
                "id" => "srv-1",
                "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}
              },
              state
            )

          # addressed to the *prompt's* request id — the client is waiting on it
          assert %{"id" => 3, "error" => %{"code" => -32603}} = response
          assert response["error"]["data"]["reason"] =~ "BareAtomResolve.resolve/3"
        end)

      assert log =~ "BareAtomResolve"
      assert log =~ "-32603"
    end

    test "request/3 returning {:error, _} answers the prompt with -32603" do
      defmodule ErrorRequest do
        @moduledoc false
        @behaviour AshAcp.PermissionRequest

        def request(_s, _a, _i), do: {:error, :approval_backend_down}
      end

      FakeHost.set_prompt_mode({:ok, :publish})
      {_, _, state} = session_new(permission_request: ErrorRequest)

      log =
        capture_log(fn ->
          {response, notifications, state} = publish_prompt(state)

          assert %{"id" => 3, "error" => %{"code" => -32603}} = response
          assert response["error"]["data"]["reason"] =~ "ErrorRequest.request/3"
          assert notifications == []
          assert state.in_flight == %{}
        end)

      assert log =~ "ErrorRequest"
      assert log =~ "{:error, :approval_backend_down}"
    end

    test "request/3 returning junk is treated as a violation too" do
      defmodule JunkRequest do
        @moduledoc false
        @behaviour AshAcp.PermissionRequest

        def request(_s, _a, _i), do: :nope
      end

      FakeHost.set_prompt_mode({:ok, :publish})
      {_, _, state} = session_new(permission_request: JunkRequest)

      {response, [], _} = publish_prompt(state)
      assert %{"id" => 3, "error" => %{"code" => -32603}} = response
    end
  end
end

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

  def new_state, do: Server.new(FakeHost.config())

  def session_new do
    Server.handle_message(
      %{"jsonrpc" => "2.0", "id" => 2, "method" => "session/new", "params" => %{"cwd" => "/tmp"}},
      new_state()
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
      assert [%{"text" => "Permission denied"}] = update["content"]

      # nothing ran
      {:ok, session} = FakeHost.SessionStore.load("sess-1")
      assert Enum.any?(session.messages, &(&1.role == :user))
      assert Enum.any?(session.messages, &(&1.role == :agent and &1.text == "Permission denied."))
    end
  end

  describe "pending approvals surfaced to the client" do
    test "prompt produces a session/request_permission request and ends the turn" do
      FakeHost.set_permission_mode({:pending, "approval-ref-1"})
      {_, _, state} = session_new()

      {response, [outbound], state} = publish_prompt(state)

      # the turn closes; the permission flow continues asynchronously
      assert response["result"] == %{"stopReason" => "end_turn"}

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
      assert %{session_id: "sess-1", request_ref: "approval-ref-1"} =
               Map.fetch!(state.pending_permissions, "srv-1")
    end

    test "client approval executes the action; denial propagates as denied" do
      FakeHost.set_permission_mode({:pending, "approval-ref-2"})
      {_, _, state} = session_new()
      {_, _, state} = publish_prompt(state)

      # the client answers "allow once"
      {nil, notifications, _} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => "srv-1",
            "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}
          },
          state
        )

      chunk =
        Enum.find(
          notifications,
          &(&1["params"]["update"]["sessionUpdate"] == "agent_message_chunk")
        )

      assert chunk["params"]["update"]["content"]["text"] == "Bulletin published: ship it"

      completed =
        Enum.find(notifications, &(&1["params"]["update"]["sessionUpdate"] == "tool_call_update"))

      assert completed["params"]["update"]["status"] == "completed"

      # fresh pending permission, then the client rejects
      {_, _, state} = session_new()
      FakeHost.set_permission_mode({:pending, "approval-ref-3"})
      {_, _, state} = publish_prompt(state)

      {nil, notifications, _} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => "srv-1",
            "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "reject_once"}}
          },
          state
        )

      failed = hd(notifications)
      assert failed["params"]["update"]["status"] == "failed"

      assert failed["params"]["update"]["content"] == [
               %{"type" => "text", "text" => "Permission denied"}
             ]
    end

    test "client cancellation of the permission request is treated as denial" do
      FakeHost.set_permission_mode({:pending, "approval-ref-4"})
      {_, _, state} = session_new()
      {_, _, state} = publish_prompt(state)

      {nil, notifications, _} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => "srv-1",
            "result" => %{"outcome" => %{"outcome" => "cancelled"}}
          },
          state
        )

      assert hd(notifications)["params"]["update"]["status"] == "failed"
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

      # default resolve: allow_once → {:approved, nil} → the action runs
      {nil, notifications, _} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => "srv-1",
            "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}
          },
          state
        )

      chunk =
        Enum.find(
          notifications,
          &(&1["params"]["update"]["sessionUpdate"] == "agent_message_chunk")
        )

      assert chunk["params"]["update"]["content"]["text"] == "Bulletin published: x"
    end
  end

  describe "Ash policy denials become permission requests" do
    test "unauthorized prompt surfaces session/request_permission, not a wire error" do
      # anonymous actor cannot run :restricted
      FakeHost.set_actor(nil)
      FakeHost.set_prompt_mode({:ok, :restricted})
      FakeHost.set_permission_mode({:approved, nil})
      {_, _, state} = session_new()

      {response, [outbound], _} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => 3,
            "method" => "session/prompt",
            "params" => %{
              "sessionId" => "sess-1",
              "prompt" => [%{"type" => "text", "text" => "try"}]
            }
          },
          state
        )

      # not an error — a permission request
      assert response["result"] == %{"stopReason" => "end_turn"}
      assert outbound["method"] == "session/request_permission"
      assert outbound["params"]["toolCall"]["title"] == "Restricted op"
    end

    test "approving an unauthorized prompt still cannot bypass Ash policies" do
      # host seam approves everything; the anonymous actor still cannot run
      # :restricted because approval never overrides Ash policies.
      defmodule ApprovingPermissions do
        @moduledoc false
        @behaviour AshAcp.PermissionRequest

        def request(_s, _a, _i), do: {:pending, "ref"}

        def resolve(_ref, _outcome, _session), do: {:approved, nil}
      end

      FakeHost.set_actor(nil)
      FakeHost.set_prompt_mode({:ok, :restricted})

      config = FakeHost.config(permission_request: ApprovingPermissions)

      {_, _, state} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "session/new",
            "params" => %{"cwd" => "/tmp"}
          },
          Server.new(config)
        )

      {_, [first_request], state} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => 3,
            "method" => "session/prompt",
            "params" => %{
              "sessionId" => "sess-1",
              "prompt" => [%{"type" => "text", "text" => "try"}]
            }
          },
          state
        )

      assert first_request["id"] == "srv-1"

      # the client approves — resolve says {:approved, nil} — but the action
      # is re-attempted with authorize?: true, Ash denies again, and the
      # denial becomes a fresh permission request rather than a result.
      {nil, [second_request], state} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => "srv-1",
            "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}
          },
          state
        )

      assert second_request["method"] == "session/request_permission"
      assert is_map_key(state.pending_permissions, "srv-2")

      # and nothing executed: the transcript holds the prompt, no result text
      {:ok, session} = FakeHost.SessionStore.load("sess-1")

      refute Enum.any?(
               session.messages,
               &(&1.role == :agent and String.contains?(&1.text, "restricted ok"))
             )
    end
  end
end

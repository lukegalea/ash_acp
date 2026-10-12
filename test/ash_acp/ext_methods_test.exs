# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.ExtMethodsTest do
  @moduledoc """
  The extension-method seam beyond the golden fixtures: ownership, contract
  violations, permission edge cases, the advertisement, and the supporting
  0.2.0 changes (config keys, update builders, session/list without a
  lister, the stderr log handler).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshAcp.Server
  alias AshAcp.TestSupport.SchemaConformance

  setup do
    FakeHost.start()
    :ok
  end

  defp call(state, method, params, id \\ 10) do
    Server.handle_message(
      %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params},
      state
    )
  end

  defp with_session(config \\ FakeHost.config()) do
    {_, _, state} = call(Server.new(config), "session/new", %{"cwd" => "/tmp"}, 2)
    state
  end

  describe "routing and advertisement" do
    test "without an ext handler, `_` methods are -32601 and initialize carries no _meta" do
      state = Server.new(FakeHost.config(ext_methods: nil))

      {init, [], state} = call(state, "initialize", %{"protocolVersion" => 1}, 1)
      refute Map.has_key?(init["result"], "_meta")
      refute Map.has_key?(init["result"]["agentCapabilities"], "_meta")

      {response, [], _} = call(state, "_ash/surfaces/list", %{})
      assert response["error"]["code"] == -32601
    end

    test "a crashing capabilities/1 is logged and the handshake still succeeds" do
      log =
        capture_log(fn ->
          {init, [], _} =
            call(
              Server.new(FakeHost.config(ext_methods: AshAcp.ExtMethodsTest.CrashingCaps)),
              "initialize",
              %{"protocolVersion" => 1},
              1
            )

          assert init["result"]["_meta"] == %{"ash" => %{"extMethods" => ["_x/ping"]}}
        end)

      assert log =~ "capabilities/1 crashed"
    end

    test "the handler context carries the connection's authenticated actor when no session is named" do
      FakeHost.set_auth_actor(:actor_a)

      config =
        FakeHost.config(
          ext_methods: AshAcp.ExtMethodsTest.Echo,
          authenticate: FakeHost.Authenticator
        )

      {_, [], state} = call(Server.new(config), "initialize", %{"protocolVersion" => 1}, 1)
      {response, [], _} = call(state, "_x/ping", %{})

      assert response["result"] == %{"actor" => "actor_a", "session" => nil, "permission" => nil}
    end
  end

  describe "sessions and ownership" do
    test "an ext call naming another actor's session is resource not found" do
      FakeHost.set_auth_actor(:actor_a)
      config = FakeHost.config(authenticate: FakeHost.Authenticator)
      _ = with_session(config)

      FakeHost.set_auth_actor(:actor_b)
      {_, [], state_b} = call(Server.new(config), "initialize", %{"protocolVersion" => 1}, 1)

      {response, [], _} =
        call(state_b, "_ash/surface/open", %{"sessionId" => "sess-1", "surface" => "notes"})

      assert %{"code" => -32002, "data" => %{"reason" => "session belongs to another actor"}} =
               response["error"]

      # and the same guard covers prompts on a connection that never loaded it
      {prompt, [], _} =
        call(state_b, "session/prompt", %{
          "sessionId" => "sess-1",
          "prompt" => [%{"type" => "text", "text" => "hi"}]
        })

      assert prompt["error"]["code"] == -32002
    end

    test "a non-string sessionId is invalid params" do
      {response, [], _} = call(with_session(), "_ash/surfaces/list", %{"sessionId" => 7})
      assert response["error"]["code"] == -32602
    end
  end

  describe "contract violations and edge cases" do
    test "a junk handler return is -32603 and names the module" do
      log =
        capture_log(fn ->
          {response, [], _} =
            call(with_session(), "_a2ui/action", %{
              "sessionId" => "sess-1",
              "surfaceId" => "notes",
              "action" => %{"name" => "explode"}
            })

          assert response["error"]["code"] == -32603
          assert response["error"]["data"]["reason"] =~ "FakeHost.ExtMethods.handle/3"
        end)

      assert log =~ "violates its contract"
    end

    test "a consequential call without a session is invalid params, never a silent approval" do
      {response, [], state} =
        call(with_session(), "_a2ui/action", %{
          "surfaceId" => "notes",
          "action" => %{"name" => "publish", "context" => %{"text" => "x"}}
        })

      assert response["error"]["code"] == -32602
      assert response["error"]["data"]["reason"] =~ "needs a sessionId"
      assert state.pending_permissions == %{}
    end

    test "updates without a session violate the contract" do
      capture_log(fn ->
        {response, [], _} =
          call(
            Server.new(FakeHost.config(ext_methods: AshAcp.ExtMethodsTest.Echo)),
            "_x/updates",
            %{}
          )

        assert response["error"]["code"] == -32603
      end)
    end

    test "updates with a session become session/update notifications ahead of the response" do
      state = with_session(FakeHost.config(ext_methods: AshAcp.ExtMethodsTest.Echo))

      {response, [thought, plan], _} = call(state, "_x/updates", %{"sessionId" => "sess-1"})

      assert response["result"] == %{"ok" => true}
      assert thought["params"]["update"]["sessionUpdate"] == "agent_thought_chunk"
      assert plan["params"]["update"]["sessionUpdate"] == "plan"

      for notification <- [thought, plan] do
        assert SchemaConformance.validate_outbound(notification, %{}) == []
      end
    end

    test "a prompt cancel leaves a pending extension permission answerable" do
      FakeHost.set_permission_mode({:pending, "ref-ext"})

      {nil, [%{"id" => outbound_id}], state} =
        call(with_session(), "_a2ui/action", %{
          "sessionId" => "sess-1",
          "surfaceId" => "notes",
          "action" => %{"name" => "publish", "context" => %{"text" => "x"}}
        })

      {nil, [], state} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "method" => "session/cancel",
            "params" => %{"sessionId" => "sess-1"}
          },
          state
        )

      {response, _notifications, _} =
        Server.handle_message(
          %{
            "jsonrpc" => "2.0",
            "id" => outbound_id,
            "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}
          },
          state
        )

      assert response["id"] == 10
      assert response["result"]["outcome"] == "applied"
    end

    test "an immediate approval re-calls the handler with the approval and the session actor" do
      FakeHost.set_permission_mode({:approved, %{"by" => "policy"}})
      state = with_session(FakeHost.config(ext_methods: AshAcp.ExtMethodsTest.Echo))

      {response, [], _} = call(state, "_x/guarded", %{"sessionId" => "sess-1"})

      assert response["result"] == %{
               "actor" => "operator",
               "session" => "sess-1",
               "permission" => %{"approved" => %{"by" => "policy"}}
             }
    end
  end

  describe "supporting changes" do
    test "AshAcp.config/0 carries candidate_actions and ext_methods from app env" do
      Application.put_env(:ash_acp, :candidate_actions, [{FakeHost.Note, :summarize}])
      Application.put_env(:ash_acp, :ext_methods, FakeHost.ExtMethods)

      on_exit(fn ->
        Application.delete_env(:ash_acp, :candidate_actions)
        Application.delete_env(:ash_acp, :ext_methods)
      end)

      config = AshAcp.config()
      assert config.candidate_actions == [{FakeHost.Note, :summarize}]
      assert config.ext_methods == FakeHost.ExtMethods

      Application.delete_env(:ash_acp, :candidate_actions)
      assert AshAcp.config().candidate_actions == []
    end

    test "session/list is -32601 and unadvertised when the store cannot list" do
      config = FakeHost.config(session_store: AshAcp.ExtMethodsTest.NoListStore)

      {init, [], state} = call(Server.new(config), "initialize", %{"protocolVersion" => 1}, 1)
      assert init["result"]["agentCapabilities"]["sessionCapabilities"] == %{}

      {response, [], _} = call(state, "session/list", %{})
      assert response["error"]["code"] == -32601
    end

    test "session/list hands the store the connection actor and drops foreign sessions" do
      FakeHost.set_tenant_probe(self())
      FakeHost.set_auth_actor(:actor_a)
      config = FakeHost.config(authenticate: FakeHost.Authenticator)
      _ = with_session(config)
      FakeHost.set_auth_actor(:actor_b)
      _ = with_session(config)

      {_, [], state} = call(Server.new(config), "initialize", %{"protocolVersion" => 1}, 1)
      {response, [], _} = call(state, "session/list", %{})

      assert_received {:list_filter, %{"actor" => :actor_b}}
      assert [%{"sessionId" => "sess-2"}] = response["result"]["sessions"]
    end

    test "the surface provider is told why it is asked" do
      config = FakeHost.config(surface_provider: AshAcp.ExtMethodsTest.ReasonSurface)
      {_, [commands], state} = call(Server.new(config), "session/new", %{"cwd" => "/tmp"}, 2)
      assert commands["params"]["update"]["_meta"]["a2ui"] == %{"reason" => "session_new"}

      {_, notifications, _} =
        call(state, "session/load", %{"sessionId" => "sess-1", "cwd" => "/"})

      assert List.last(notifications)["params"]["update"]["_meta"]["a2ui"] == %{
               "reason" => "session_load"
             }
    end

    test "update builders produce schema-valid session updates" do
      updates = [
        AshAcp.Updates.agent_thought("thinking"),
        AshAcp.Updates.agent_message("hello"),
        AshAcp.Updates.user_message("hi"),
        AshAcp.Updates.plan([
          %{content: "Read the inbox", priority: :high, status: :in_progress},
          %{"content" => "Draft a reply"}
        ]),
        AshAcp.Updates.available_commands([%{"name" => "x", "description" => "y"}]),
        AshAcp.Updates.session_info("Morning")
      ]

      for update <- updates do
        assert SchemaConformance.validate_outbound(AshAcp.Updates.notification("s", update), %{}) ==
                 [],
               "#{update["sessionUpdate"]} drifted from the ACP schema"
      end

      assert %{"entries" => [_, %{"priority" => "medium", "status" => "pending"}]} =
               Enum.at(updates, 3)
    end

    test "keep_stdout_pure installs an :error-level stderr handler (level is a handler key)" do
      {:ok, original} = :logger.get_handler_config(:default)

      on_exit(fn ->
        :logger.remove_handler(:default)
        :logger.add_handler(:default, original.module, original)
      end)

      assert :ok = AshAcp.Endpoint.keep_stdout_pure()

      assert {:ok, %{level: :error, config: %{type: :standard_error}}} =
               :logger.get_handler_config(:default)

      # idempotent
      assert :ok = AshAcp.Endpoint.keep_stdout_pure()
    end
  end
end

defmodule AshAcp.ExtMethodsTest.CrashingCaps do
  @moduledoc false
  @behaviour AshAcp.ExtMethods

  @impl true
  def methods, do: ["_x/ping"]

  @impl true
  def capabilities(_ctx), do: raise("index unavailable")

  @impl true
  def handle(_method, _params, _ctx), do: {:ok, %{}}
end

defmodule AshAcp.ExtMethodsTest.Echo do
  @moduledoc false
  @behaviour AshAcp.ExtMethods

  @impl true
  def methods, do: ["_x/ping", "_x/updates", "_x/guarded"]

  @impl true
  def handle("_x/ping", _params, ctx), do: {:ok, echo(ctx)}

  def handle("_x/updates", _params, _ctx) do
    {:ok, %{ok: true},
     [
       AshAcp.Updates.agent_thought("considering"),
       AshAcp.Updates.plan([%{content: "step one"}])
     ]}
  end

  def handle("_x/guarded", _params, %{permission: nil}),
    do: {:request_permission, %{title: "Guarded"}}

  def handle("_x/guarded", _params, ctx), do: {:ok, echo(ctx)}

  defp echo(ctx) do
    %{
      actor: ctx.actor && to_string(ctx.actor),
      session: ctx.session_id,
      permission:
        case ctx.permission do
          {:approved, approval} -> %{approved: approval}
          other -> other
        end
    }
  end
end

defmodule AshAcp.ExtMethodsTest.NoListStore do
  @moduledoc false
  @behaviour AshAcp.SessionStore

  @impl true
  defdelegate create(init), to: FakeHost.SessionStore
  @impl true
  defdelegate load(id), to: FakeHost.SessionStore
  @impl true
  defdelegate append_message(session, role, text), to: FakeHost.SessionStore
  @impl true
  defdelegate close(id), to: FakeHost.SessionStore
end

defmodule AshAcp.ExtMethodsTest.ReasonSurface do
  @moduledoc false
  @behaviour AshAcp.SurfaceProvider

  @impl true
  def surface(_session, %{reason: reason}), do: %{"reason" => to_string(reason)}
end

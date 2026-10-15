# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.A2uiActionOutcomeTest do
  @moduledoc """
  `_a2ui/action` writes the actor cannot do, or that fail: the up-front
  `Ash.can?` refusal on the extension path (no approval, no
  `session/request_permission`), and the `failed` outcome a refused,
  invalid or errored write answers with — never `applied`.
  """
  use ExUnit.Case, async: false

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

  defp with_session do
    {_, _, state} = call(Server.new(FakeHost.config()), "session/new", %{"cwd" => "/tmp"}, 2)
    state
  end

  defp act(state, name, context \\ %{}) do
    call(state, "_a2ui/action", %{
      "sessionId" => "sess-1",
      "surfaceId" => "notes",
      "action" => %{"name" => name, "context" => context}
    })
  end

  defp approve(state, outbound_id) do
    Server.handle_message(
      %{
        "jsonrpc" => "2.0",
        "id" => outbound_id,
        "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}
      },
      state
    )
  end

  defp assert_conforms(result) do
    assert SchemaConformance.ext_def_problems("A2uiActionResult", result) == []
  end

  describe "the up-front authorization check on extension writes" do
    test "a write the actor's policies refuse answers failed/forbidden with no permission request" do
      FakeHost.set_actor(nil)
      FakeHost.set_permission_mode({:pending, "never-used"})
      FakeHost.set_request_probe(self())

      {response, notifications, state} = act(with_session(), "restricted", %{"text" => "x"})

      assert notifications == []
      refute_received {:permission_requested, _}
      assert state.pending_permissions == %{}

      result = response["result"]
      assert result["outcome"] == "failed"
      assert result["error"]["kind"] == "forbidden"
      assert is_binary(result["error"]["message"])
      assert_conforms(result)
    end

    test "the handler learns the denial came from policy, not from a person" do
      FakeHost.set_actor(nil)

      config = FakeHost.config(ext_methods: AshAcp.A2uiActionOutcomeTest.DeniedBy)
      {_, _, state} = call(Server.new(config), "session/new", %{"cwd" => "/tmp"}, 2)

      {response, [], _} = call(state, "_x/guarded_write", %{"sessionId" => "sess-1"})

      assert response["result"] == %{"permission" => "denied", "denied_by" => "policy"}
    end

    test "a spec the check cannot evaluate falls back to the approval seam" do
      FakeHost.set_actor(nil)
      FakeHost.set_permission_mode({:pending, "ref-1"})

      config = FakeHost.config(ext_methods: AshAcp.A2uiActionOutcomeTest.DeniedBy)
      {_, _, state} = call(Server.new(config), "session/new", %{"cwd" => "/tmp"}, 2)

      # not an Ash resource: the up-front check raises, which means "cannot
      # tell" — the client is asked, exactly as before the check existed
      {nil, [outbound], _} = call(state, "_x/unknowable_write", %{"sessionId" => "sess-1"})
      assert outbound["method"] == "session/request_permission"
    end

    test "an update with no record is not checked up front: its owner is still asked" do
      # Judged against a blank Note, `owner == ^actor(:name)` is false for
      # everyone; without the record the check must not decide at all.
      FakeHost.set_actor(%{name: "pat"})
      FakeHost.set_permission_mode({:pending, "ref-1"})

      config = FakeHost.config(ext_methods: AshAcp.A2uiActionOutcomeTest.DeniedBy)
      {_, _, state} = call(Server.new(config), "session/new", %{"cwd" => "/tmp"}, 2)

      {nil, [outbound], _} = call(state, "_x/edit", %{"sessionId" => "sess-1"})
      assert outbound["method"] == "session/request_permission"
    end

    test "an update is checked against the record the host names" do
      FakeHost.set_actor(%{name: "pat"})
      FakeHost.set_permission_mode({:pending, "ref-1"})

      config = FakeHost.config(ext_methods: AshAcp.A2uiActionOutcomeTest.DeniedBy)
      {_, _, state} = call(Server.new(config), "session/new", %{"cwd" => "/tmp"}, 2)

      # their own note: allowed, so the approval seam decides
      {nil, [outbound], _} = call(state, "_x/edit", %{"sessionId" => "sess-1", "owner" => "pat"})
      assert outbound["method"] == "session/request_permission"

      # someone else's: refused up front, nobody asked
      {response, [], _} = call(state, "_x/edit", %{"sessionId" => "sess-1", "owner" => "sam"})
      assert response["result"] == %{"permission" => "denied", "denied_by" => "policy"}
    end

    test "an authorized write still goes through the host's approval seam" do
      FakeHost.set_permission_mode({:pending, "ref-1"})
      FakeHost.set_request_probe(self())

      {nil, [outbound], _} = act(with_session(), "restricted", %{"text" => "x"})

      assert outbound["method"] == "session/request_permission"
      assert_received {:permission_requested, %{action: :restricted}}
    end

    test "a denial by the host seam or the client is still `denied`" do
      FakeHost.set_permission_mode({:denied})
      {response, [], _} = act(with_session(), "publish", %{"text" => "x"})
      assert response["result"]["outcome"] == "denied"
      assert_conforms(response["result"])
    end
  end

  describe "the failed outcome" do
    test "an invalid write answers failed/invalid, naming fields but never values" do
      FakeHost.set_permission_mode({:pending, "ref-1"})

      {nil, [%{"id" => id}], state} = act(with_session(), "publish", %{"text" => ""})
      {response, _notifications, _} = approve(state, id)

      result = response["result"]
      assert result["outcome"] == "failed"
      assert result["error"]["kind"] == "invalid"
      assert result["error"]["message"] =~ "text"
      assert_conforms(result)
    end

    test "an errored write answers failed/error with a generic message" do
      FakeHost.set_permission_mode({:approved, nil})

      {response, _, _} = act(with_session(), "flaky")

      result = response["result"]
      assert result["outcome"] == "failed"
      assert result["error"]["kind"] == "error"
      refute result["error"]["message"] =~ "secret-detail"
      assert_conforms(result)
    end

    test "a write approved but forbidden at execution answers failed/forbidden" do
      FakeHost.set_permission_mode({:pending, "ref-1"})
      {nil, [%{"id" => id}], state} = act(with_session(), "gated", %{"text" => "x"})

      # the grant is gone by the time the client approves
      FakeHost.set_gate(false)

      {response, notifications, _} = approve(state, id)

      assert response["result"]["outcome"] == "failed"
      assert response["result"]["error"]["kind"] == "forbidden"
      assert_conforms(response["result"])

      # the pending tool call the client rendered is settled as failed
      assert Enum.any?(notifications, fn n ->
               get_in(n, ["params", "update", "status"]) == "failed"
             end)
    end
  end

  describe "AshAcp.ExtMethods.action_failed/2" do
    test "classifies Ash errors by class and keeps messages free of values and traces" do
      {:error, forbidden} =
        FakeHost.Note
        |> Ash.ActionInput.for_action(:restricted, %{text: "secret-value"})
        |> Ash.run_action(actor: nil, authorize?: true)

      {:error, invalid} =
        FakeHost.Note
        |> Ash.ActionInput.for_action(:publish_bulletin, %{text: ""})
        |> Ash.run_action(actor: :operator, authorize?: true)

      {:error, errored} =
        FakeHost.Note
        |> Ash.ActionInput.for_action(:flaky, %{})
        |> Ash.run_action(actor: :operator, authorize?: true)

      for {error, kind} <- [{forbidden, "forbidden"}, {invalid, "invalid"}, {errored, "error"}] do
        result = AshAcp.ExtMethods.action_failed(error, [])
        assert result["outcome"] == "failed"
        assert result["error"]["kind"] == kind
        assert result["a2ui"] == []
        refute result["error"]["message"] =~ "secret"
        refute result["error"]["message"] =~ ".ex:"
        assert_conforms(result)
      end
    end

    test "accepts a bare kind, an arbitrary error term, and carries the a2ui payload" do
      status = %{"version" => "v0.9.1", "updateDataModel" => %{"surfaceId" => "s"}}

      assert %{"error" => %{"kind" => "forbidden"}, "a2ui" => [^status]} =
               AshAcp.ExtMethods.action_failed(:forbidden, [status])

      assert %{"error" => %{"kind" => "invalid"}} = AshAcp.ExtMethods.action_failed(:invalid)
      assert %{"error" => %{"kind" => "error"}} = AshAcp.ExtMethods.action_failed({:boom, "pw"})

      refute inspect(AshAcp.ExtMethods.action_failed({:boom, "pw"})) =~ "pw"
    end
  end

  describe "the published schema" do
    test "failed requires an error; applied and denied carry none; errors carry no extras" do
      error = %{"kind" => "forbidden", "message" => "You are not allowed to do this."}

      assert SchemaConformance.ext_def_problems("A2uiActionResult", %{
               "outcome" => "failed",
               "error" => error,
               "a2ui" => []
             }) == []

      refute SchemaConformance.ext_def_problems("A2uiActionResult", %{
               "outcome" => "failed",
               "a2ui" => []
             }) == []

      refute SchemaConformance.ext_def_problems("A2uiActionResult", %{
               "outcome" => "applied",
               "error" => error,
               "a2ui" => []
             }) == []

      refute SchemaConformance.ext_def_problems("A2uiActionResult", %{
               "outcome" => "failed",
               "error" => Map.put(error, "record", %{"ssn" => "x"}),
               "a2ui" => []
             }) == []

      refute SchemaConformance.ext_def_problems("A2uiActionResult", %{
               "outcome" => "failed",
               "error" => %{"kind" => "teapot", "message" => "x"},
               "a2ui" => []
             }) == []
    end
  end
end

defmodule AshAcp.A2uiActionOutcomeTest.DeniedBy do
  @moduledoc false
  @behaviour AshAcp.ExtMethods

  @impl true
  def methods, do: ["_x/guarded_write", "_x/unknowable_write", "_x/edit"]

  @impl true
  def handle("_x/guarded_write", _params, %{permission: nil}) do
    {:request_permission,
     %{title: "Guarded write", resource: FakeHost.Note, action: :restricted, inputs: %{text: "x"}}}
  end

  def handle("_x/edit", params, %{permission: nil}) do
    spec = %{title: "Edit", resource: FakeHost.Note, action: :edit_note, inputs: %{title: "t"}}

    case params["owner"] do
      nil -> {:request_permission, spec}
      owner -> {:request_permission, Map.put(spec, :record, %FakeHost.Note{owner: owner})}
    end
  end

  def handle("_x/unknowable_write", _params, %{permission: nil}) do
    {:request_permission, %{title: "Unknowable", resource: NotAResource, action: :nope}}
  end

  def handle(_method, _params, ctx) do
    {:ok, %{permission: to_string(ctx.permission), denied_by: to_string(ctx.denied_by)}}
  end
end

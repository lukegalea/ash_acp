# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.KindResolverTest do
  @moduledoc """
  The optional `kind_resolver:` seam. Without it every kind is the library
  default (the golden fixtures in `fixtures_test.exs` are the byte-for-byte
  record). With it, the host names the kind of an action whose spec does
  not; a spec's own `:kind` still wins. A resolver that returns nil falls
  back to the default; one that returns something that is not an ACP tool
  kind, or raises, fails the request with -32603 and the action never runs.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias AshAcp.KindResolver
  alias AshAcp.Server

  defmodule DeleteResolver do
    @behaviour AshAcp.KindResolver
    @impl true
    def kind(FakeHost.Note, _action), do: :delete
    def kind(_resource, _action), do: nil
  end

  defmodule NilResolver do
    @behaviour AshAcp.KindResolver
    @impl true
    def kind(_resource, _action), do: nil
  end

  defmodule StringResolver do
    @behaviour AshAcp.KindResolver
    @impl true
    def kind(_resource, _action), do: "edit"
  end

  defmodule UnknownKindResolver do
    @behaviour AshAcp.KindResolver
    @impl true
    def kind(_resource, _action), do: :launch
  end

  defmodule NotAKindResolver do
    @behaviour AshAcp.KindResolver
    @impl true
    def kind(_resource, _action), do: {:ok, :read}
  end

  defmodule RaisingResolver do
    @behaviour AshAcp.KindResolver
    @impl true
    def kind(_resource, _action), do: raise("effects declaration unavailable")
  end

  setup do
    FakeHost.start()
    :ok
  end

  defp call(state, method, params, id) do
    Server.handle_message(
      %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params},
      state
    )
  end

  defp session(overrides) do
    {_, _, state} =
      call(Server.new(FakeHost.config(overrides)), "session/new", %{"cwd" => "/tmp"}, 2)

    state
  end

  defp prompt(state, mode) do
    FakeHost.set_prompt_mode({:ok, mode})

    call(
      state,
      "session/prompt",
      %{"sessionId" => "sess-1", "prompt" => [%{"type" => "text", "text" => "go"}]},
      3
    )
  end

  defp tool_call_kind(notifications) do
    notifications
    |> Enum.find(&(get_in(&1, ["params", "update", "sessionUpdate"]) == "tool_call"))
    |> get_in(["params", "update", "kind"])
  end

  defp permission_kind(notifications) do
    notifications
    |> Enum.find(&(&1["method"] == "session/request_permission"))
    |> get_in(["params", "toolCall", "kind"])
  end

  describe "without a resolver" do
    test "a generic action without a spec kind is execute" do
      {_, notifications, _} = prompt(session([]), :restricted)
      assert tool_call_kind(notifications) == "execute"
    end

    test "a read action without a spec kind is read" do
      FakeHost.set_notes([])
      {_, notifications, _} = prompt(session([]), :list_notes)
      assert tool_call_kind(notifications) == "read"
    end
  end

  describe "with a resolver" do
    test "names the kind of a prompt action whose spec does not" do
      {_, notifications, _} = prompt(session(kind_resolver: DeleteResolver), :restricted)
      assert tool_call_kind(notifications) == "delete"
    end

    test "overrides the read default too" do
      FakeHost.set_notes([])
      {_, notifications, _} = prompt(session(kind_resolver: StringResolver), :list_notes)
      assert tool_call_kind(notifications) == "edit"
    end

    test "labels the permission request it puts to the client" do
      FakeHost.set_permission_mode({:pending, "ref-1"})
      {response, notifications, _} = prompt(session(kind_resolver: DeleteResolver), :restricted)

      assert response == nil
      assert permission_kind(notifications) == "delete"
    end

    test "never overrides a kind the spec sets" do
      {_, notifications, _} = prompt(session(kind_resolver: DeleteResolver), :publish)
      assert tool_call_kind(notifications) == "execute"
    end

    test "returning nil keeps the library default" do
      FakeHost.set_notes([])
      {_, generic, _} = prompt(session(kind_resolver: NilResolver), :restricted)
      {_, read, _} = prompt(session(kind_resolver: NilResolver), :list_notes)

      assert tool_call_kind(generic) == "execute"
      assert tool_call_kind(read) == "read"
    end

    test "labels an extension method's permission request that names its action" do
      FakeHost.set_permission_mode({:pending, "ref-2"})

      {response, notifications, _} =
        call(
          session(kind_resolver: DeleteResolver),
          "_a2ui/action",
          %{
            "sessionId" => "sess-1",
            "surfaceId" => "notes",
            "action" => %{"name" => "publish", "context" => %{"text" => "x"}}
          },
          10
        )

      assert response == nil
      assert permission_kind(notifications) == "delete"
    end
  end

  describe "a resolver outside its contract never runs the action" do
    for {resolver, label} <- [
          {UnknownKindResolver, "an unknown kind"},
          {NotAKindResolver, "a value that is not a kind"},
          {RaisingResolver, "a raise"}
        ] do
      test "#{label} fails the prompt with -32603 and no tool call" do
        FakeHost.set_permission_mode({:approved, nil})
        FakeHost.set_request_probe(self())

        {response, notifications, _} =
          prompt(session(kind_resolver: unquote(resolver)), :restricted)

        assert response["error"]["code"] == -32603
        assert notifications == []
        refute_received {:permission_requested, _}
      end
    end
  end

  describe "resolve/4" do
    test "no resolver, or no resource and action, is the default" do
      assert KindResolver.resolve(nil, FakeHost.Note, :summarize, :read) == :read
      assert KindResolver.resolve(DeleteResolver, nil, :summarize, :execute) == :execute
      assert KindResolver.resolve(DeleteResolver, FakeHost.Note, nil, :execute) == :execute
    end

    test "the accepted kinds are exactly the pinned schema's ToolKind values" do
      schema = "priv/acp_schema/schema.json" |> File.read!() |> Jason.decode!()

      schema_kinds =
        schema |> get_in(["$defs", "ToolKind", "oneOf"]) |> Enum.map(& &1["const"])

      assert Enum.sort(KindResolver.tool_kinds()) == Enum.sort(schema_kinds)
    end

    test "an unknown kind raises, naming the resolver" do
      assert_raise ArgumentError, ~r/UnknownKindResolver.kind\/2 must return/, fn ->
        KindResolver.resolve(UnknownKindResolver, FakeHost.Note, :summarize, :read)
      end
    end
  end
end

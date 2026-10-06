# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule FakeHost.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource FakeHost.Note
  end
end

defmodule FakeHost.Note do
  @moduledoc """
  The fake host's one resource: Simple data layer (no Postgres), policy
  authorizer backed by simple_sat. `summarize` is anyone's action;
  `restricted` requires an actor — that is the whole authorization surface
  the tests exercise.
  """
  use Ash.Resource,
    domain: FakeHost.Domain,
    data_layer: Ash.DataLayer.Simple,
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
    attribute :body, :string, public?: true
  end

  actions do
    action :summarize, :string do
      description "Summarize the given text"
      argument :text, :string, allow_nil?: false

      run fn input, _context ->
        {:ok, "Summary: " <> input.arguments.text}
      end
    end

    action :publish_bulletin, :string do
      description "Publish a bulletin to the whole org"
      argument :text, :string, allow_nil?: false

      run fn input, _context ->
        {:ok, "Bulletin published: " <> input.arguments.text}
      end
    end

    action :restricted, :string do
      description "Only actors may run this"
      argument :text, :string, allow_nil?: false

      run fn _input, _context ->
        {:ok, "restricted ok"}
      end
    end
  end

  policies do
    policy action(:restricted) do
      authorize_if actor_present()
    end

    policy always() do
      authorize_if always()
    end
  end
end

defmodule FakeHost do
  @moduledoc """
  ETS-coordinated fake implementations of every `AshAcp` host seam. Each test
  calls `FakeHost.start/0` in setup and steers behaviour through
  `FakeHost.set_prompt_mode/1` / `FakeHost.set_permission_mode/1`.
  """

  @table :fake_host_acp

  # == lifecycle =============================================================

  def start do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public])
    end

    :ets.insert(@table, [
      {:counter, 0},
      {:actor, :operator},
      {:prompt_mode, {:ok, :summarize}},
      {:permission_mode, {:approved, nil}},
      {:surface, %{"type" => "list", "title" => "Notes"}},
      {:blocked, false},
      {:released, false}
    ])

    :ok
  end

  def release_blocked do
    :ets.insert(@table, {:released, true})
  end

  @doc "Config for `AshAcp.Server.new/1` wired to the fakes."
  def config(overrides \\ []) do
    [
      session_store: FakeHost.SessionStore,
      prompt_target: FakeHost.PromptTarget,
      permission_request: FakeHost.PermissionRequest,
      surface_provider: FakeHost.SurfaceProvider,
      agent_info: %{name: "fake_host", version: "1.0.0", title: "Fake Host"},
      candidate_actions: [
        {FakeHost.Note, :summarize},
        {FakeHost.Note, :restricted}
      ]
    ]
    |> Keyword.merge(overrides)
    |> Map.new()
  end

  # == knobs =================================================================

  def set_actor(actor), do: :ets.insert(@table, {:actor, actor})
  def set_prompt_mode(mode), do: :ets.insert(@table, {:prompt_mode, mode})
  def set_permission_mode(mode), do: :ets.insert(@table, {:permission_mode, mode})
  def set_surface(nil), do: :ets.insert(@table, {:surface, nil})
  def set_surface(surface), do: :ets.insert(@table, {:surface, surface})

  def blocked? do
    case :ets.lookup(@table, :blocked) do
      [{:blocked, true}] -> true
      _ -> false
    end
  end

  def mark_blocked, do: :ets.insert(@table, {:blocked, true})

  def wait_released_or_timeout(max \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + max

    do_wait(deadline)
  end

  defp do_wait(deadline) do
    released? =
      case :ets.lookup(@table, :released) do
        [{:released, true}] -> true
        _ -> false
      end

    cond do
      released? ->
        :released

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(5)
        do_wait(deadline)
    end
  end

  def next_session_id do
    n = :ets.update_counter(@table, :counter, 1)
    "sess-#{n}"
  end

  # == AshAcp.SessionStore ===================================================

  defmodule SessionStore do
    @moduledoc false
    @behaviour AshAcp.SessionStore

    @impl true
    def create(init) do
      session = %{
        session_id: FakeHost.next_session_id(),
        actor: FakeHost.current_actor(),
        cwd: init["cwd"],
        messages: []
      }

      :ets.insert(FakeHost.table(), {{:session, session.session_id}, session})
      {:ok, session}
    end

    @impl true
    def load(session_id) do
      case :ets.lookup(FakeHost.table(), {:session, session_id}) do
        [{_key, session}] -> {:ok, session}
        [] -> {:error, :not_found}
      end
    end

    @impl true
    def append_message(session, role, text) do
      new = %{session | messages: session.messages ++ [%{role: role, text: text}]}
      :ets.insert(FakeHost.table(), {{:session, session.session_id}, new})
      {:ok, new}
    end

    @impl true
    def close(_session_id), do: :ok
  end

  def current_actor do
    :ets.lookup_element(@table, :actor, 2)
  end

  def table, do: @table

  # == AshAcp.PromptTarget ===================================================

  defmodule PromptTarget do
    @moduledoc false
    @behaviour AshAcp.PromptTarget

    @impl true
    def resolve(_session_id, prompt_text, _ctx) do
      case :ets.lookup_element(FakeHost.table(), :prompt_mode, 2) do
        {:ok, :summarize} ->
          {:ok,
           %{
             resource: FakeHost.Note,
             action: :summarize,
             inputs: %{text: prompt_text},
             title: "Summarize",
             kind: :read
           }}

        {:ok, :publish} ->
          {:ok,
           %{
             resource: FakeHost.Note,
             action: :publish_bulletin,
             inputs: %{text: prompt_text},
             title: "Publish bulletin",
             kind: :execute
           }}

        {:ok, :restricted} ->
          {:ok,
           %{
             resource: FakeHost.Note,
             action: :restricted,
             inputs: %{text: prompt_text},
             title: "Restricted op"
           }}

        {:ok, :unresolvable} ->
          {:error, :no_action_matches}

        :block ->
          FakeHost.mark_blocked()

          case FakeHost.wait_released_or_timeout() do
            :released -> {:error, :released_mid_turn}
            :timeout -> {:error, :blocked_past_timeout}
          end
      end
    end
  end

  # == AshAcp.PermissionRequest =============================================

  defmodule PermissionRequest do
    @moduledoc false
    @behaviour AshAcp.PermissionRequest

    @impl true
    def request(_session, _action_spec, _inputs) do
      :ets.lookup_element(FakeHost.table(), :permission_mode, 2)
    end

    @impl true
    def resolve(_request_ref, outcome, _session) do
      AshAcp.PermissionRequest.default_resolve(nil, outcome)
    end
  end

  # == AshAcp.SurfaceProvider ===============================================

  defmodule SurfaceProvider do
    @moduledoc false
    @behaviour AshAcp.SurfaceProvider

    @impl true
    def surface(_session, _meta) do
      :ets.lookup_element(FakeHost.table(), :surface, 2)
    end
  end
end

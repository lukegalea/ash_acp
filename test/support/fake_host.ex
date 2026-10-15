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

defmodule FakeHost.GateOpen do
  @moduledoc """
  A simple check whose answer the test steers (`FakeHost.set_gate/1`):
  authorization that changes between the up-front `Ash.can?` and the run —
  a revoked grant, say.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the fake host's gate is open"

  @impl true
  def match?(_actor, _context, _opts), do: FakeHost.gate_open?()
end

defmodule FakeHost.Note do
  @moduledoc """
  The fake host's one resource: Simple data layer (no Postgres), policy
  authorizer backed by simple_sat. `summarize` is anyone's action;
  `restricted` requires an actor; `gated` follows `FakeHost.GateOpen` —
  that is the whole authorization surface the tests exercise.
  """
  use Ash.Resource,
    domain: FakeHost.Domain,
    data_layer: Ash.DataLayer.Simple,
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
    attribute :body, :string, public?: true

    # money-adjacent columns must serialize as STRINGS — a float round-trip
    # silently changes values (iron law #04)
    attribute :amount, :decimal, public?: true

    # every platform table carries these; they must serialize to ISO8601
    # on the wire (the DateTime row-serialization regression)
    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  actions do
    read :list_notes do
      description "List notes, newest first"

      prepare fn query, _context ->
        FakeHost.note_tenant_probe(query.tenant)
        Ash.DataLayer.Simple.set_data(query, FakeHost.note_records())
      end
    end

    create :create_note do
      description "Create a note (not a v1 ACP surface)"
      accept [:title, :body]
    end

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

    action :gated, :string do
      description "Runs while the fake host's gate is open"
      argument :text, :string, allow_nil?: false

      run fn _input, _context ->
        {:ok, "gated ok"}
      end
    end

    action :flaky, :string do
      description "Always fails (an errored write)"

      run fn _input, _context ->
        {:error, "the bulletin board is down: secret-detail"}
      end
    end
  end

  policies do
    policy action(:restricted) do
      authorize_if actor_present()
    end

    policy action(:gated) do
      authorize_if FakeHost.GateOpen
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
      {:tenant_probe, nil},
      {:auth_actor, :operator},
      {:blocked, false},
      {:released, false},
      {:gate, true},
      {:request_probe, nil}
    ])

    :ok
  end

  @doc "Registers a pid that receives {:tenant, tenant} whenever a fake read runs."
  def set_tenant_probe(pid), do: :ets.insert(@table, {:tenant_probe, pid})

  @doc "Seeds the rows the fake `list_notes` read returns."
  def set_notes(records), do: :ets.insert(@table, {:note_records, records})

  @doc false
  def note_records do
    case :ets.lookup(@table, :note_records) do
      [{:note_records, records}] -> records
      _ -> []
    end
  end

  @doc false
  def note_tenant_probe(tenant) do
    case :ets.lookup(@table, :tenant_probe) do
      [{:tenant_probe, nil}] -> :ok
      [{:tenant_probe, pid}] when is_pid(pid) -> send(pid, {:tenant, tenant})
      _ -> :ok
    end

    :ok
  end

  @doc "Opens or closes the `FakeHost.GateOpen` check."
  def set_gate(open?) when is_boolean(open?), do: :ets.insert(@table, {:gate, open?})

  @doc false
  def gate_open? do
    case :ets.lookup(@table, :gate) do
      [{:gate, open?}] -> open?
      _ -> true
    end
  end

  @doc """
  Registers a pid that receives `{:permission_requested, spec}` whenever the
  fake `AshAcp.PermissionRequest.request/3` is called.
  """
  def set_request_probe(pid), do: :ets.insert(@table, {:request_probe, pid})

  @doc false
  def probe_request(spec) do
    case :ets.lookup(@table, :request_probe) do
      [{:request_probe, pid}] when is_pid(pid) -> send(pid, {:permission_requested, spec})
      _ -> :ok
    end
  end

  @doc """
  The command palette computed at runtime — what a host whose palette is
  derived from a registry passes as `candidate_actions: {FakeHost,
  :candidate_actions, []}`.
  """
  def candidate_actions, do: [{FakeHost.Note, :summarize}, {FakeHost.Note, :restricted}]

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
      ext_methods: FakeHost.ExtMethods,
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
        actor: init["actor"] || FakeHost.current_actor(),
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

    @impl true
    def list(filter) do
      send_probe({:list_filter, filter})

      sessions =
        FakeHost.table()
        |> :ets.match_object({{:session, :_}, :_})
        |> Enum.map(fn {_key, session} -> session end)
        |> Enum.filter(&(is_nil(filter["cwd"]) or &1.cwd == filter["cwd"]))
        |> Enum.sort_by(& &1.session_id)
        |> Enum.map(
          &Map.merge(&1, %{
            title: "Session #{&1.session_id}",
            updated_at: ~U[2026-10-12 09:00:00Z]
          })
        )

      {:ok, sessions, nil}
    end

    defp send_probe(message) do
      case :ets.lookup(FakeHost.table(), :tenant_probe) do
        [{:tenant_probe, pid}] when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  def current_actor do
    :ets.lookup_element(@table, :actor, 2)
  end

  def table, do: @table

  # == AshAcp.Authenticator ==================================================

  def set_auth_actor(actor), do: :ets.insert(@table, {:auth_actor, actor})

  def current_auth_actor do
    case :ets.lookup(@table, :auth_actor) do
      [{:auth_actor, actor}] -> actor
      _ -> :operator
    end
  end

  defmodule Authenticator do
    @moduledoc false
    @behaviour AshAcp.Authenticator

    @impl true
    def authenticate(_params), do: {:ok, FakeHost.current_auth_actor()}
  end

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

        {:ok, :list_notes} ->
          {:ok,
           %{
             resource: FakeHost.Note,
             action: :list_notes,
             inputs: %{},
             title: "List notes"
           }}

        {:ok, :tenant_read} ->
          {:ok,
           %{
             resource: FakeHost.Note,
             action: :list_notes,
             inputs: %{},
             title: "List notes (tenanted)",
             tenant: "acme"
           }}

        {:ok, :create_note} ->
          {:ok,
           %{
             resource: FakeHost.Note,
             action: :create_note,
             inputs: %{title: "x"},
             title: "Create note"
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

        {:ok, :gated} ->
          {:ok,
           %{
             resource: FakeHost.Note,
             action: :gated,
             inputs: %{text: prompt_text},
             title: "Gated op",
             kind: :execute
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
    def request(_session, action_spec, _inputs) do
      FakeHost.probe_request(action_spec)
      :ets.lookup_element(FakeHost.table(), :permission_mode, 2)
    end

    @impl true
    def resolve(_request_ref, outcome, _session) do
      AshAcp.PermissionRequest.default_resolve(nil, outcome)
    end
  end

  # == AshAcp.ExtMethods ====================================================

  defmodule ExtMethods do
    @moduledoc """
    The `ash` extension conventions over the fake note resource:

    * `_ash/surfaces/list` — `notes` for everyone, `restricted` only when
      `Ash.can?/3` lets the actor run `FakeHost.Note.restricted`;
    * `_ash/surface/open` — `notes` opens; anything else is `-32602`;
    * `_a2ui/action` — `refresh` applies at once; `publish`, `restricted`,
      `gated` and `flaky` are consequential writes: `{:request_permission, spec}`,
      then the action runs as the actor with `authorize?: true`. A refused,
      invalid or errored run answers `outcome: "failed"`
      (`AshAcp.ExtMethods.action_failed/2`); a policy refusal decided up
      front (`denied_by: :policy`) too; a denied approval answers `denied`.
    """
    @behaviour AshAcp.ExtMethods

    # the consequential A2UI actions, by name -> the Note action they run
    @writes %{
      "publish" => :publish_bulletin,
      "restricted" => :restricted,
      "gated" => :gated,
      "flaky" => :flaky
    }

    @impl true
    def methods, do: AshAcp.ExtMethods.conventional_methods()

    @impl true
    def capabilities(ctx), do: %{"surfaces" => surfaces(ctx.actor)}

    @impl true
    def handle("_ash/surfaces/list", _params, ctx),
      do: {:ok, %{"surfaces" => surfaces(ctx.actor)}}

    def handle("_ash/surface/open", %{"surface" => "notes"} = params, _ctx) do
      {:ok, %{"surfaceId" => "notes", "a2ui" => open_messages(params["recordId"])}}
    end

    def handle("_ash/surface/open", %{"surface" => other}, _ctx) do
      {:error, -32602, "Invalid params", %{"reason" => "unknown surface #{inspect(other)}"}}
    end

    def handle("_a2ui/action", %{"action" => %{"name" => "refresh"}} = params, _ctx) do
      {:ok, %{"outcome" => "applied", "a2ui" => [status(params["surfaceId"], "refreshed")]}}
    end

    def handle("_a2ui/action", %{"action" => %{"name" => name}} = params, ctx)
        when is_map_key(@writes, name) do
      action = Map.fetch!(@writes, name)
      inputs = write_inputs(action, get_in(params, ["action", "context", "text"]))
      surface_id = params["surfaceId"]

      case ctx.permission do
        nil ->
          {:request_permission,
           %{
             resource: FakeHost.Note,
             action: action,
             title: "#{String.capitalize(name)} bulletin",
             inputs: inputs
           }}

        {:approved, _approval} ->
          FakeHost.Note
          |> Ash.ActionInput.for_action(action, inputs)
          |> Ash.run_action(actor: ctx.actor, authorize?: true)
          |> case do
            {:ok, text} ->
              {:ok, %{"outcome" => "applied", "a2ui" => [status(surface_id, text)]},
               [AshAcp.Updates.agent_message(text)]}

            {:error, error} ->
              {:ok, AshAcp.ExtMethods.action_failed(error, [status(surface_id, "failed")])}
          end

        :denied when ctx.denied_by == :policy ->
          {:ok, AshAcp.ExtMethods.action_failed(:forbidden, [status(surface_id, "not allowed")])}

        :denied ->
          {:ok, %{"outcome" => "denied", "a2ui" => [status(surface_id, "denied")]}}
      end
    end

    def handle("_a2ui/action", %{"action" => %{"name" => "explode"}}, _ctx), do: :not_a_result

    def handle("_a2ui/action", _params, _ctx), do: {:error, :unknown_action}

    defp write_inputs(:flaky, _text), do: %{}
    defp write_inputs(_action, text), do: %{text: text || ""}

    defp surfaces(actor) do
      notes = %{"id" => "notes", "title" => "Notes", "group" => "Workspace"}

      restricted = %{
        "id" => "restricted",
        "title" => "Restricted",
        "description" => "Actors only",
        "recordScoped" => true
      }

      if Ash.can?({FakeHost.Note, :restricted}, actor),
        do: [notes, restricted],
        else: [notes]
    end

    defp open_messages(record_id) do
      [
        %{
          "version" => "v0.9.1",
          "createSurface" => %{"surfaceId" => "notes", "catalogId" => "fake"}
        },
        %{
          "version" => "v0.9.1",
          "updateDataModel" => %{
            "surfaceId" => "notes",
            "path" => "/",
            "value" => %{"recordId" => record_id}
          }
        }
      ]
    end

    defp status(surface_id, text) do
      %{
        "version" => "v0.9.1",
        "updateDataModel" => %{"surfaceId" => surface_id, "path" => "/ui/status", "value" => text}
      }
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

# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.Server do
  @moduledoc """
  The pure ACP protocol core.

  `handle_message/2` maps one decoded JSON-RPC message to

      {response :: map() | nil, notifications :: [map()], new_state :: t()}

  with **no IO whatsoever** — both `AshAcp.Endpoint` (stdio) and `AshAcp.Plug`
  (HTTP) are thin shells over it, and the whole protocol is testable without a
  process. `notifications` may contain `session/update` notifications and
  `session/request_permission` *requests* (server→client requests carry an id
  and expect a response; the transports write both shapes verbatim, in order,
  before the response of the turn).

  `handle_message/2` never raises: a crash inside any seam callback or during
  action execution is converted into a JSON-RPC `-32603` error for the
  offending request plus a `Logger.error` with the stacktrace, so a buggy
  host integration cannot hang a client.

  ## Method map (ACP v1, `AshAcp.acp_version/0`)

  | Message | Behaviour seam touched |
  |---|---|
  | `initialize` | optional `AshAcp.Authenticator.authenticate/1` |
  | `session/new` | `AshAcp.Authenticator` (optional), `AshAcp.SessionStore.create/1` |
  | `session/load` | `AshAcp.Authenticator` (optional), `AshAcp.SessionStore.load/1`, transcript replay, then commands + last surface |
  | `session/list` | `AshAcp.SessionStore.list/1` (optional; advertised as `sessionCapabilities.list`) |
  | `session/prompt` | `AshAcp.PromptTarget`, `AshAcp.PermissionRequest`, `AshAcp.SurfaceProvider`, `Ash.read/2` or `Ash.run_action/2` (`authorize?: true`), `Ash.can?/3` |
  | `session/cancel` | none (answers the in-flight prompt with `stopReason: "cancelled"`) |
  | `_`-prefixed extension methods | `AshAcp.ExtMethods.handle/3` (optional), `AshAcp.PermissionRequest` for consequential ones |
  | client responses to our `session/request_permission` | `AshAcp.PermissionRequest.resolve/3` |

  Every `available_commands_update` (after `session/new`, after the
  `session/load` replay, and closing each prompt turn) carries the
  `Ash.can?/3`-pruned commands and — when `AshAcp.SurfaceProvider` returns
  one — the A2UI surface under `update._meta.a2ui`. The commands come from
  the `candidate_actions` config: a list, or an `{m, f, a}` / zero-arity
  function evaluated whenever a palette is built, for hosts that derive the
  palette at runtime — the shape `mix ash_acp.stdio` can carry, since it
  configures the server from app env alone.

  A prompt turn that needs approval **stays open**: `session/request_permission`
  goes out with no prompt response, and the prompt's response is only sent
  when the client resolves the request — `end_turn` with the action's content
  after approval, `refusal` after denial, `-32603` if a seam violates its
  contract, or `cancelled` if the client cancels the turn meanwhile.

  ## Policy refusals are never put to the client

  Before the approval seam is consulted, the action is checked with
  `Ash.can/3` — the session actor, the spec's `tenant`, and the same action
  input or query the run will use (`maybe_is: :maybe`, `run_queries?:
  false`). A definite `false` ends the turn `refusal` with a failed
  `"Not permitted"` tool call update: `AshAcp.PermissionRequest.request/3`
  is not called and no `session/request_permission` goes out, because no
  approval could make the run succeed. `:maybe`, an error or a raise means
  "cannot tell up front" and the flow continues exactly as before. The check
  only spares the client a pointless prompt — the run itself is still
  authorized (`authorize?: true`), and a refusal there (authorization that
  changed while an approval was pending) ends the turn the same way, without
  asking again. Consequential extension calls get the same check (see
  `AshAcp.ExtMethods`).

  ## Action dispatch

  The action a `AshAcp.PromptTarget` resolves is run according to its type:

  * `:read` — `Ash.Query.for_read/3` + `Ash.read/2` (actor, `authorize?: true`,
    optional `tenant`). The result streams as a `session/update` carrying the
    first `@max_read_rows` rows as JSON plus the total count. Row fields are
    the resource's public attributes, overridable with `row_fields:` on the
    action spec.
  * `:action` — `Ash.ActionInput.for_action/3` + `Ash.run_action/2`.
  * `:create`, `:update`, `:destroy` — not v1 surfaces; answered with a
    `-32603` wire error rather than a host crash.

  Contract-violating returns from `AshAcp.PermissionRequest.request/3` or
  `resolve/3` (anything but `{:approved, _} | {:denied}` — with `{:pending, _}`
  additionally allowed for `request/3`) are never swallowed: they fail the
  affected prompt with `-32603` and log a `Logger.error` naming the module.

  The state is connection-scoped bookkeeping only — the session cache,
  in-flight prompt request ids, pending permission requests and the id
  counters. Everything durable lives in the host's `AshAcp.SessionStore`, so a
  transport may rebuild the state per connection at any time.
  """

  alias AshAcp.AvailableActions
  alias AshAcp.JsonRpc
  alias AshAcp.Updates

  require Logger

  defstruct [
    :config,
    actor: nil,
    sessions: %{},
    in_flight: %{},
    pending_permissions: %{},
    tool_call_counter: 0,
    outbound_id_counter: 0
  ]

  @type t :: %__MODULE__{
          config: map(),
          actor: term(),
          sessions: %{String.t() => term()},
          in_flight: %{String.t() => term()},
          pending_permissions: %{term() => map()},
          tool_call_counter: non_neg_integer(),
          outbound_id_counter: non_neg_integer()
        }

  @default_permission_options [
    %{"optionId" => "allow_once", "name" => "Allow once", "kind" => "allow_once"},
    %{"optionId" => "allow_always", "name" => "Allow always", "kind" => "allow_always"},
    %{"optionId" => "reject_once", "name" => "Reject once", "kind" => "reject_once"}
  ]

  @max_read_rows 50

  @doc "Builds the initial state from a config map (the `AshAcp.config/1` shape)."
  @spec new(map()) :: t()
  def new(config), do: %__MODULE__{config: Map.new(config)}

  @doc """
  Handles one decoded JSON-RPC message. Returns `{response, notifications,
  new_state}`; `response` is `nil` for notifications and for client responses
  to our own requests (those are never answered). Never raises — see the
  module documentation.

  Use `handle_line/2` for raw ndjson lines — it layers parse-error handling
  (`-32700`) on top of this function.
  """
  @spec handle_message(map(), t()) :: {map() | nil, [map()], t()}
  def handle_message(message, state) do
    do_handle_message(message, state)
  rescue
    e ->
      Logger.error(fn ->
        "AshAcp: handle_message/2 crashed on #{inspect(Map.get(message, "method"))}: " <>
          Exception.format(:error, e, __STACKTRACE__)
      end)

      {JsonRpc.error(message["id"], -32603, "internal error", %{"reason" => Exception.message(e)}),
       [], state}
  end

  defp do_handle_message(message, state)

  # -- client response to our session/request_permission ---------------------

  defp do_handle_message(%{"id" => id, "result" => result}, %__MODULE__{} = state)
       when is_map_key(state.pending_permissions, id) do
    permission = Map.fetch!(state.pending_permissions, id)

    handle_permission_outcome(permission, result, %{
      state
      | pending_permissions: Map.delete(state.pending_permissions, id)
    })
  end

  # Responses to unknown ids (or errors about our requests) are ignored: the
  # connection state has no pending work to complete.
  defp do_handle_message(%{"id" => _id, "result" => _result}, state), do: {nil, [], state}
  defp do_handle_message(%{"id" => _id, "error" => _error}, state), do: {nil, [], state}

  # -- methods ---------------------------------------------------------------

  defp do_handle_message(%{"method" => "initialize"} = message, state) do
    with_params(message, state, &handle_initialize(&1, &2, &3))
  end

  defp do_handle_message(%{"method" => "session/new"} = message, state) do
    with_params(message, state, &handle_session_new(&1, &2, &3))
  end

  defp do_handle_message(%{"method" => "session/load"} = message, state) do
    with_params(message, state, &handle_session_load(&1, &2, &3))
  end

  defp do_handle_message(%{"method" => "session/list"} = message, state) do
    with_params(message, state, &handle_session_list(&1, &2, &3))
  end

  defp do_handle_message(%{"method" => "session/prompt"} = message, state) do
    with_params(message, state, &handle_session_prompt(&1, &2, &3))
  end

  defp do_handle_message(%{"method" => "session/cancel"} = message, state) do
    params = message["params"] || %{}
    session_id = params["sessionId"]

    case Map.get(state.in_flight, session_id) do
      nil ->
        # Nothing in flight (a late cancel after a finished turn, or an
        # unknown session): per JSON-RPC a notification is never answered.
        {nil, [], state}

      prompt_request_id ->
        # The transport is expected to stop the live prompt task; the
        # response is addressed to the *prompt's* request id, because that is
        # the call the client is still awaiting. Pending permission requests
        # for the session die with the turn.
        response = JsonRpc.response(prompt_request_id, %{"stopReason" => "cancelled"})

        {response, [],
         %{
           state
           | in_flight: Map.delete(state.in_flight, session_id),
             pending_permissions:
               Map.reject(state.pending_permissions, fn {_id, p} ->
                 p.kind == :prompt and p.session_id == session_id
               end)
         }}
    end
  end

  # Extension methods (`_`-prefixed, ACP "Extensibility") the host's
  # `AshAcp.ExtMethods` lists; any other `_` method falls through to -32601.
  defp do_handle_message(%{"method" => "_" <> _ = method} = message, state) do
    handler = Map.get(state.config, :ext_methods)

    if handler && method in ext_method_names(handler) do
      with_params(message, state, &handle_ext(handler, method, &1, &2, &3))
    else
      unknown_method(message, state)
    end
  end

  defp do_handle_message(%{"method" => _method} = message, state) do
    unknown_method(message, state)
  end

  defp do_handle_message(_other, state) do
    {JsonRpc.std_error(nil, -32600), [], state}
  end

  # Unknown method: requests get -32601; notifications are never answered.
  defp unknown_method(message, state) do
    if Map.has_key?(message, "id") do
      {JsonRpc.std_error(message["id"], -32601), [], state}
    else
      {nil, [], state}
    end
  end

  @doc """
  Handles one raw ndjson line: parse errors become `-32700` (with `id: null`,
  since the id cannot be recovered), everything else goes through
  `handle_message/2`. Returns the ordered wire messages to write followed by
  the new state.
  """
  @spec handle_line(String.t(), t()) :: {[map()], t()}
  def handle_line(line, state) do
    case JsonRpc.decode(line) do
      {:error, :parse} ->
        {[JsonRpc.std_error(nil, -32700)], state}

      {:ok, message} ->
        {response, notifications, new_state} = handle_message(message, state)
        {List.wrap(notifications) ++ List.wrap(response), new_state}
    end
  end

  # == parameter plumbing ====================================================

  defp with_params(message, state, fun) do
    case Map.get(message, "params") do
      params when is_map(params) ->
        fun.(params, message, state)

      nil ->
        fun.(%{}, message, state)

      _other ->
        {JsonRpc.std_error(message["id"], -32602, %{"reason" => "params must be an object"}), [],
         state}
    end
  end

  # == authentication ========================================================

  # `{:ok, actor}` admits the message; `{:error, reason}` rejects it with the
  # ACP authentication error. Unconfigured, everything is admitted — the host
  # must then run the server behind a trusted boundary only.
  defp authenticate(params, message, state, fun) do
    case Map.get(state.config, :authenticate) do
      nil ->
        fun.(nil, state)

      module ->
        case module.authenticate(params) do
          {:ok, actor} -> fun.(actor, remember_actor(state, actor))
          {:error, reason} -> auth_required(message, reason, state)
          other -> seam_violation(Map.get(message, "id"), module, "authenticate/1", other, state)
        end
    end
  end

  defp auth_required(message, reason, state) do
    # -32000 is the ACP schema's "Authentication required" error code.
    {JsonRpc.error(message["id"], -32000, "Authentication required", %{
       "reason" => inspect(reason)
     }), [], state}
  end

  # == initialize ============================================================

  defp handle_initialize(params, message, state) do
    authenticate(params, message, state, fn _actor, state ->
      handle_initialize_admitted(params, message, state)
    end)
  end

  defp handle_initialize_admitted(params, message, state) do
    case params["protocolVersion"] do
      version when is_integer(version) ->
        negotiated =
          if version == AshAcp.acp_version() do
            version
          else
            # Exactly one protocol version is implemented; a client that
            # asked for anything else is told our version and may disconnect.
            AshAcp.acp_version()
          end

        ext_meta = ext_meta(state)

        capabilities =
          %{
            "loadSession" => true,
            "promptCapabilities" => %{
              "image" => false,
              "audio" => false,
              "embeddedContext" => false
            },
            "mcpCapabilities" => %{"http" => false, "sse" => false},
            "sessionCapabilities" => session_capabilities(state)
          }
          |> maybe_put("_meta", ext_meta)

        # The `ash` extension advertisement lives in the capability object's
        # `_meta` (where ACP's extensibility guidance puts custom
        # capabilities) and is mirrored at the result's own `_meta`.
        result =
          %{
            "protocolVersion" => negotiated,
            "agentCapabilities" => capabilities,
            "authMethods" => [],
            "agentInfo" => agent_info(state)
          }
          |> maybe_put("_meta", ext_meta)

        {JsonRpc.response(message["id"], result), [], state}

      _other ->
        {JsonRpc.std_error(message["id"], -32602, %{
           "reason" => "protocolVersion (integer) is required"
         }), [], state}
    end
  end

  # == session/new ===========================================================

  defp handle_session_new(params, message, state) do
    authenticate(params, message, state, fn actor, state ->
      handle_session_new_admitted(params, message, actor, state)
    end)
  end

  defp handle_session_new_admitted(params, message, actor, state) do
    init = %{
      "cwd" => params["cwd"],
      "mcpServers" => params["mcpServers"] || [],
      "clientInfo" => params["clientInfo"],
      # the authenticated actor, so the host store records the owner the
      # ownership check on session/load compares against
      "actor" => actor
    }

    case session_store!(state).create(init) do
      {:ok, session} ->
        session = put_actor(session, actor)
        session_id = session_id!(session)

        # The palette (and any opening surface) right away, not only at the
        # first turn's end. It precedes the response, like every update.
        {commands, state} = final_update(state, session, session_id, :session_new)

        {JsonRpc.response(message["id"], %{"sessionId" => session_id}), [commands],
         %{state | sessions: Map.put(state.sessions, session_id, session)}}

      {:error, reason} ->
        {JsonRpc.error(message["id"], -32603, "session could not be created", %{
           "reason" => inspect(reason)
         }), [], state}
    end
  end

  # == session/load ==========================================================

  defp handle_session_load(params, message, state) do
    authenticate(params, message, state, fn actor, state ->
      handle_session_load_admitted(params, message, actor, state)
    end)
  end

  defp handle_session_load_admitted(params, message, actor, state) do
    session_id = params["sessionId"]

    if is_binary(session_id) do
      case fetch_session(state, session_id) do
        {:ok, session, state} ->
          with :ok <- check_session_ownership(session, actor, message) do
            session = put_actor(session, actor)

            replay =
              Enum.map(transcript(session), fn %{role: role, text: text} ->
                Updates.notification(session_id, chunk(role, text))
              end)

            # After the transcript: the commands and the session's last
            # surface, so a resumed client is where it left off.
            {commands, state} = final_update(state, session, session_id, :session_load)

            {JsonRpc.response(message["id"], %{}), replay ++ [commands],
             %{state | sessions: Map.put(state.sessions, session_id, session)}}
          else
            {:error, response} ->
              {response, [], state}
          end

        {:error, reason} ->
          {session_not_found(message["id"], reason), [], state}
      end
    else
      {JsonRpc.std_error(message["id"], -32602, %{"reason" => "sessionId (string) is required"}),
       [], state}
    end
  end

  # Ownership: a session with an owner actor may only be loaded by the same
  # authenticated actor — actor B loading actor A's session is "Resource not
  # found" (-32002), never a transcript leak. Skipped when the connection has
  # no identity (no `AshAcp.Authenticator` configured — the trusted-boundary
  # rule) or when the stored session carries no owner.
  defp check_session_ownership(session, actor, message) do
    if foreign?(session, actor) do
      {:error, foreign_session(message["id"])}
    else
      :ok
    end
  end

  defp foreign?(session, actor) do
    owner = actor_of(session)
    not is_nil(owner) and not is_nil(actor) and owner != actor
  end

  defp foreign_session(request_id) do
    JsonRpc.error(request_id, -32002, "Resource not found", %{
      "reason" => "session belongs to another actor"
    })
  end

  # == session/list ==========================================================

  defp handle_session_list(params, message, state) do
    store = session_store!(state)

    if exports?(store, :list, 1) do
      filter = %{"cwd" => params["cwd"], "cursor" => params["cursor"], "actor" => state.actor}

      case store.list(filter) do
        {:ok, sessions} when is_list(sessions) ->
          {session_list(message["id"], sessions, nil, state), [], state}

        {:ok, sessions, cursor} when is_list(sessions) ->
          {session_list(message["id"], sessions, cursor, state), [], state}

        {:error, reason} ->
          {JsonRpc.error(message["id"], -32603, "sessions could not be listed", %{
             "reason" => inspect(reason)
           }), [], state}

        other ->
          seam_violation(message["id"], store, "list/1", other, state)
      end
    else
      {JsonRpc.std_error(message["id"], -32601), [], state}
    end
  end

  defp session_list(request_id, sessions, cursor, state) do
    infos =
      sessions
      |> Enum.reject(&foreign?(&1, state.actor))
      |> Enum.map(&session_info/1)

    JsonRpc.response(request_id, maybe_put(%{"sessions" => infos}, "nextCursor", cursor))
  end

  defp session_info(session) do
    %{"sessionId" => session_id!(session), "cwd" => to_string(get_key(session, :cwd) || "/")}
    |> maybe_put("title", get_key(session, :title))
    |> maybe_put("updatedAt", iso8601(get_key(session, :updated_at)))
  end

  defp iso8601(nil), do: nil
  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(value), do: stringify(value)

  # == session/prompt ========================================================

  defp handle_session_prompt(params, message, state) do
    with {:ok, session_id, prompt_text} <- extract_prompt(params),
         :ok <- check_not_in_flight(state, session_id) do
      case fetch_owned_session(state, session_id, message["id"]) do
        {:ok, session, state} ->
          state = put_in(state, [Access.key!(:in_flight), session_id], message["id"])
          run_prompt_turn(session, session_id, prompt_text, message["id"], state)

        {:error, response} ->
          {response, [], state}
      end
    else
      {:error, {:invalid_params, reason}} ->
        {JsonRpc.std_error(message["id"], -32602, %{"reason" => reason}), [], state}

      {:error, :in_flight} ->
        {JsonRpc.error(message["id"], -32600, "a prompt is already in progress for this session"),
         [], state}
    end
  end

  defp extract_prompt(params) do
    session_id = params["sessionId"]
    prompt = params["prompt"]

    cond do
      not is_binary(session_id) ->
        {:error, {:invalid_params, "sessionId (string) is required"}}

      not is_list(prompt) or prompt == [] ->
        {:error, {:invalid_params, "prompt (non-empty list of content blocks) is required"}}

      true ->
        text =
          prompt
          |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
          |> Enum.map(& &1["text"])
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        {:ok, session_id, text}
    end
  end

  defp check_not_in_flight(state, session_id) do
    if Map.has_key?(state.in_flight, session_id), do: {:error, :in_flight}, else: :ok
  end

  defp run_prompt_turn(session, session_id, prompt_text, request_id, state) do
    case prompt_target!(state).resolve(session_id, prompt_text, %{"session" => session}) do
      {:ok, spec} ->
        spec = normalize_spec(spec)
        session = record(state, session, :user, prompt_text)

        case precheck(spec, actor_of(session), &prompt_source/1) do
          :forbidden -> forbidden_turn(session, session_id, request_id, state)
          :unknown -> request_approval(session, session_id, spec, request_id, state)
        end

      {:error, reason} ->
        notifications = [
          agent_chunk(session_id, "Prompt could not be mapped to an action: #{inspect(reason)}")
        ]

        record(state, session, :agent, "Prompt could not be mapped to an action.")

        {JsonRpc.response(request_id, %{"stopReason" => "refusal"}), notifications,
         clear_in_flight(state, session_id)}
    end
  end

  # The host's approval seam, for an action the up-front check did not refuse.
  defp request_approval(session, session_id, spec, request_id, state) do
    case permission_request!(state).request(session, spec, spec.inputs) do
      {:approved, approval} ->
        execute_action(session, session_id, spec, request_id, state, approval)

      {:denied} ->
        denied_turn(session, session_id, spec, request_id, state)

      {:pending, request_ref} ->
        request_permission(session, session_id, spec, request_id, request_ref, state)

      other ->
        {response, notifications, _} =
          seam_violation(request_id, permission_request!(state), "request/3", other, state)

        {response, notifications, clear_in_flight(state, session_id)}
    end
  end

  # A turn whose action Ash's policies refuse the actor — up front, or at
  # execution. No approval is asked for: it could not change the answer.
  # `tool_call_id` is the call already announced, if any.
  defp forbidden_turn(session, session_id, request_id, state, tool_call_id \\ nil) do
    {tool_call_id, state} =
      if tool_call_id, do: {tool_call_id, state}, else: next_tool_call_id(state)

    record(state, session, :agent, "Not permitted.")

    notifications = [
      tool_call_update(session_id, tool_call_id, "failed", %{
        "content" => [tool_content("Not permitted")]
      })
    ]

    response =
      if request_id do
        JsonRpc.response(request_id, %{"stopReason" => "refusal"})
      end

    {response, notifications, clear_in_flight(state, session_id)}
  end

  # == the up-front authorization check =====================================

  # `:forbidden` only when Ash definitely refuses; anything it cannot decide
  # without running queries, any error and any raise (building the source
  # included) is `:unknown`, and the caller carries on as if no check had
  # been made. `source_of` builds what the eventual call will authorize, or
  # nil when there is nothing to check.
  defp precheck(spec, actor, source_of) do
    case source_of.(spec) do
      nil ->
        :unknown

      source ->
        opts = put_tenant([maybe_is: :maybe, run_queries?: false], Map.get(spec, :tenant))

        case Ash.can(source, actor, opts) do
          {:ok, false} -> :forbidden
          {:ok, false, _} -> :forbidden
          _other -> :unknown
        end
    end
  rescue
    _error -> :unknown
  catch
    _kind, _reason -> :unknown
  end

  # What a prompt's run authorizes: the same action input or query
  # `execute_action/6` builds. Types the prompt path does not run are left to
  # the existing unsupported-type answer.
  defp prompt_source(spec) do
    case dispatch_type(spec) do
      :action -> build_input(spec)
      :read -> build_query(spec)
      {:unsupported, _type} -> nil
    end
  end

  # An extension call's spec names the resource, action, inputs and tenant
  # of the call the handler will make; without `:resource`/`:action` there is
  # nothing to check.
  defp ext_source(%{resource: resource, action: action} = spec)
       when is_atom(resource) and is_atom(action) and not is_nil(action) do
    inputs = Map.get(spec, :inputs) || %{}

    case action_type(resource, action) do
      nil -> nil
      :action -> Ash.ActionInput.for_action(resource, action, inputs)
      :read -> Ash.Query.for_read(resource, action, inputs)
      _write -> {resource, action, inputs}
    end
  end

  defp ext_source(_spec), do: nil

  # A turn that the host's approval seam already denied: no execution, a
  # failed tool call update, and a refusal stop reason.
  defp denied_turn(session, session_id, _spec, request_id, state) do
    {tool_call_id, state} = next_tool_call_id(state)
    record(state, session, :agent, "Permission denied.")

    notifications = [
      tool_call_update(session_id, tool_call_id, "failed", %{
        "content" => [tool_content("Permission denied")]
      })
    ]

    {JsonRpc.response(request_id, %{"stopReason" => "refusal"}), notifications,
     clear_in_flight(state, session_id)}
  end

  # An approval request was recorded on the host's approval resource (ADR
  # 0015). The client is asked through `session/request_permission` and the
  # prompt turn STAYS OPEN — `in_flight` keeps the prompt's request id and no
  # prompt response is sent yet. The client's answer completes the turn in
  # `handle_permission_outcome/3`.
  defp request_permission(session, session_id, spec, request_id, request_ref, state) do
    {tool_call_id, state} = next_tool_call_id(state)
    {outbound_id, state} = next_outbound_id(state)
    outbound = permission_request(outbound_id, session_id, tool_call_id, spec, request_ref)

    state = %{
      state
      | pending_permissions:
          Map.put(state.pending_permissions, outbound_id, %{
            kind: :prompt,
            session_id: session_id,
            request_ref: request_ref,
            action_spec: spec,
            tool_call_id: tool_call_id,
            session: session,
            prompt_request_id: request_id
          })
    }

    # No prompt response: the turn is still open. `in_flight` keeps the
    # prompt's request id so a session/cancel can still answer it, and so a
    # second prompt for the session is refused until the permission lands.
    {nil, [outbound], state}
  end

  # The client answered a pending session/request_permission: the open
  # prompt turn completes now, and its response — addressed to the prompt's
  # original request id — reflects the outcome. Approval executes the action
  # (streaming its updates first, response last); denial ends the turn
  # refused with a failed tool call update.
  defp handle_permission_outcome(%{kind: :ext} = permission, result, state) do
    %{session_id: session_id, tool_call_id: tool_call_id, ext: ext} = permission
    tool_call = {session_id, tool_call_id}

    case resolve_permission(permission, result, state) do
      {:approved, approval} ->
        ext_resume(ext, {:approved, approval}, tool_call, state)

      {:denied} ->
        ext_resume(ext, {:denied, :client}, tool_call, state)

      other ->
        seam_violation(ext.id, permission_request!(state), "resolve/3", other, state, [
          tool_call_update(session_id, tool_call_id, "failed", %{
            "content" => [tool_content("Permission resolution failed")]
          })
        ])
    end
  end

  defp handle_permission_outcome(permission, result, state) do
    %{session: session, session_id: session_id, action_spec: spec, tool_call_id: tool_call_id} =
      permission

    case resolve_permission(permission, result, state) do
      {:approved, approval} ->
        execute_action(session, session_id, spec, permission.prompt_request_id, state, approval)

      {:denied} ->
        record(state, session, :agent, "Permission denied.")

        notifications = [
          tool_call_update(session_id, tool_call_id, "failed", %{
            "content" => [tool_content("Permission denied")]
          })
        ]

        response =
          if permission.prompt_request_id do
            JsonRpc.response(permission.prompt_request_id, %{"stopReason" => "refusal"})
          end

        {response, notifications, clear_in_flight(state, session_id)}

      other ->
        {response, notifications, _} =
          seam_violation(
            permission.prompt_request_id,
            permission_request!(state),
            "resolve/3",
            other,
            state,
            [
              tool_call_update(session_id, tool_call_id, "failed", %{
                "content" => [tool_content("Permission resolution failed")]
              })
            ]
          )

        {response, notifications, clear_in_flight(state, session_id)}
    end
  end

  # The host's resolve/3 when exported, else the default option-id mapping.
  defp resolve_permission(permission, result, state) do
    outcome = result["outcome"] || result
    module = permission_request!(state)

    if exports?(module, :resolve, 3) do
      module.resolve(permission.request_ref, outcome, permission.session)
    else
      AshAcp.PermissionRequest.default_resolve(permission.request_ref, outcome)
    end
  end

  defp permission_request(outbound_id, session_id, tool_call_id, spec, request_ref) do
    JsonRpc.request(outbound_id, "session/request_permission", %{
      "sessionId" => session_id,
      "toolCall" => %{
        "toolCallId" => tool_call_id,
        "title" => spec.title,
        "kind" => tool_kind(spec),
        "status" => "pending"
      },
      "options" => @default_permission_options,
      "_meta" => %{"requestRef" => encode_ref(request_ref)}
    })
  end

  # A seam returned something outside its contract. Never silent: the
  # affected prompt is answered with -32603 and the module is named in the
  # log, so a broken host integration is loud instead of a hanging client.
  defp seam_violation(request_id, module, callback, returned, state, extra_notifications \\ [])

  defp seam_violation(request_id, module, callback, returned, state, extra_notifications) do
    Logger.error(fn ->
      "AshAcp: #{inspect(module)}.#{callback} returned #{inspect(returned)}, " <>
        "which violates its contract — failing the affected prompt with -32603"
    end)

    response =
      if request_id do
        JsonRpc.error(request_id, -32603, "internal error", %{
          "reason" => "#{inspect(module)}.#{callback} returned an invalid value",
          "return" => inspect(returned)
        })
      end

    {response, extra_notifications, state}
  end

  # == extension methods ====================================================

  # The handler's method names, as advertised and as routed.
  defp ext_method_names(handler), do: Enum.map(handler.methods(), &to_string/1)

  # `%{"ash" => %{"extMethods" => [...], ...capabilities/1}}`, or nil with no
  # handler. A failing `capabilities/1` is logged and its extras omitted: an
  # optional index must never break the handshake.
  defp ext_meta(state) do
    case Map.get(state.config, :ext_methods) do
      nil ->
        nil

      handler ->
        extra = ext_capabilities(handler, ext_ctx(nil, nil, state))
        %{"ash" => Map.put(extra, "extMethods", ext_method_names(handler))}
    end
  end

  defp ext_capabilities(handler, ctx) do
    if exports?(handler, :capabilities, 1) do
      case handler.capabilities(ctx) do
        extra when is_map(extra) -> stringify(extra)
        _other -> %{}
      end
    else
      %{}
    end
  rescue
    e ->
      Logger.error(fn ->
        "AshAcp: #{inspect(handler)}.capabilities/1 crashed: " <>
          Exception.format(:error, e, __STACKTRACE__)
      end)

      %{}
  end

  defp ext_ctx(session, session_id, state) do
    %{
      session: session,
      session_id: session_id,
      actor: (session && actor_of(session)) || state.actor,
      permission: nil,
      denied_by: nil
    }
  end

  defp handle_ext(handler, method, params, message, state) do
    id = message["id"]

    case ext_session(params, id, state) do
      {:ok, session, session_id, state} ->
        ext = %{
          handler: handler,
          method: method,
          params: params,
          id: id,
          ctx: ext_ctx(session, session_id, state)
        }

        returned = handler.handle(method, params, ext.ctx)

        if Map.has_key?(message, "id") do
          ext_first(returned, ext, state)
        else
          # an extension notification: dispatched, never answered
          {nil, [], state}
        end

      {:error, response} ->
        if Map.has_key?(message, "id"), do: {response, [], state}, else: {nil, [], state}
    end
  end

  defp ext_session(params, request_id, state) do
    case params["sessionId"] do
      nil ->
        {:ok, nil, nil, state}

      session_id when is_binary(session_id) ->
        case fetch_owned_session(state, session_id, request_id) do
          {:ok, session, state} -> {:ok, session, session_id, state}
          {:error, response} -> {:error, response}
        end

      _other ->
        {:error,
         JsonRpc.std_error(request_id, -32602, %{"reason" => "sessionId must be a string"})}
    end
  end

  defp ext_first({:request_permission, spec}, ext, state) when is_map(spec) do
    if ext.ctx.session do
      ext_request_permission(normalize_ext_spec(spec, ext), ext, state)
    else
      {JsonRpc.std_error(ext.id, -32602, %{
         "reason" => "#{ext.method} needs a sessionId: the operation requires permission"
       }), [], state}
    end
  end

  defp ext_first(returned, ext, state), do: ext_answer(returned, ext, nil, state)

  # Ash's answer first: a call the actor's policies refuse is denied at once
  # (`denied_by: :policy`), with no approval and no client round trip. Then
  # the host's own approval seam decides, exactly as for a prompt.
  defp ext_request_permission(spec, ext, state) do
    case precheck(spec, ext.ctx.actor, &ext_source/1) do
      :forbidden -> ext_resume(ext, {:denied, :policy}, nil, state)
      :unknown -> ext_request_approval(spec, ext, state)
    end
  end

  defp ext_request_approval(spec, ext, state) do
    module = permission_request!(state)

    case module.request(ext.ctx.session, spec, spec.inputs) do
      {:approved, approval} ->
        ext_resume(ext, {:approved, approval}, nil, state)

      {:denied} ->
        ext_resume(ext, {:denied, :host}, nil, state)

      {:pending, request_ref} ->
        session_id = ext.ctx.session_id
        {tool_call_id, state} = next_tool_call_id(state)
        {outbound_id, state} = next_outbound_id(state)
        outbound = permission_request(outbound_id, session_id, tool_call_id, spec, request_ref)

        pending = %{
          kind: :ext,
          session_id: session_id,
          session: ext.ctx.session,
          request_ref: request_ref,
          tool_call_id: tool_call_id,
          ext: ext
        }

        # The extension request stays open until the client answers.
        {nil, [outbound],
         %{state | pending_permissions: Map.put(state.pending_permissions, outbound_id, pending)}}

      other ->
        seam_violation(ext.id, module, "request/3", other, state)
    end
  end

  # The second call: the handler answers knowing the permission outcome.
  # `tool_call` is `{session_id, tool_call_id}` when the client was asked, so
  # the pending tool call it rendered is settled too.
  defp ext_resume(ext, {:denied, by}, tool_call, state) do
    ext
    |> put_in([:ctx, :permission], :denied)
    |> put_in([:ctx, :denied_by], by)
    |> ext_call_again(tool_call, state)
  end

  defp ext_resume(ext, permission, tool_call, state) do
    ext
    |> put_in([:ctx, :permission], permission)
    |> ext_call_again(tool_call, state)
  end

  defp ext_call_again(ext, tool_call, state) do
    returned = ext.handler.handle(ext.method, ext.params, ext.ctx)
    ext_answer(returned, ext, tool_call, state)
  end

  defp ext_answer(returned, ext, tool_call, state) do
    case returned do
      {:ok, result} ->
        result = stringify(result)
        settled = settle_tool_call(tool_call, ext.ctx.permission, settlement(result))
        {JsonRpc.response(ext.id, result), settled, state}

      {:ok, result, updates} when is_list(updates) ->
        ext_answer_with_updates(result, updates, ext, tool_call, state)

      {:error, code, message} when is_integer(code) and is_binary(message) ->
        {JsonRpc.error(ext.id, code, message), settle_tool_call(tool_call, nil, :error), state}

      {:error, code, message, data} when is_integer(code) and is_binary(message) ->
        {JsonRpc.error(ext.id, code, message, stringify(data)),
         settle_tool_call(tool_call, nil, :error), state}

      {:error, reason} ->
        {JsonRpc.error(ext.id, -32603, "extension method failed", %{"reason" => inspect(reason)}),
         settle_tool_call(tool_call, nil, :error), state}

      other ->
        seam_violation(
          ext.id,
          ext.handler,
          "handle/3",
          other,
          state,
          settle_tool_call(tool_call, nil, :error)
        )
    end
  end

  defp ext_answer_with_updates(result, updates, ext, tool_call, state) do
    case ext.ctx.session_id do
      nil ->
        seam_violation(
          ext.id,
          ext.handler,
          "handle/3",
          {:ok, :updates_without_a_session},
          state,
          settle_tool_call(tool_call, nil, :error)
        )

      session_id ->
        result = stringify(result)

        notifications =
          Enum.map(updates, &Updates.notification(session_id, stringify(&1))) ++
            settle_tool_call(tool_call, ext.ctx.permission, settlement(result))

        {JsonRpc.response(ext.id, result), notifications, state}
    end
  end

  # A result carrying the conventional `outcome: "failed"` settles the pending
  # tool call as failed too — the write did not happen.
  defp settlement(%{"outcome" => "failed", "error" => %{"kind" => "forbidden"}}),
    do: {:error, "Not permitted"}

  defp settlement(%{"outcome" => "failed"}), do: :error
  defp settlement(_result), do: :ok

  defp settle_tool_call(nil, _permission, _result), do: []

  defp settle_tool_call({session_id, tool_call_id}, :denied, _result) do
    [
      tool_call_update(session_id, tool_call_id, "failed", %{
        "content" => [tool_content("Permission denied")]
      })
    ]
  end

  defp settle_tool_call({session_id, tool_call_id}, _permission, :ok),
    do: [tool_call_update(session_id, tool_call_id, "completed")]

  defp settle_tool_call(tool_call, permission, :error),
    do: settle_tool_call(tool_call, permission, {:error, "Action failed"})

  defp settle_tool_call({session_id, tool_call_id}, _permission, {:error, text}) do
    [
      tool_call_update(session_id, tool_call_id, "failed", %{
        "content" => [tool_content(text)]
      })
    ]
  end

  # The spec handed to `AshAcp.PermissionRequest.request/3`: the host's keys
  # (e.g. `:resource`/`:action`) kept, the prompt-spec keys defaulted, and
  # the originating call attached under `:ext`.
  defp normalize_ext_spec(spec, ext) do
    spec
    |> Map.put_new(:title, ext.method)
    |> Map.put_new(:kind, :execute)
    |> Map.put_new(:inputs, %{})
    |> Map.put_new(:name, ext.method)
    |> Map.put(:ext, %{method: ext.method, params: ext.params})
  end

  # == action execution ======================================================

  # The library's one execution path: the session's actor, `authorize?: true`
  # (and the spec's `tenant`, when given). Approval never bypasses policies;
  # it only unblocks the attempt.
  defp execute_action(session, session_id, spec, request_id, state, approval) do
    {tool_call_id, state} = next_tool_call_id(state)

    started =
      JsonRpc.notification("session/update", %{
        "sessionId" => session_id,
        "update" =>
          %{
            "sessionUpdate" => "tool_call",
            "toolCallId" => tool_call_id,
            "title" => spec.title,
            "kind" => tool_kind(spec),
            "status" => "in_progress",
            "name" => spec.name
          }
          |> maybe_put("rawInput", non_empty(spec.inputs) |> stringify())
          |> maybe_put("approval", if(approval, do: stringify(approval)))
      })

    case dispatch_type(spec) do
      :action ->
        case Ash.run_action(build_input(spec), run_opts(session, spec)) do
          :ok ->
            complete_turn(
              session,
              session_id,
              request_id,
              tool_call_id,
              started,
              agent_chunk(session_id, "ok"),
              "ok",
              state
            )

          {:ok, value} ->
            text = result_text(value)

            complete_turn(
              session,
              session_id,
              request_id,
              tool_call_id,
              started,
              agent_chunk(session_id, text),
              text,
              state
            )

          {:error, error_class} ->
            action_error_turn(
              error_class,
              session,
              session_id,
              spec,
              request_id,
              tool_call_id,
              state
            )
        end

      :read ->
        case read_rows(spec, session) do
          {:ok, records} ->
            {rows_notification, rows_text} = rows_notification(session_id, spec, records)

            complete_turn(
              session,
              session_id,
              request_id,
              tool_call_id,
              started,
              rows_notification,
              rows_text,
              state
            )

          {:error, error_class} ->
            action_error_turn(
              error_class,
              session,
              session_id,
              spec,
              request_id,
              tool_call_id,
              state
            )
        end

      {:unsupported, unsupported_type} ->
        unsupported_turn(session_id, request_id, tool_call_id, unsupported_type, state)
    end
  end

  # :action → generic action; :read → read action; anything else is not a v1
  # surface and is answered with a wire error instead of a host crash.
  defp dispatch_type(%{action_input: %Ash.ActionInput{}}), do: :action

  defp dispatch_type(%{resource: resource, action: action}) do
    case Ash.Resource.Info.action(resource, action) do
      %{type: type} -> if type in [:action, :read], do: type, else: {:unsupported, type}
      nil -> {:unsupported, nil}
    end
  end

  defp build_query(spec) do
    if spec[:tenant] do
      Ash.Query.for_read(spec.resource, spec.action, spec.inputs, tenant: spec.tenant)
    else
      Ash.Query.for_read(spec.resource, spec.action, spec.inputs)
    end
  end

  defp read_rows(spec, session) do
    spec
    |> build_query()
    |> Ash.read(run_opts(session, spec))
    |> case do
      {:ok, records} when is_list(records) -> {:ok, records}
      {:ok, records, _query} when is_list(records) -> {:ok, records}
      {:error, error_class} -> {:error, error_class}
    end
  end

  # The read result update: bounded rows plus the total count, as JSON text.
  @spec rows_notification(String.t(), map(), list()) :: {map(), String.t()}
  defp rows_notification(session_id, spec, records) do
    rows =
      records
      |> Enum.take(@max_read_rows)
      |> Enum.map(&row_map(spec, &1))
      |> Enum.map(&stringify/1)

    text = Jason.encode!(%{"count" => length(records), "rows" => rows})
    {agent_chunk(session_id, text), text}
  end

  defp row_map(spec, record) do
    fields =
      spec.row_fields ||
        spec.resource
        |> Ash.Resource.Info.attributes()
        |> Enum.filter(& &1.public?)
        |> Enum.map(& &1.name)

    Map.take(record, fields)
  end

  defp complete_turn(
         session,
         session_id,
         request_id,
         tool_call_id,
         started,
         result_notification,
         result_text,
         state
       ) do
    {final, state} = final_update(state, session, session_id, :turn_end)

    notifications = [
      started,
      result_notification,
      final,
      tool_call_update(session_id, tool_call_id, "completed")
    ]

    record(state, session, :agent, result_text)

    response =
      if request_id do
        JsonRpc.response(request_id, %{"stopReason" => "end_turn"})
      end

    {response, notifications, clear_in_flight(state, session_id)}
  end

  # Ash's policies refused the run itself: the turn ends refused, settling
  # the announced tool call. The client is not asked to approve it — an
  # approval cannot change a policy's answer. Other failures are wire errors.
  defp action_error_turn(error_class, session, session_id, _spec, request_id, tool_call_id, state) do
    if forbidden?(error_class) do
      forbidden_turn(session, session_id, request_id, state, tool_call_id)
    else
      notifications = [
        tool_call_update(session_id, tool_call_id, "failed", %{
          "content" => [tool_content("Action failed")]
        })
      ]

      {JsonRpc.error(request_id, -32603, "action failed", %{
         "errors" => Exception.message(error_class)
       }), notifications, clear_in_flight(state, session_id)}
    end
  end

  defp unsupported_turn(session_id, request_id, tool_call_id, type, state) do
    notifications = [
      tool_call_update(session_id, tool_call_id, "failed", %{
        "content" => [
          tool_content("Unsupported action type: #{inspect(type || :unknown)} (not a v1 surface)")
        ]
      })
    ]

    response =
      if request_id do
        JsonRpc.error(request_id, -32603, "unsupported action type", %{
          "actionType" => inspect(type),
          "reason" => "only :read and generic :action types are v1 surfaces"
        })
      end

    {response, notifications, clear_in_flight(state, session_id)}
  end

  defp build_input(%{action_input: %Ash.ActionInput{} = input}), do: input

  defp build_input(%{resource: resource, action: action, inputs: inputs}),
    do: Ash.ActionInput.for_action(resource, action, inputs)

  defp forbidden?(%{class: :forbidden}), do: true
  defp forbidden?(_other), do: false

  # == turn bookkeeping ======================================================

  defp clear_in_flight(state, session_id) do
    %{state | in_flight: Map.delete(state.in_flight, session_id)}
  end

  # Transcript recording is the host store's job (`AshAcp.SessionStore`); the
  # server only forwards. Returns the store's updated session so consecutive
  # appends within one turn build on each other. Failures in the host store
  # never break the turn.
  defp record(state, session, role, text)

  defp record(_state, session, _role, text) when text in [nil, ""], do: session

  defp record(state, session, role, text) do
    case session_store!(state).append_message(session, role, text) do
      {:ok, updated} -> updated
      _other -> session
    end
  rescue
    _ -> session
  end

  # == session/update construction ==========================================

  defp agent_chunk(session_id, text) do
    Updates.notification(session_id, Updates.agent_message(text))
  end

  # Tool call content is wrapped: ToolCallContent = {"type": "content", ...Content}.
  defp tool_content(text) do
    %{"type" => "content", "content" => %{"type" => "text", "text" => text}}
  end

  defp tool_call_update(session_id, tool_call_id, status, extra \\ %{}) do
    update =
      %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => tool_call_id,
        "status" => status
      }
      |> Map.merge(Map.new(extra, fn {k, v} -> {to_string(k), v} end))

    Updates.notification(session_id, update)
  end

  # The commands update (after session/new, after the session/load replay,
  # closing each turn): available actions pruned with `Ash.can?/3` for the
  # session actor and — when a provider returns one — the host's opaque A2UI
  # surface, carried verbatim under `update._meta.a2ui` (the ACP `_meta`
  # extension point). `reason` tells the provider why it is asked.
  defp final_update(state, session, session_id, reason) do
    commands = AvailableActions.for_actor(actor_of(session), candidate_actions(state))

    update =
      commands
      |> Updates.available_commands()
      |> maybe_put_a2ui(surface_of(state, session, reason))

    {Updates.notification(session_id, update), state}
  end

  # The configured palette: a list, or — for a host that derives it at
  # runtime (a surface registry) — an `{m, f, a}` or zero-arity function
  # evaluated each time a palette is built. A failing provider is logged and
  # yields an empty palette: it must never break a session.
  defp candidate_actions(state) do
    case resolve_candidates(Map.get(state.config, :candidate_actions)) do
      list when is_list(list) ->
        list

      other ->
        Logger.error(fn ->
          "AshAcp: candidate_actions resolved to #{inspect(other)}, not a list — sending an empty palette"
        end)

        []
    end
  rescue
    e ->
      Logger.error(fn ->
        "AshAcp: candidate_actions provider failed — sending an empty palette: " <>
          Exception.format(:error, e, __STACKTRACE__)
      end)

      []
  end

  defp resolve_candidates(nil), do: []
  defp resolve_candidates(list) when is_list(list), do: list

  defp resolve_candidates({module, fun, args})
       when is_atom(module) and is_atom(fun) and is_list(args),
       do: apply(module, fun, args)

  defp resolve_candidates(fun) when is_function(fun, 0), do: fun.()
  defp resolve_candidates(other), do: other

  defp maybe_put_a2ui(update, nil), do: update
  defp maybe_put_a2ui(update, payload), do: Map.put(update, "_meta", %{"a2ui" => payload})

  defp surface_of(state, session, reason) do
    case Map.get(state.config, :surface_provider) do
      nil -> nil
      provider -> provider.surface(session, %{reason: reason})
    end
  rescue
    e ->
      Logger.warning(fn -> "AshAcp: surface provider failed: " <> Exception.message(e) end)
      nil
  end

  # == wire hygiene ==========================================================

  # Everything placed inside a wire payload must be Jason-encodable with
  # string keys. Host values arrive with atom keys and platform types, so:
  # dates/times become ISO8601 strings, Decimals and money amounts stay
  # STRINGS (a float round-trip silently changes money values — iron law
  # #04), and unknown structs or non-encodable cells become inspect text —
  # one exotic cell must never crash the turn.
  defp stringify(%Date{} = value), do: Date.to_iso8601(value)
  defp stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp stringify(%Time{} = value), do: Time.to_iso8601(value)

  defp stringify(%Decimal{} = value), do: Decimal.to_string(value)

  # money-shaped structs (ash_money): amount-string + currency
  defp stringify(%{amount: amount, currency: currency} = value) when is_struct(value) do
    %{"amount" => stringify(amount), "currency" => to_string(currency)}
  end

  defp stringify(value) when is_struct(value), do: inspect(value)

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), stringify(v)} end)
  rescue
    _ -> inspect(value)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  @doc """
  Serializes one host value for the wire (see the wire-hygiene rules in the
  module documentation). Exposed so hosts and tests can assert exactly what
  a row cell, `rawInput` or approval payload will look like on the wire.
  """
  @spec stringify_value(term()) :: term()
  def stringify_value(value), do: stringify(value)

  # == helpers ===============================================================

  defp agent_info(state) do
    stringify(
      Map.get(state.config, :agent_info) || %{name: "ash_acp", version: AshAcp.library_version()}
    )
  end

  defp session_store!(state), do: Map.fetch!(state.config, :session_store)
  defp prompt_target!(state), do: Map.fetch!(state.config, :prompt_target)
  defp permission_request!(state), do: Map.fetch!(state.config, :permission_request)

  defp run_opts(session, spec) do
    [actor: actor_of(session), authorize?: true]
    |> put_tenant(Map.get(spec, :tenant))
  end

  defp put_tenant(opts, nil), do: opts
  defp put_tenant(opts, tenant), do: Keyword.put(opts, :tenant, tenant)

  defp fetch_session(state, session_id) do
    case Map.get(state.sessions, session_id) do
      nil ->
        case session_store!(state).load(session_id) do
          {:ok, session} ->
            {:ok, session, %{state | sessions: Map.put(state.sessions, session_id, session)}}

          {:error, reason} ->
            {:error, reason}
        end

      session ->
        {:ok, session, state}
    end
  end

  # A session addressed by id on this connection: cached, or loaded from the
  # store — and then never one owned by another actor than the connection's.
  defp fetch_owned_session(state, session_id, request_id) do
    case fetch_session(state, session_id) do
      {:ok, session, new_state} ->
        if foreign?(session, state.actor) do
          {:error, foreign_session(request_id)}
        else
          {:ok, session, new_state}
        end

      {:error, reason} ->
        {:error, session_not_found(request_id, reason)}
    end
  end

  defp session_not_found(id, reason) do
    JsonRpc.error(id, -32002, "Resource not found", %{
      "reason" => "session not found",
      "detail" => inspect(reason)
    })
  end

  defp transcript(session) do
    session
    |> get_key(:messages)
    |> List.wrap()
    |> Enum.map(fn
      %{role: role, text: text} -> %{role: normalize_role(role), text: to_string(text)}
      %{"role" => role, "text" => text} -> %{role: normalize_role(role), text: to_string(text)}
      _other -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_role(role) when role in [:agent, "agent", :assistant, "assistant"], do: :agent
  defp normalize_role(_role), do: :user

  defp chunk(:user, text), do: Updates.user_message(text)
  defp chunk(:agent, text), do: Updates.agent_message(text)

  defp session_id!(session) do
    case get_key(session, :session_id) do
      nil ->
        raise ArgumentError, "host session store must return a session carrying a :session_id"

      id ->
        to_string(id)
    end
  end

  defp actor_of(session), do: get_key(session, :actor)

  defp remember_actor(state, nil), do: state
  defp remember_actor(state, actor), do: %{state | actor: actor}

  defp exports?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  defp session_capabilities(state) do
    if exports?(session_store!(state), :list, 1), do: %{"list" => %{}}, else: %{}
  end

  # The authenticated actor (when `AshAcp.Authenticator` is configured)
  # replaces whatever the host store put on the session.
  defp put_actor(session, nil) when is_map(session), do: session
  defp put_actor(nil, _actor), do: nil

  defp put_actor(session, actor) when is_map(session) do
    cond do
      Map.has_key?(session, :actor) -> Map.put(session, :actor, actor)
      Map.has_key?(session, "actor") -> Map.put(session, "actor", actor)
      true -> session
    end
  end

  defp put_actor(session, _actor), do: session

  # Reads a key from a host session by atom or string name. Host sessions may
  # be plain maps or resource structs; the server touches only the three
  # documented keys (see `AshAcp.SessionStore`).
  defp get_key(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp get_key(_other, _key), do: nil

  defp normalize_spec(%{action_input: %Ash.ActionInput{}} = spec) do
    spec
    |> Map.put_new(:title, "Run action")
    |> Map.put_new(:inputs, %{})
    |> Map.put_new(:kind, :execute)
    |> Map.put_new(:name, spec[:title] || "Run action")
    |> Map.put_new(:tenant, nil)
  end

  defp normalize_spec(%{resource: resource, action: action} = spec)
       when is_atom(resource) and is_atom(action) do
    name = "#{resource |> Module.split() |> Enum.join(".")}.#{action}"
    type = action_type(resource, action)

    %{
      resource: resource,
      action: action,
      inputs: Map.get(spec, :inputs, %{}),
      title: Map.get(spec, :title) || name,
      kind: Map.get(spec, :kind) || default_kind(type),
      name: name,
      tenant: Map.get(spec, :tenant),
      row_fields: Map.get(spec, :row_fields)
    }
  end

  defp normalize_spec(other) do
    raise ArgumentError,
          "AshAcp.PromptTarget must return {:ok, %{resource:, action:, inputs:}} or {:ok, %{action_input:}}, got: #{inspect(other)}"
  end

  defp action_type(resource, action) do
    case Ash.Resource.Info.action(resource, action) do
      %{type: type} -> type
      nil -> nil
    end
  end

  defp default_kind(:read), do: :read
  defp default_kind(_type), do: :execute

  defp tool_kind(%{kind: kind}) when is_atom(kind), do: to_string(kind)
  defp tool_kind(%{kind: kind}) when is_binary(kind), do: kind
  defp tool_kind(_spec), do: "execute"

  defp result_text(text) when is_binary(text), do: text
  defp result_text(other), do: inspect(other)

  defp next_tool_call_id(state) do
    id = "tc-#{state.tool_call_counter + 1}"
    {id, %{state | tool_call_counter: state.tool_call_counter + 1}}
  end

  defp next_outbound_id(state) do
    id = "srv-#{state.outbound_id_counter + 1}"
    {id, %{state | outbound_id_counter: state.outbound_id_counter + 1}}
  end

  defp encode_ref(ref) when is_binary(ref), do: ref
  defp encode_ref(ref), do: inspect(ref)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp non_empty(map) when map == %{}, do: nil
  defp non_empty(map), do: map
end

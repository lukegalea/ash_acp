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

  ## Method map (ACP v1, `AshAcp.acp_version/0`)

  | Message | Behaviour seam touched |
  |---|---|
  | `initialize` | none (version + capabilities derived from `AshAcp`) |
  | `session/new` | `AshAcp.SessionStore.create/1` |
  | `session/load` | `AshAcp.SessionStore.load/1`, transcript replay |
  | `session/prompt` | `AshAcp.PromptTarget`, `AshAcp.PermissionRequest`, `AshAcp.SurfaceProvider`, `Ash.run_action/2` (`authorize?: true`), `Ash.can?/3` |
  | `session/cancel` | none (answers the in-flight prompt with `stopReason: "cancelled"`) |
  | client responses to our `session/request_permission` | `AshAcp.PermissionRequest.resolve/3` |

  The state is connection-scoped bookkeeping only — the session cache,
  in-flight prompt request ids, pending permission requests and the id
  counters. Everything durable lives in the host's `AshAcp.SessionStore`, so a
  transport may rebuild the state per connection at any time.
  """

  alias AshAcp.AvailableActions
  alias AshAcp.JsonRpc

  defstruct [
    :config,
    sessions: %{},
    in_flight: %{},
    pending_permissions: %{},
    tool_call_counter: 0,
    outbound_id_counter: 0
  ]

  @type t :: %__MODULE__{
          config: map(),
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

  @doc "Builds the initial state from a config map (the `AshAcp.config/1` shape)."
  @spec new(map()) :: t()
  def new(config), do: %__MODULE__{config: Map.new(config)}

  @doc """
  Handles one decoded JSON-RPC message. Returns `{response, notifications,
  new_state}`; `response` is `nil` for notifications and for client responses
  to our own requests (those are never answered).

  Use `handle_line/2` for raw ndjson lines — it layers parse-error handling
  (`-32700`) on top of this function.
  """
  @spec handle_message(map(), t()) :: {map() | nil, [map()], t()}
  def handle_message(message, state)

  # -- client response to our session/request_permission ---------------------

  def handle_message(%{"id" => id, "result" => result}, %__MODULE__{} = state)
      when is_map_key(state.pending_permissions, id) do
    permission = Map.fetch!(state.pending_permissions, id)

    handle_permission_outcome(permission, result, %{
      state
      | pending_permissions: Map.delete(state.pending_permissions, id)
    })
  end

  # Responses to unknown ids (or errors about our requests) are ignored: the
  # connection state has no pending work to complete.
  def handle_message(%{"id" => _id, "result" => _result}, state), do: {nil, [], state}
  def handle_message(%{"id" => _id, "error" => _error}, state), do: {nil, [], state}

  # -- methods ---------------------------------------------------------------

  def handle_message(%{"method" => "initialize"} = message, state) do
    with_params(message, state, &handle_initialize(&1, &2, &3))
  end

  def handle_message(%{"method" => "session/new"} = message, state) do
    with_params(message, state, &handle_session_new(&1, &2, &3))
  end

  def handle_message(%{"method" => "session/load"} = message, state) do
    with_params(message, state, &handle_session_load(&1, &2, &3))
  end

  def handle_message(%{"method" => "session/prompt"} = message, state) do
    with_params(message, state, &handle_session_prompt(&1, &2, &3))
  end

  def handle_message(%{"method" => "session/cancel"} = message, state) do
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
        # the call the client is still awaiting.
        response = JsonRpc.response(prompt_request_id, %{"stopReason" => "cancelled"})

        {response, [], %{state | in_flight: Map.delete(state.in_flight, session_id)}}
    end
  end

  # Unknown method: requests get -32601; notifications are never answered.
  def handle_message(%{"method" => _method} = message, state) do
    if Map.has_key?(message, "id") do
      {JsonRpc.std_error(message["id"], -32601), [], state}
    else
      {nil, [], state}
    end
  end

  def handle_message(_other, state) do
    {JsonRpc.std_error(nil, -32600), [], state}
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

  # == initialize ============================================================

  defp handle_initialize(params, message, state) do
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

        result = %{
          "protocolVersion" => negotiated,
          "agentCapabilities" => %{
            "loadSession" => true,
            "promptCapabilities" => %{
              "image" => false,
              "audio" => false,
              "embeddedContext" => false
            },
            "mcpCapabilities" => %{"http" => false, "sse" => false},
            "sessionCapabilities" => %{}
          },
          "authMethods" => [],
          "agentInfo" => agent_info(state)
        }

        {JsonRpc.response(message["id"], result), [], state}

      _other ->
        {JsonRpc.std_error(message["id"], -32602, %{
           "reason" => "protocolVersion (integer) is required"
         }), [], state}
    end
  end

  # == session/new ===========================================================

  defp handle_session_new(params, message, state) do
    init = %{
      "cwd" => params["cwd"],
      "mcpServers" => params["mcpServers"] || [],
      "clientInfo" => params["clientInfo"]
    }

    case session_store!(state).create(init) do
      {:ok, session} ->
        session_id = session_id!(session)

        {JsonRpc.response(message["id"], %{"sessionId" => session_id}), [],
         %{state | sessions: Map.put(state.sessions, session_id, session)}}

      {:error, reason} ->
        {JsonRpc.error(message["id"], -32603, "session could not be created", %{
           "reason" => inspect(reason)
         }), [], state}
    end
  end

  # == session/load ==========================================================

  defp handle_session_load(params, message, state) do
    session_id = params["sessionId"]

    if is_binary(session_id) do
      case fetch_session(state, session_id) do
        {:ok, session, state} ->
          notifications =
            Enum.map(transcript(session), fn %{role: role, text: text} ->
              JsonRpc.notification("session/update", %{
                "sessionId" => session_id,
                "update" => %{
                  "sessionUpdate" => chunk_type(role),
                  "content" => %{"type" => "text", "text" => text}
                }
              })
            end)

          {JsonRpc.response(message["id"], %{}), notifications, state}

        {:error, reason} ->
          {session_not_found(message["id"], reason), [], state}
      end
    else
      {JsonRpc.std_error(message["id"], -32602, %{"reason" => "sessionId (string) is required"}),
       [], state}
    end
  end

  # == session/prompt ========================================================

  defp handle_session_prompt(params, message, state) do
    with {:ok, session_id, prompt_text} <- extract_prompt(params),
         :ok <- check_not_in_flight(state, session_id) do
      case fetch_session(state, session_id) do
        {:ok, session, state} ->
          state = put_in(state.in_flight, Map.put(state.in_flight, session_id, message["id"]))
          run_prompt_turn(session, session_id, prompt_text, message["id"], state)

        {:error, reason} ->
          {session_not_found(message["id"], reason), [], state}
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

        case permission_request!(state).request(session, spec, spec.inputs) do
          {:approved, approval} ->
            execute_action(session, session_id, spec, request_id, state, approval)

          {:denied} ->
            denied_turn(session, session_id, spec, request_id, state)

          {:pending, request_ref} ->
            request_permission(session, session_id, spec, request_id, request_ref, state)

          other ->
            {JsonRpc.error(request_id, -32603, "permission request failed", %{
               "reason" => inspect(other)
             }), [], clear_in_flight(state, session_id)}
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

  # A turn that the host's approval seam already denied: no execution, a
  # failed tool call update, and a refusal stop reason.
  defp denied_turn(session, session_id, _spec, request_id, state) do
    {tool_call_id, state} = next_tool_call_id(state)
    record(state, session, :agent, "Permission denied.")

    notifications = [
      tool_call_update(session_id, tool_call_id, "failed", %{
        "content" => [%{"type" => "text", "text" => "Permission denied"}]
      })
    ]

    {JsonRpc.response(request_id, %{"stopReason" => "refusal"}), notifications,
     clear_in_flight(state, session_id)}
  end

  # An approval request was recorded on the host's approval resource (ADR
  # 0015). The client is asked through `session/request_permission`; the
  # prompt turn ends and the outcome continues asynchronously.
  defp request_permission(session, session_id, spec, request_id, request_ref, state) do
    {tool_call_id, state} = next_tool_call_id(state)
    {outbound_id, state} = next_outbound_id(state)

    outbound =
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

    state = %{
      state
      | pending_permissions:
          Map.put(state.pending_permissions, outbound_id, %{
            session_id: session_id,
            request_ref: request_ref,
            action_spec: spec,
            tool_call_id: tool_call_id,
            session: session
          })
    }

    # A prompt request gets its turn-ending response; when the flow was
    # reached via a client's answer to our own request_permission (no open
    # request of theirs), there is nothing to answer.
    response =
      if request_id do
        JsonRpc.response(request_id, %{"stopReason" => "end_turn"})
      end

    {response, [outbound], clear_in_flight(state, session_id)}
  end

  # The client answered a pending session/request_permission.
  defp handle_permission_outcome(permission, result, state) do
    %{session: session, session_id: session_id, action_spec: spec, tool_call_id: tool_call_id} =
      permission

    outcome = result["outcome"] || result

    resolved =
      if function_exported?(permission_request!(state), :resolve, 3) do
        permission_request!(state).resolve(permission.request_ref, outcome, session)
      else
        AshAcp.PermissionRequest.default_resolve(permission.request_ref, outcome)
      end

    case resolved do
      {:approved, approval} ->
        execute_action(session, session_id, spec, nil, state, approval)

      {:denied} ->
        record(state, session, :agent, "Permission denied.")

        {nil,
         [
           tool_call_update(session_id, tool_call_id, "failed", %{
             "content" => [%{"type" => "text", "text" => "Permission denied"}]
           })
         ], state}

      {:pending, new_ref} ->
        # The host wants the request surfaced again (e.g. the previous
        # approval lapsed): re-issue session/request_permission with the new
        # reference.
        {new_tool_call_id, state} = next_tool_call_id(state)
        {outbound_id, state} = next_outbound_id(state)

        outbound =
          JsonRpc.request(outbound_id, "session/request_permission", %{
            "sessionId" => session_id,
            "toolCall" => %{
              "toolCallId" => new_tool_call_id,
              "title" => spec.title,
              "kind" => tool_kind(spec),
              "status" => "pending"
            },
            "options" => @default_permission_options
          })

        state = %{
          state
          | pending_permissions:
              Map.put(state.pending_permissions, outbound_id, %{
                session_id: session_id,
                request_ref: new_ref,
                action_spec: spec,
                tool_call_id: new_tool_call_id,
                session: session
              })
        }

        {nil, [outbound], state}

      other ->
        {nil,
         [
           tool_call_update(session_id, tool_call_id, "failed", %{
             "content" => [
               %{"type" => "text", "text" => "Permission resolution failed: #{inspect(other)}"}
             ]
           })
         ], state}
    end
  end

  # == action execution ======================================================

  # The library's one execution path: a generic Ash action run with the
  # session's actor and `authorize?: true`. Approval never bypasses policies;
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

    case Ash.run_action(build_input(spec), actor: actor_of(session), authorize?: true) do
      :ok ->
        complete_turn(session, session_id, spec, request_id, tool_call_id, started, "ok", state)

      {:ok, value} ->
        complete_turn(
          session,
          session_id,
          spec,
          request_id,
          tool_call_id,
          started,
          result_text(value),
          state
        )

      {:error, error_class} ->
        if forbidden?(error_class) do
          # An Ash policy denial surfaces as a permission request — never as
          # a wire error. The operator decides through the client.
          unauthorized_turn(session, session_id, spec, request_id, state)
        else
          {JsonRpc.error(request_id, -32603, "action failed", %{
             "errors" => Exception.message(error_class)
           }), [], clear_in_flight(state, session_id)}
        end
    end
  end

  defp complete_turn(
         session,
         session_id,
         _spec,
         request_id,
         tool_call_id,
         started,
         result_text,
         state
       ) do
    {final, state} = final_update(state, session, session_id)

    notifications = [
      started,
      agent_chunk(session_id, result_text),
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

  # An action denied by Ash policies becomes a permission request bound to a
  # synthetic reference; `resolve/3` (or the default) decides what a client
  # approval means for it.
  defp unauthorized_turn(session, session_id, spec, request_id, state) do
    request_permission(
      session,
      session_id,
      spec,
      request_id,
      {:ash_denied, spec.resource, spec.action},
      state
    )
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
    JsonRpc.notification("session/update", %{
      "sessionId" => session_id,
      "update" => %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text}
      }
    })
  end

  defp tool_call_update(session_id, tool_call_id, status, extra \\ %{}) do
    update =
      %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => tool_call_id,
        "status" => status
      }
      |> Map.merge(Map.new(extra, fn {k, v} -> {to_string(k), v} end))

    JsonRpc.notification("session/update", %{"sessionId" => session_id, "update" => update})
  end

  # The closing update of a turn: available actions pruned with `Ash.can?/3`
  # for the session actor and — when a provider is configured — the host's
  # opaque A2UI surface descriptors carried verbatim under `update.surface`.
  defp final_update(state, session, session_id) do
    candidates = Map.get(state.config, :candidate_actions, [])
    commands = AvailableActions.for_actor(actor_of(session), candidates)

    update =
      %{"sessionUpdate" => "available_commands_update", "availableCommands" => commands}
      |> maybe_put("surface", surface_of(state, session))

    {JsonRpc.notification("session/update", %{"sessionId" => session_id, "update" => update}),
     state}
  end

  defp surface_of(state, session) do
    case Map.get(state.config, :surface_provider) do
      nil -> nil
      provider -> provider.surface(session, %{})
    end
  rescue
    _ -> nil
  end

  # == wire hygiene ==========================================================

  # Everything placed inside a wire payload must have string keys — host
  # values (agent info, approval records, action inputs) arrive with atom
  # keys and would otherwise leak Elixir-isms onto a JSON wire.
  defp stringify(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  # == helpers ===============================================================

  defp agent_info(state) do
    stringify(
      Map.get(state.config, :agent_info) || %{name: "ash_acp", version: AshAcp.library_version()}
    )
  end

  defp session_store!(state), do: Map.fetch!(state.config, :session_store)
  defp prompt_target!(state), do: Map.fetch!(state.config, :prompt_target)
  defp permission_request!(state), do: Map.fetch!(state.config, :permission_request)

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

  defp chunk_type(:user), do: "user_message_chunk"
  defp chunk_type(:agent), do: "agent_message_chunk"

  defp session_id!(session) do
    case get_key(session, :session_id) do
      nil ->
        raise ArgumentError, "host session store must return a session carrying a :session_id"

      id ->
        to_string(id)
    end
  end

  defp actor_of(session), do: get_key(session, :actor)

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
  end

  defp normalize_spec(%{resource: resource, action: action} = spec)
       when is_atom(resource) and is_atom(action) do
    name = "#{resource |> Module.split() |> Enum.join(".")}.#{action}"

    %{
      resource: resource,
      action: action,
      inputs: Map.get(spec, :inputs, %{}),
      title: Map.get(spec, :title) || name,
      kind: Map.get(spec, :kind) || :execute,
      name: name
    }
  end

  defp normalize_spec(other) do
    raise ArgumentError,
          "AshAcp.PromptTarget must return {:ok, %{resource:, action:, inputs:}} or {:ok, %{action_input:}}, got: #{inspect(other)}"
  end

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

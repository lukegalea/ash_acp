# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.TestSupport.SchemaConformance do
  @moduledoc """
  Validates wire messages against the vendored ACP v1 JSON schema
  (`priv/acp_schema/schema.json`, provenance in `source.json`).

  Two layers:

  * every message validates against the schema root (envelope + payload
    well-formedness on both protocol sides);
  * targeted validation: outbound agent requests validate their `params`
    against the method's request definition, notifications against
    `SessionNotification`, and responses validate their `result` against the
    response definition of the method their id is correlated with.

  The schema is published as draft 2020-12; ex_json_schema resolves it as
  draft-07, which is faithful for every construct this schema uses (the
  `x-deserialize-*` annotations are inert either way).
  """

  @schema_path "priv/acp_schema/schema.json"
  @source_path "priv/acp_schema/source.json"

  # method → {request definition, response definition}. `session/cancel` is a
  # notification, so it has no response definition.
  @method_defs %{
    "initialize" => {"InitializeRequest", "InitializeResponse"},
    "session/new" => {"NewSessionRequest", "NewSessionResponse"},
    "session/load" => {"LoadSessionRequest", "LoadSessionResponse"},
    "session/prompt" => {"PromptRequest", "PromptResponse"},
    "session/cancel" => {"CancelNotification", nil},
    "session/request_permission" => {"RequestPermissionRequest", "RequestPermissionResponse"}
  }

  def provenance, do: @source_path |> File.read!() |> Jason.decode!()

  def resolved do
    case :persistent_term.get({__MODULE__, :resolved}, nil) do
      nil ->
        resolved = resolve_schema()
        :persistent_term.put({__MODULE__, :resolved}, resolved)
        resolved

      resolved ->
        resolved
    end
  end

  defp resolve_schema do
    raw = @schema_path |> File.read!() |> Jason.decode!()

    raw =
      if raw["$schema"] =~ "2020-12" do
        Map.put(raw, "$schema", "http://json-schema.org/draft-07/schema#")
      else
        raw
      end

    ExJsonSchema.Schema.resolve(raw)
  end

  @doc "Validates one decoded wire message against the schema root."
  @spec validate_root(map()) :: :ok | {:error, [String.t()]}
  def validate_root(message) do
    validate_against(resolved(), message)
  end

  @doc """
  Validates a full fixture's recorded wire output (`expected` — the outbound
  agent messages, in order) against the schema. Inbound `input` lines are
  deliberately excluded: fixtures intentionally probe malformed envelopes
  (parse errors, bad params, unknown methods), and the recorded `-32700` /
  `-32602` / `-32601` responses are the conformance evidence. Client
  *responses* inside the input (replies to our `session/request_permission`)
  still validate their `result` against the correlated response definition.
  Returns a list of human-readable problems; empty means conformance.
  """
  @spec validate_fixture(expected :: [map()], input_lines :: [String.t()]) :: [String.t()]
  def validate_fixture(expected, input_lines) do
    # correlate response/request ids with methods across both directions
    methods_by_id =
      Enum.flat_map(expected ++ Enum.flat_map(input_lines, &decode_ids/1), fn
        %{"id" => id, "method" => method} -> [{id, method}]
        _ -> []
      end)
      |> Enum.into(%{})

    Enum.flat_map(expected, &validate_outbound(&1, methods_by_id)) ++
      Enum.flat_map(input_lines, &validate_inbound(&1, methods_by_id))
  end

  defp decode_ids(line) do
    case Jason.decode(line) do
      {:ok, message} -> [message]
      {:error, _} -> []
    end
  end

  def validate_outbound(message, methods_by_id) do
    root_errors = root_problems(message)

    targeted =
      cond do
        is_map_key(message, "method") and is_map_key(message, "id") ->
          method = message["method"]

          case @method_defs[method] do
            {request_def, _} -> def_problems(request_def, message["params"])
            nil -> ["unvalidated outbound method: #{method}"]
          end

        is_map_key(message, "method") and message["method"] == "session/update" ->
          def_problems("SessionNotification", message["params"])

        is_map_key(message, "method") ->
          ["unvalidated outbound notification: #{message["method"]}"]

        is_map_key(message, "result") ->
          case Map.get(methods_by_id, message["id"]) do
            nil ->
              ["response id #{inspect(message["id"])} not correlated with any method"]

            method ->
              case @method_defs[method] do
                {_, response_def} when not is_nil(response_def) ->
                  def_problems(response_def, message["result"])

                _ ->
                  ["method #{method} has no response definition to validate against"]
              end
          end

        true ->
          []
      end

    root_errors ++ targeted
  end

  def validate_inbound(line, methods_by_id) do
    case Jason.decode(line) do
      {:error, _} ->
        # parse-error scenarios intentionally carry invalid JSON
        []

      {:ok, %{"result" => _result} = message} ->
        # a client response to one of our requests: its result must satisfy
        # the method's response definition
        case Map.get(methods_by_id, message["id"]) do
          nil ->
            []

          method ->
            case @method_defs[method] do
              {_, response_def} when not is_nil(response_def) ->
                def_problems(response_def, message["result"])

              _ ->
                []
            end
        end

      {:ok, _message} ->
        # inbound requests/notifications are scripted probes, sometimes
        # deliberately malformed; their recorded responses are the evidence
        []
    end
  end

  defp root_problems(message) do
    case validate_against(resolved(), message) do
      :ok -> []
      {:error, errors} -> Enum.map(errors, &("root: " <> &1))
    end
  end

  defp def_problems(definition, value) do
    case ExJsonSchema.Validator.validate_fragment(resolved(), "#/$defs/#{definition}", value) do
      :ok ->
        []

      {:error, errors} ->
        Enum.map(errors, fn
          {message, path} -> "#{definition}: #{message} (at #{path})"
          message when is_binary(message) -> "#{definition}: #{message}"
          other -> "#{definition}: #{inspect(other)}"
        end)
    end
  rescue
    e -> ["#{definition}: validator error: " <> Exception.message(e)]
  end

  defp validate_against(schema, value) do
    case ExJsonSchema.Validator.validate(schema, value) do
      :ok -> :ok
      [] -> :ok
      errors when is_list(errors) -> {:error, errors}
      other -> {:error, [to_string(other)]}
    end
  rescue
    e -> {:error, ["validator error: " <> Exception.message(e)]}
  end

  @doc "A representative constructed session/update, for direct validation."
  def constructed_session_update do
    %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "sess-1",
        "update" => %{
          "sessionUpdate" => "available_commands_update",
          "availableCommands" => [
            %{"name" => "Example.Note.list_notes", "description" => "List notes"}
          ],
          "_meta" => %{"a2ui" => %{"type" => "list", "title" => "Notes"}},
          "surface" => %{"type" => "list", "title" => "Notes"}
        }
      }
    }
  end
end

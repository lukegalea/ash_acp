# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.JsonRpc do
  @moduledoc """
  JSON-RPC 2.0 message construction, decoding and envelope validation for the
  ACP wire.

  ACP carries one JSON-RPC message per ndjson line. This module owns the
  envelope rules only — `AshAcp.Server` owns method semantics. Parse errors
  are `-32700` with `id: null` (the id cannot be known), unknown methods
  `-32601`, invalid params `-32602`, malformed envelopes `-32600`. JSON-RPC
  batches are not part of ACP and are rejected as `-32600`.
  """

  @jsonrpc "2.0"

  @type error_code ::
          -32700 | -32600 | -32601 | -32602 | -32603 | -32800 | -32000 | -32002

  @error_messages %{
    -32700 => "Parse error",
    -32600 => "Invalid request",
    -32601 => "Method not found",
    -32602 => "Invalid params",
    -32603 => "Internal error",
    -32800 => "Request cancelled",
    -32000 => "Authentication required",
    -32002 => "Resource not found"
  }

  @doc "The wire version string every message carries."
  @spec jsonrpc() :: String.t()
  def jsonrpc, do: @jsonrpc

  @doc """
  Decodes one ndjson line. Returns `{:error, :parse}` when the line is not
  valid JSON — the caller answers with a `-32700` error, `id: null`.
  """
  @spec decode(String.t()) :: {:ok, map()} | {:error, :parse}
  def decode(line) do
    case Jason.decode(line) do
      {:ok, %{} = msg} -> {:ok, msg}
      _ -> {:error, :parse}
    end
  end

  @doc """
  Validates the envelope of a decoded message.

  * `{:request, id, method, params}` — a call expecting a response.
  * `{:notification, method, params}` — a call expecting none.
  * `{:response, id, result}` / `{:response_error, id, error}` — replies to
    our own outbound requests (e.g. `session/request_permission`).
  * `{:error, code, message, id}` — envelope is unusable.
  """
  @spec classify(map()) ::
          {:request, term(), String.t(), map() | nil}
          | {:notification, String.t(), map() | nil}
          | {:response, term(), term()}
          | {:response_error, term(), map()}
          | {:error, error_code(), String.t(), term() | nil}
  def classify(msg)

  def classify(%{"jsonrpc" => @jsonrpc, "method" => method} = msg) when is_binary(method) do
    params = Map.get(msg, "params")

    cond do
      Map.has_key?(msg, "id") -> {:request, msg["id"], method, normalize_params(params)}
      true -> {:notification, method, normalize_params(params)}
    end
  end

  def classify(%{"jsonrpc" => @jsonrpc, "id" => id, "result" => result}),
    do: {:response, id, result}

  def classify(%{"jsonrpc" => @jsonrpc, "id" => id, "error" => error}),
    do: {:response_error, id, error}

  def classify(msg) when is_map(msg) do
    id = Map.get(msg, "id")
    {:error, -32600, "Invalid request", id}
  end

  # ACP carries one message per line; a JSON array is not a valid ACP message.
  def classify(_other), do: {:error, -32600, "Invalid request", nil}

  @doc "Builds a successful response for a request id."
  @spec response(term(), term()) :: map()
  def response(id, result), do: %{"jsonrpc" => @jsonrpc, "id" => id, "result" => result}

  @doc "Builds an error response for a request id (`nil` when the id is unknowable)."
  @spec error(term(), error_code(), String.t(), term() | nil) :: map()
  def error(id, code, message, data \\ nil)

  def error(id, code, message, nil) do
    %{"jsonrpc" => @jsonrpc, "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  def error(id, code, message, data) do
    %{
      "jsonrpc" => @jsonrpc,
      "id" => id,
      "error" => %{"code" => code, "message" => message, "data" => data}
    }
  end

  @doc "Builds an error response from a standard code, with its canonical message."
  @spec std_error(term(), error_code(), term() | nil) :: map()
  def std_error(id, code, data \\ nil),
    do: error(id, code, Map.fetch!(@error_messages, code), data)

  @doc "Builds an outbound notification (no id — never answered)."
  @spec notification(String.t(), map()) :: map()
  def notification(method, params),
    do: %{"jsonrpc" => @jsonrpc, "method" => method, "params" => params}

  @doc "Builds an outbound request (the peer must answer it)."
  @spec request(term(), String.t(), map()) :: map()
  def request(id, method, params),
    do: %{"jsonrpc" => @jsonrpc, "id" => id, "method" => method, "params" => params}

  @doc "Encodes a message as one ndjson line (including the trailing newline)."
  @spec encode_line(map()) :: String.t()
  def encode_line(msg), do: Jason.encode!(msg) <> "\n"

  defp normalize_params(nil), do: nil
  defp normalize_params(params) when is_map(params), do: params
  # params of the wrong shape fail param validation downstream with -32602
  defp normalize_params(_other), do: :invalid
end

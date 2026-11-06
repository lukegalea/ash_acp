# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshAcp.KindResolver do
  @moduledoc """
  Optional host-implemented seam that names the ACP `ToolKind` of an action.

  A `tool_call` and a `session/request_permission` carry a `kind` the client
  uses to pick an icon and decide how carefully to present the call. When the
  action spec sets `:kind`, that value is used. Otherwise the library asks
  this resolver, configured as `kind_resolver:`, and falls back to its own
  default when the resolver returns `nil` or none is configured:

    * a prompt spec's read action is `read`, anything else `execute`;
    * an extension method's `{:request_permission, spec}` is `execute`.

  Configuring no resolver leaves every kind exactly as it was. A host
  typically answers from a declaration it already keeps about its actions
  (what each one reads, changes or deletes), so the kind shown to a person
  matches what the action does. The resolver only labels; it never decides
  whether an action may run.

  `kind/2` returns one of the ACP tool kinds (`read`, `edit`, `delete`,
  `move`, `search`, `execute`, `think`, `fetch`, `switch_mode`, `other`), as
  an atom or a string, or `nil` for the default. Any other value is a
  contract violation: the request it labels fails with `-32603` and the
  module is logged, as for every other seam. So does a resolver that raises.
  A broken resolver never runs an action under a kind it did not give.
  """

  @typedoc "An ACP `ToolKind`, as an atom or a string."
  @type tool_kind :: atom() | String.t()

  @callback kind(resource :: module(), action :: atom()) :: tool_kind() | nil

  @tool_kinds ~w(read edit delete move search execute think fetch switch_mode other)

  @doc "The ACP `ToolKind` values, as strings."
  @spec tool_kinds() :: [String.t()]
  def tool_kinds, do: @tool_kinds

  @doc """
  Resolves the kind of `resource`'s `action` through `resolver`, or `default`
  when there is no resolver or it returns `nil`. Raises `ArgumentError` when
  the resolver returns anything that is not an ACP tool kind.
  """
  @spec resolve(module() | nil, module() | nil, atom() | nil, tool_kind()) :: tool_kind()
  def resolve(nil, _resource, _action, default), do: default

  def resolve(resolver, resource, action, default)
      when is_atom(resource) and not is_nil(resource) and is_atom(action) and not is_nil(action) do
    case resolver.kind(resource, action) do
      nil ->
        default

      kind when is_atom(kind) or is_binary(kind) ->
        if to_string(kind) in @tool_kinds do
          kind
        else
          violation(resolver, kind)
        end

      other ->
        violation(resolver, other)
    end
  end

  def resolve(_resolver, _resource, _action, default), do: default

  defp violation(resolver, returned) do
    raise ArgumentError,
          "#{inspect(resolver)}.kind/2 must return an ACP tool kind (" <>
            Enum.join(@tool_kinds, ", ") <> ") or nil, got: #{inspect(returned)}"
  end
end

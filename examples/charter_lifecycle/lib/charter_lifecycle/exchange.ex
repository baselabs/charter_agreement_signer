# The inter-host boundary. In a real deployment this is your transport; here
# it is an explicit in-process handoff so the lifecycle runs with zero
# services. Its ONE product duty: every failure crossing it collapses to a
# closed atom — never raw protocol errors, claims content, or key material
# (docs/consumer-integration.md §3: the value-free obligation every host
# owes at its boundary).
defmodule CharterLifecycle.Exchange do
  @moduledoc false

  @type handoff :: {:ok, binary()} | {:error, :rejected}

  @spec deliver(binary()) :: handoff()
  def deliver(compact) when is_binary(compact), do: {:ok, compact}

  # The collapse: anything a host tried to hand over that is not a compact
  # becomes :rejected — with NO detail riding along. A real transport's
  # error channel gets the same treatment.
  def deliver(_not_a_compact), do: {:error, :rejected}

  @spec deliver_result({:ok, %{optional(atom()) => binary()}} | {:error, atom() | tuple()}) ::
          {:ok, binary()} | {:error, atom()}
  def deliver_result({:ok, %{kind: kind}}) when is_atom(kind), do: deliver(kind)

  def deliver_result({:ok, map}) when is_map(map) do
    case Enum.map(map, fn {_kind, compact} -> compact end) do
      [compact] -> deliver(compact)
      _ -> {:error, :rejected}
    end
  end

  def deliver_result({:error, reason}) when is_atom(reason), do: {:error, reason}
  def deliver_result({:error, {kind, _detail}}) when is_atom(kind), do: {:error, kind}
  def deliver_result(_off_spec), do: {:error, :rejected}
end

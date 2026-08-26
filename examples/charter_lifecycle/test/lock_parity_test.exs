defmodule CharterLifecycle.LockParityTest do
  @moduledoc """
  Protocol lock parity: the example resolves EXACTLY the CAP version the
  library locked. The example is the integration canary — if the two locks
  drift, the example proves nothing about the library's tested span.
  """

  use ExUnit.Case, async: true

  test "both mix.locks resolve the same charter_agreement_protocol version" do
    example_lock = File.read!("./mix.lock")
    library_lock = File.read!(Path.expand("../../mix.lock", File.cwd!()))

    example_version = protocol_version(example_lock)
    library_version = protocol_version(library_lock)

    assert example_version != nil and example_version == library_version,
           "CAP lock drift: example=#{inspect(example_version)} library=#{inspect(library_version)} " <>
             "— run mix deps.get in both projects and commit the locks together"
  end

  defp protocol_version(lock_source) do
    Regex.run(
      ~r/"charter_agreement_protocol":\s*\{:hex,\s*:charter_agreement_protocol,\s*"([^"]+)"/,
      lock_source
    )
    |> case do
      [_, version] -> version
      nil -> nil
    end
  end
end

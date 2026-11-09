defmodule CharterLifecycle.LockParityTest do
  @moduledoc "Protocol lock parity between the example and library."
  use ExUnit.Case, async: true

  test "the example and library use the same tested protocol source" do
    dependency =
      Enum.find(Mix.Project.config()[:deps], &(elem(&1, 0) == :charter_agreement_protocol))

    assert elem(dependency, 1) == "~> 1.0.0"

    if tuple_size(dependency) == 3 and Keyword.has_key?(elem(dependency, 2), :path) do
      assert to_string(Application.spec(:charter_agreement_protocol, :vsn)) == "1.0.0"
    else
      example_lock = File.read!("mix.lock")
      library_lock = File.read!(Path.expand("../../mix.lock", File.cwd!()))
      assert protocol_version(example_lock) == "1.0.0"
      assert protocol_version(library_lock) == "1.0.0"
    end
  end

  defp protocol_version(lock_source) do
    case Regex.run(
           ~r/"charter_agreement_protocol":\s*\{:hex,\s*:charter_agreement_protocol,\s*"([^"]+)"/,
           lock_source
         ) do
      [_, version] -> version
      nil -> nil
    end
  end
end

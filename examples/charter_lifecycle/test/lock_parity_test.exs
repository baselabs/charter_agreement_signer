defmodule CharterLifecycle.LockParityTest do
  use ExUnit.Case, async: true

  test "both projects resolve the same local CAP build" do
    {:charter_agreement_protocol, options} =
      List.keyfind(Mix.Project.config()[:deps], :charter_agreement_protocol, 0)

    example_path = Path.expand(options[:path])
    library_root = Path.expand("../..")
    assert example_path == Path.expand("../cap-060", library_root)
    assert Application.spec(:charter_agreement_protocol, :vsn) == ~c"0.6.0"

    for root <- [File.cwd!(), library_root] do
      refute File.read!(Path.join(root, "mix.lock")) =~ "\"charter_agreement_protocol\""
    end
  end
end

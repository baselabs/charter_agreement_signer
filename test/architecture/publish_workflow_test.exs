defmodule PublishWorkflowTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "publication only uploads verified archives without loading project code under the key" do
    workflow = File.read!(Path.join(@root, ".github/workflows/publish.yml"))
    refute workflow =~ "hex.publish"
    refute workflow =~ "push:"
    refute workflow =~ "tags:"
    assert workflow =~ "workflow_dispatch:"
    assert workflow =~ "timeout-minutes: 90 # no green run yet"
    assert workflow =~ "install-hex: false"
    assert workflow =~ "mix local.hex 2.7.0 --force"
    assert workflow =~ "mix docs --warnings-as-errors --formatter html"

    steps = String.split(workflow, ~r/^      - /m) |> tl()
    keyed_steps = Enum.filter(steps, &String.contains?(&1, "HEX_API_KEY"))
    assert [keyed] = keyed_steps
    assert keyed =~ "HEX_API_KEY: ${{ secrets.HEX_API_KEY }}"

    assert length(Regex.scan(~r/HEX_API_KEY/, workflow)) ==
             length(Regex.scan(~r/HEX_API_KEY/, keyed))

    assert keyed =~ "working-directory: release-assets"
    assert keyed =~ "mix run --no-mix-exs ../scripts/hex_upload.exs"
    refute keyed =~ "mix hex.build"
    refute keyed =~ "mix docs"

    assert [artifact] = Enum.filter(steps, &String.contains?(&1, "actions/upload-artifact@"))
    assert artifact =~ "name: release-assets\n"
    assert artifact =~ "path: release-assets/*"
    assert artifact =~ "if-no-files-found: error"
    assert workflow =~ "id: plan"
    assert workflow =~ "hex_release_state.exs\" --plan"
    assert workflow =~ "hex_release_state.exs\" --served"

    # The package is the release; docs builds are not byte-stable, so the registry state
    # reads never receive the docs archive and never compare docs bytes.
    state_steps = Enum.filter(steps, &String.contains?(&1, "hex_release_state.exs"))
    assert length(state_steps) == 2
    for step <- state_steps, do: refute(step =~ "-docs.tar.gz")

    assert workflow =~ "if: always()"

    {artifact_position, _} = :binary.match(workflow, "actions/upload-artifact@")
    {key_position, _} = :binary.match(workflow, "HEX_API_KEY")
    assert artifact_position < key_position
  end

  test "only the default-branch warmer writes qualification caches" do
    warmer = File.read!(Path.join(@root, ".github/workflows/cache-warmer.yml"))
    ci = File.read!(Path.join(@root, ".github/workflows/ci.yml"))
    assert warmer =~ "push:\n    branches: [master]"
    assert warmer =~ "actions/cache/save@"
    assert ci =~ "actions/cache/restore@"
    refute ci =~ "actions/cache/save@"
    refute ci =~ ~r/uses: actions\/cache@/
  end
end

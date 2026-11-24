defmodule PublishWorkflowTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "every workflow preserves failing shell commands and pins container bytes" do
    workflows = Path.wildcard(Path.join(@root, ".github/workflows/*.{yml,yaml}"))
    assert workflows != []

    for path <- workflows do
      workflow = File.read!(path)
      assert workflow =~ ~r/^defaults:\n  run:\n    shell: bash\n/m, path

      for [defaults] <- Regex.scan(~r/^    defaults:\n(?:^      .*\n|^\n)*/m, workflow) do
        assert defaults =~ "        shell: bash\n", path
        assert defaults =~ "        working-directory:", path
      end

      for [_, image] <- Regex.scan(~r/^    container: ([^\n]+)$/m, workflow) do
        assert image =~ ~r/\Aubuntu:(?:24|26)\.04@sha256:[0-9a-f]{64}\z/, path
      end

      refute workflow =~ ~r/\|\|\s*true\b/, path
      refute workflow =~ ~r/^\s*(?:run: )?(?:echo|for)\b[^\n]*\$\(/m, path
      refute workflow =~ "<(", path
    end

    if File.dir?(Path.join(@root, ".github/actions/hex-org-login")) do
      ci = File.read!(Path.join(@root, ".github/workflows/ci.yml"))
      assert ci =~ ~r/^    container: ubuntu:26\.04@sha256:[0-9a-f]{64}$/m

      if File.exists?(Path.join(@root, "scripts/assert_limited_substrate.exs")) do
        [_, limited] = Regex.run(~r/^  capability-limited:\n(.*?)(?=^  \S|\z)/ms, ci)
        assert limited =~ ~r/^    container: ubuntu:24\.04@sha256:[0-9a-f]{64}$/m
        assert limited =~ "scripts/assert_limited_substrate.exs"
      end
    end

    for relative <- ["scripts/verifier_source.exs", "scripts/typescript_sources.exs"],
        path = Path.join(@root, relative),
        File.exists?(path) do
      script = File.read!(path)
      refute script =~ ~s|System.cmd("sh"|, path
      assert script =~ ~r/System\.cmd\("bash",\s*\[\s*"-euo",\s*"pipefail",\s*"-c"/, path
    end

    for path <- Path.wildcard(Path.join(@root, "scripts/*.sh")) do
      script = File.read!(path)
      assert String.starts_with?(script, "#!/usr/bin/env bash\n"), path
      assert script =~ ~r/^set -euo pipefail$/m, path
    end
  end

  test "qualification requires workflow syntax and secret scanning" do
    ci = File.read!(Path.join(@root, ".github/workflows/ci.yml"))

    [_, needs] =
      Regex.run(~r/^  qualified:\n(?:^    [^\n]*\n)*?^    needs: \[([^\n]+)\]$/m, ci)

    jobs = String.split(needs, ", ")
    assert "workflow-syntax" in jobs
    assert "secret-scan" in jobs
  end

  test "CI reads exact runtime versions only through the pinned shared reader" do
    path = Path.join(@root, "scripts/toolchain.sh")
    script = File.read!(path)

    assert Base.encode16(:crypto.hash(:sha256, script), case: :lower) ==
             "25bbfa023b7f031256428b498fe300fcc460988fea81277072355e4c0d933764"

    # The committed mode, not the checkout's: a checkout's permission bits follow its umask.
    args = ["ls-files", "--stage", "--", "scripts/toolchain.sh"]
    {stage, 0} = System.cmd("git", args, cd: @root)
    assert String.starts_with?(stage, "100755 "), stage

    for path <- Path.wildcard(Path.join(@root, ".github/workflows/*.{yml,yaml}")) do
      workflow = File.read!(path)
      refute workflow =~ ~r/\b(?:node-|bun-)?version-file:/, path
      refute workflow =~ ~r/\bawk\b/, path
      refute workflow =~ ~r/\b(?:bash|sh)\s+[^\n]*scripts\/toolchain\.sh/, path

      refute workflow =~
               ~r/\b(?:elixir|otp|node|bun|golang|elixir-version|otp-version|node-version|bun-version|go-version|EXPECTED_ELIXIR|EXPECTED_OTP|EXPECTED_NODE|EXPECTED_BUN|EXPECTED_GO):\s*["']?[0-9]/,
             path

      for line <- String.split(workflow, "\n"),
          not String.starts_with?(String.trim(line), "#"),
          String.contains?(line, ".tool-versions") do
        assert line =~ "scripts/toolchain.sh ", path
      end

      for [job] <- Regex.scan(~r/^  [\w-]+:\n.*?(?=^  [\w-]+:\n|\z)/ms, workflow),
          job =~
            ~r/uses: (?:erlef\/setup-beam|actions\/setup-node|actions\/setup-go|oven-sh\/setup-bun)@/ do
        assert job =~ "run: scripts/toolchain.sh ", path
        assert job =~ "scripts/toolchain.sh --installed ", path

        for {setup, tool} <- [
              {"erlef/setup-beam@", "elixir"},
              {"erlef/setup-beam@", "erlang"},
              {"actions/setup-node@", "nodejs"},
              {"actions/setup-go@", "golang"}
            ],
            String.contains?(job, setup) do
          assert job =~ ~s("#{tool}=$), path
        end

        for [_, value] <-
              Regex.scan(
                ~r/^          (?:elixir|otp|node|bun|go)-version: ([^\n]+)$/m,
                job
              ) do
          assert String.starts_with?(value, "${{ "), path
        end
      end
    end
  end

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

    publish =
      workflow
      |> String.split(~r/^(?=\S|  \S)/m)
      |> Enum.find(&String.starts_with?(&1, "  publish:\n"))

    assert publish, "expected a publish job"
    steps = String.split(publish, ~r/^      - /m) |> tl()
    keyed_steps = Enum.filter(steps, &String.contains?(&1, "HEX_API_KEY"))
    assert [keyed] = keyed_steps
    assert keyed =~ "HEX_API_KEY: ${{ secrets.HEX_API_KEY }}"

    assert length(Regex.scan(~r/HEX_API_KEY/, workflow)) ==
             length(Regex.scan(~r/HEX_API_KEY/, keyed))

    assert keyed =~ ~r/^        working-directory: release-assets$/m
    refute keyed =~ "mix hex.build"
    refute keyed =~ "mix docs"

    assert [artifact] = Enum.filter(steps, &String.contains?(&1, "actions/upload-artifact@"))
    assert artifact =~ "name: release-assets\n"
    assert artifact =~ "path: release-assets/*"
    assert artifact =~ "if-no-files-found: error"
    assert artifact =~ "retention-days: 7\n"
    assert workflow =~ "run: bash scripts/build_release_sbom.sh"
    assert workflow =~ "id: plan"
    assert workflow =~ "hex_release_state.exs\" --plan"
    assert workflow =~ "hex_release_state.exs\" --served"

    changelog_name = "name: Refuse a package whose changelog is not stamped for its version\n"
    assert [changelog] = Enum.filter(steps, &String.starts_with?(&1, changelog_name))
    package = "charter_agreement_signer"
    package_archive = package <> ~S(-${VERSION}.tar)
    archive = ~s("release-assets/#{package_archive}")
    archive_argument = Regex.escape("release-assets/#{package_archive}")

    invocation =
      ~r/python3[ \t]+-I[ \t]+-[ \t]+"(?:\.\/|\$GITHUB_WORKSPACE\/)?#{archive_argument}"[ \t]+[^\n]*<</

    assert length(Regex.scan(invocation, workflow)) == 1

    export_version = ~S(echo "VERSION=$version" >> "$GITHUB_ENV")
    assert [version_step] = Enum.filter(steps, &String.contains?(&1, export_version))
    assert version_step =~ ~S|version=$(sed -n 's/^  @version "\([^"]*\)".*$/\1/p' mix.exs)|

    normalized =
      changelog
      |> String.trim_trailing("\n")
      |> String.replace("\n      ", "\n")
      |> String.replace(archive, "path/to/package-archive", global: false)

    # The dedented YAML from infra 6f19bd49, baselabs/docs/ci.md:360–402.
    assert Base.encode16(:crypto.hash(:sha256, "- " <> normalized <> "\n"), case: :lower) ==
             "2a912ae3e07700555d8827da491b8875207341808b4a6c1137c07129f0cbfa30"

    # The docs path is a read-back destination, never an archive to compare.
    assert [plan, served] = Enum.filter(steps, &String.contains?(&1, "hex_release_state.exs"))
    plan_command =
      ~s(mix run --no-mix-exs "$GITHUB_WORKSPACE/scripts/hex_release_state.exs" --plan #{package} "$VERSION" "$GITHUB_WORKSPACE/release-assets/#{package_archive}")

    upload_command =
      ~s(mix run --no-mix-exs ../scripts/hex_upload.exs "${flags[@]}" #{package} "$VERSION" "#{package_archive}" "#{package}-${VERSION}-docs.tar.gz")

    assert plan_command in shell_lines(plan)
    assert upload_command in shell_lines(keyed)
    refute plan =~ "-docs.tar.gz"
    refute plan =~ "--commit"
    refute plan =~ "--clone"
    refute plan =~ "--docs-output"
    assert served =~ "id: served"
    assert served =~ ~s(--commit "$GITHUB_SHA" --clone "$GITHUB_WORKSPACE")
    assert served =~ ~r/--docs-output "\$GITHUB_WORKSPACE\/release-assets\/[^" ]+-docs\.tar\.gz"/
    assert length(Regex.scan(~r/-docs\.tar\.gz/, served)) == 1

    assert [provenance] = Enum.filter(steps, &String.contains?(&1, "doc/release.json"))
    assert provenance =~ "JSON.encode!"
    assert provenance =~ ~s|"package" => System.fetch_env!("DOCS_PACKAGE")|
    assert provenance =~ ~s|"version" => System.fetch_env!("VERSION")|
    assert provenance =~ ~s|"commit" => System.fetch_env!("GITHUB_SHA")|

    release_step =
      ~r/actions\/(?:attest[\w-]*|upload-artifact)@|gh attestation\b|run: bash scripts\/build_release_sbom\.sh|hex_release_state\.exs" --plan\b|hex_upload\.exs\b/

    for step <- Enum.take_while(steps, &(&1 != changelog)) do
      refute step =~ release_step
    end

    {docs_position, _} = :binary.match(publish, "mix docs --warnings-as-errors")
    {provenance_position, _} = :binary.match(publish, "doc/release.json")
    {archive_position, _} = :binary.match(publish, "tar --sort=name")
    {version_position, _} = :binary.match(publish, version_step)
    {package_position, _} = :binary.match(publish, "mix hex.build --output " <> archive)
    {served_position, _} = :binary.match(publish, "id: served")
    {checksum_position, _} = :binary.match(publish, "name: Record release checksums")
    {artifact_position, _} = :binary.match(publish, "actions/upload-artifact@")
    {changelog_position, _} = :binary.match(publish, changelog)
    {plan_position, _} = :binary.match(publish, plan)
    {upload_position, _} = :binary.match(publish, keyed)

    {inspection_position, _} =
      :binary.match(publish, "name: Build and inspect the package and consumer")

    assert version_position < docs_position
    assert inspection_position < package_position
    assert docs_position < provenance_position
    assert provenance_position < package_position
    assert package_position < archive_position
    assert archive_position < changelog_position
    assert plan_position < upload_position
    assert served_position < checksum_position
    assert checksum_position < artifact_position
    assert String.trim(List.last(steps)) =~ "if: always()"
    assert List.last(steps) =~ "name: Remove release archives"
  end

  test "additional release assets belong to the published commit" do
    workflow = File.read!(Path.join(@root, ".github/workflows/publish.yml"))
    script = File.read!(Path.join(@root, "scripts/build_release_sbom.sh"))
    assert script =~ "--exclude-system-dependencies"
    assert script =~ "set -euo pipefail"
    assert script =~ "mix sbom.cyclonedx --only prod"
    assert script =~ "--classification library --schema 1.6 --format json"
    assert workflow =~ "run: bash scripts/build_release_sbom.sh"
    refute workflow =~ "mix sbom.cyclonedx"

    steps = String.split(workflow, ~r/^      - /m) |> tl()
    assert [proof] = Enum.filter(steps, &String.contains?(&1, "gh attestation verify"))
    assert proof =~ "GH_TOKEN: ${{ github.token }}"
    assert proof =~ "PUBLISHED_COMMIT: ${{ steps.served.outputs.commit }}"
    assert proof =~ "--repo baselabs/charter_agreement_signer"
    assert proof =~ ~s(--source-digest "$PUBLISHED_COMMIT")
    assert proof =~ ~s(if [ "$PUBLISHED_COMMIT" != "$GITHUB_SHA" ]; then)

    assert proof =~
             ~s(git diff --quiet "$PUBLISHED_COMMIT" "$GITHUB_SHA" -- mix.exs mix.lock scripts/build_release_sbom.sh; then)

    assert proof =~ "the fix is a new version"
    assert workflow =~ "attestations: write"
    {served_position, _} = :binary.match(workflow, "id: served")
    {proof_position, _} = :binary.match(workflow, "name: Verify release assets")
    {checksum_position, _} = :binary.match(workflow, "name: Record release checksums")
    {attest_position, _} = :binary.match(workflow, "name: Attest release SBOM")
    {upload_position, _} = :binary.match(workflow, "name: Upload only the missing")
    assert attest_position < upload_position
    assert served_position < proof_position
    assert proof_position < checksum_position
  end

  test "only the default-branch warmer writes qualification caches" do
    warmer = File.read!(Path.join(@root, ".github/workflows/cache-warmer.yml"))
    ci = File.read!(Path.join(@root, ".github/workflows/ci.yml"))
    assert warmer =~ "push:\n    branches: [master]"
    assert warmer =~ "actions/cache/save@"
    assert ci =~ "actions/cache/restore@"
    refute ci =~ "actions/cache/save@"
    refute ci =~ ~r/uses: actions\/cache@/

    [[matrix]] =
      Regex.scan(
        ~r/^      - name: Compose the qualification matrix\n.*?(?=^      - |^  \S|\z)/ms,
        ci
      )

    assert warmer =~ matrix

    key =
      "key: plt-${{ runner.os }}-${{ runner.arch }}-otp-${{ matrix.otp }}-elixir-${{ matrix.elixir_release }}-${{ hashFiles('mix.lock') }}"

    assert ci =~ key
    assert warmer =~ key
    assert ci =~ "BEAM_MATRIX: ${{ needs.toolchain.outputs.beam_matrix }}"
    assert ci =~ "cover/standard-{lane['elixir_release']}-{lane['otp']}.coverdata"
  end

  defp shell_lines(step) do
    step
    |> String.replace(~r/\\\n +/, "")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
  end
end

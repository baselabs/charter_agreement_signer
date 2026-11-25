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

    verifier_source = Path.join(@root, "scripts/verifier_source.exs")

    if File.exists?(verifier_source) do
      script = File.read!(verifier_source)
      refute script =~ ~s|System.cmd("sh"|, verifier_source
      strict_bash = ~r/System\.cmd\("bash",\s*\[\s*"-euo",\s*"pipefail",\s*"-c"/
      assert script =~ strict_bash, verifier_source
    end

    for path <- Path.wildcard(Path.join(@root, "scripts/*.sh")) do
      script = File.read!(path)
      assert String.starts_with?(script, "#!/usr/bin/env bash\n"), path
      assert script =~ ~r/^set -euo pipefail$/m, path
    end
  end

  test "TypeScript source materialization drives Git without a shell or tar" do
    path = Path.join(@root, "scripts/typescript_sources.exs")
    script = File.read!(path)

    assert script =~ ~s|System.cmd("git"|
    refute script =~ ~r/System\.cmd\(\s*"(?:sh|bash|tar)"/
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
        if Path.basename(path) == "publish.yml" and
             job =~ ~r/\A  (?:upload|read-back):\n/ do
          assert job =~ "elixir-version: ${{ needs.build.outputs.elixir }}", path
          assert job =~ "otp-version: ${{ needs.build.outputs.otp }}", path
          assert job =~ "version-type: strict", path
        else
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

  test "the qualification job guards the release checkout and workflow-owned scripts" do
    workflow = File.read!(Path.join(@root, ".github/workflows/publish.yml"))

    assert workflow =~
             ~r/workflow_dispatch:\n    inputs:\n      release_commit:\n        description: [^\n]+\n        required: true\n        type: string\n/

    assert [release, build, upload, readback] = release_jobs(workflow)

    actor_filter =
      ~s|if: contains(fromJSON('["corepay","palermo-git"]'), github.actor) && contains(fromJSON('["corepay","palermo-git"]'), github.triggering_actor)|

    for job <- [release, build, upload, readback] do
      assert job =~ actor_filter
    end

    assert release =~ "checks: read"
    assert release =~ "GH_TOKEN: ${{ github.token }}"

    assert release =~ ~s(.conclusion == "success")
    assert release =~ "| .head_sha"

    checks = [
      "refs/heads/$DEFAULT_BRANCH",
      "^[0-9a-f]{40}$",
      "/compare/",
      "check-runs?check_name=qualified",
      "/contents/mix.exs?ref=$RELEASE_COMMIT",
      "matching-refs/tags/"
    ]

    positions =
      Enum.map(checks, fn marker ->
        assert {position, _length} = :binary.match(release, marker)
        position
      end)

    assert positions == Enum.sort(positions)
    refute release =~ "actions/checkout"
    refute release =~ "mix hex.build"
    assert build =~ "needs: release"
    assert upload =~ "needs: [release, build]"
    assert readback =~ "needs: [release, build, upload]"
    assert upload =~ "environment: publish"
    assert length(Regex.scan(~r/^    environment:/m, workflow)) == 1
    refute build =~ "environment:"
    refute readback =~ "environment:"
    refute release <> build <> readback =~ "secrets."
    refute upload =~ "inputs.release_commit"
    refute upload =~ "scripts/toolchain.sh"
    refute upload =~ ~r/mix (?:deps|docs|hex\.build)/
    assert upload =~ "ref: ${{ github.sha }}"
    assert upload =~ "sha256sum --check --strict SHA256SUMS"
    assert build =~ "ref: ${{ inputs.release_commit }}"
    assert readback =~ "ref: ${{ inputs.release_commit }}"
    assert build =~ "fetch-depth: 0"

    for job <- [build, readback],
        script <- ["hex_release_state.ex", "hex_release_state.exs"] do
      assert job =~ ~s(git show "$GITHUB_SHA:scripts/#{script}")
    end

    assert {checkout, _} = :binary.match(build, "actions/checkout@")
    assert {scripts, _} = :binary.match(build, "Load release scripts from the workflow revision")
    assert {archive, _} = :binary.match(build, "mix hex.build")
    assert checkout < scripts and scripts < archive
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

    [_release, build, upload, readback] = release_jobs(workflow)
    steps = Enum.flat_map([build, upload, readback], &release_steps/1)
    keyed_steps = Enum.filter(steps, &String.contains?(&1, "HEX_API_KEY"))
    assert [keyed] = keyed_steps
    assert keyed =~ "HEX_API_KEY: ${{ secrets.HEX_API_KEY }}"

    assert length(Regex.scan(~r/HEX_API_KEY/, workflow)) ==
             length(Regex.scan(~r/HEX_API_KEY/, keyed))

    assert keyed =~ "        working-directory: ${{ runner.temp }}\n"
    refute keyed =~ "mix hex.build"
    refute keyed =~ "mix docs"

    assert [artifact] =
             Enum.filter(
               release_steps(readback),
               &String.contains?(&1, "actions/upload-artifact@")
             )

    assert artifact =~ "name: release-assets\n"
    assert artifact =~ ~s(release-assets/charter_agreement_signer-${{ env.VERSION }}.tar)
    assert artifact =~ ~s(release-assets/charter_agreement_signer-${{ env.VERSION }}-docs.tar.gz)
    assert artifact =~ "release-assets/SHA256SUMS"
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

    assert build =~ "VERSION: ${{ needs.release.outputs.version }}"

    normalized =
      changelog
      |> String.trim_trailing("\n")
      |> String.replace("\n      ", "\n")
      |> String.replace(archive, "path/to/package-archive", global: false)

    # The dedented YAML from infra 6f19bd49, baselabs/docs/ci.md:360–402.
    assert Base.encode16(:crypto.hash(:sha256, "- " <> normalized <> "\n"), case: :lower) ==
             "2a912ae3e07700555d8827da491b8875207341808b4a6c1137c07129f0cbfa30"

    # The docs path is a read-back destination, never an archive to compare.
    assert [plan, served] =
             Enum.filter(
               steps,
               &(String.contains?(&1, ~s(hex_release_state.exs")) and
                   String.contains?(&1, "mix run --no-mix-exs"))
             )

    plan_command =
      ~s(mix run --no-mix-exs "$RUNNER_TEMP/release-workflow/hex_release_state.exs" --plan #{package} "$VERSION" "$GITHUB_WORKSPACE/release-assets/#{package_archive}")

    upload_command =
      ~s(mix run --no-mix-exs "$GITHUB_WORKSPACE/release-workflow/scripts/hex_upload.exs" "${flags[@]}" #{package} "$VERSION" "$GITHUB_WORKSPACE/release-assets/#{package_archive}" "$GITHUB_WORKSPACE/release-assets/#{package}-${VERSION}-docs.tar.gz")

    assert plan_command in shell_lines(plan)
    assert upload_command in shell_lines(keyed)

    assert ~S|if [ "$PACKAGE_STATE" = upload ]; then flags+=(--package); fi| in shell_lines(keyed)
    assert ~S|if [ "$DOCS_STATE" = upload ]; then flags+=(--docs); fi| in shell_lines(keyed)
    refute plan =~ "-docs.tar.gz"
    refute plan =~ "--commit"
    refute plan =~ "--clone"
    refute plan =~ "--docs-output"
    assert served =~ "id: served"
    assert served =~ ~s(--commit "$RELEASE_COMMIT" --clone "$GITHUB_WORKSPACE")
    assert served =~ ~r/--docs-output "\$GITHUB_WORKSPACE\/release-assets\/[^" ]+-docs\.tar\.gz"/
    assert length(Regex.scan(~r/-docs\.tar\.gz/, served)) == 1

    assert [provenance] = Enum.filter(steps, &String.contains?(&1, "doc/release.json"))
    assert provenance =~ "JSON.encode!"
    assert provenance =~ ~s|"package" => System.fetch_env!("DOCS_PACKAGE")|
    assert provenance =~ ~s|"version" => System.fetch_env!("VERSION")|
    assert provenance =~ ~s|"commit" => System.fetch_env!("RELEASE_COMMIT")|

    release_step =
      ~r/actions\/(?:attest[\w-]*|upload-artifact)@|gh attestation\b|run: bash scripts\/build_release_sbom\.sh|hex_release_state\.exs" --plan\b|mix run --no-mix-exs[^\n]*hex_upload\.exs\b/

    for step <- Enum.take_while(steps, &(&1 != changelog)) do
      refute step =~ release_step
    end

    {docs_position, _} = :binary.match(workflow, "mix docs --warnings-as-errors")
    {provenance_position, _} = :binary.match(workflow, "doc/release.json")
    {archive_position, _} = :binary.match(workflow, "tar --sort=name")
    {checkout_position, _} = :binary.match(workflow, "ref: ${{ inputs.release_commit }}")
    {package_position, _} = :binary.match(workflow, "mix hex.build --output " <> archive)
    {served_position, _} = :binary.match(workflow, "id: served")
    {checksum_position, _} = :binary.match(workflow, "name: Record release checksums")
    {artifact_position, _} = :binary.match(workflow, "name: Upload consumer release assets")
    {changelog_position, _} = :binary.match(workflow, changelog)
    {plan_position, _} = :binary.match(workflow, plan)
    {upload_position, _} = :binary.match(workflow, keyed)

    {inspection_position, _} =
      :binary.match(workflow, "name: Build and inspect the package and consumer")

    assert checkout_position < docs_position
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
    assert proof =~ ~s(--repo "$GITHUB_REPOSITORY" --signer-workflow "$signer")
    assert proof =~ "baselabs/charter_agreement_signer/.github/workflows/publish.yml"
    assert proof =~ ~s(--source-ref "$GITHUB_REF" --predicate-type "$predicate" --format json)
    assert proof =~ ~s(.verificationResult.statement.predicate.release_commit == $commit)
    assert proof =~ ~s(jq -e --arg commit "$PUBLISHED_COMMIT")
    assert proof =~ ~s(test "$PUBLISHED_COMMIT" != "$RELEASE_COMMIT")

    assert [source] =
             Enum.filter(steps, &String.contains?(&1, "name: Attest the release source commit"))

    assert source =~
             "subject-path: release-assets/charter_agreement_signer-${{ env.VERSION }}.tar"

    assert source =~ ~s|predicate: '{"release_commit":"${{ inputs.release_commit }}"}'|
    assert [_, predicate] = Regex.run(~r/predicate-type: (\S+)/, source)
    assert proof =~ ~s(predicate="#{predicate}")
    assert proof =~ ~s(--source-digest "$PUBLISHED_COMMIT")
    assert proof =~ ~s(if [ "$PUBLISHED_COMMIT" != "$RELEASE_COMMIT" ]; then)

    assert proof =~
             ~s(git diff --quiet "$PUBLISHED_COMMIT" "$RELEASE_COMMIT" -- mix.exs mix.lock scripts/build_release_sbom.sh; then)

    assert proof =~ "the fix is a new version"
    assert workflow =~ "attestations: write"
    {served_position, _} = :binary.match(workflow, "id: served")
    {proof_position, _} = :binary.match(workflow, "name: Verify release assets")
    {checksum_position, _} = :binary.match(workflow, "name: Record release checksums")
    {attest_position, _} = :binary.match(workflow, "name: Attest release SBOM")
    {upload_position, _} = :binary.match(workflow, "name: Apply the verified archive upload plan")
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

  defp release_jobs(workflow) do
    [_header | jobs] = String.split(workflow, ~r/^  (?:release|build|upload|read-back):\n/m)
    jobs
  end

  defp release_steps(job), do: String.split(job, ~r/^      - /m) |> tl()

  defp shell_lines(step) do
    step
    |> String.replace(~r/\\\n +/, "")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
  end
end

defmodule PublishWorkflowTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @action_sha "654fcd0ef63daf8e3f79dfeb4ca900adffd0d4e2"
  @action "baselabs/.github/.github/actions/hex-publish@" <> @action_sha
  @hex_version "/#{@action_sha}/.github/actions/hex-publish/hex-version"
  @actor ~s|contains(fromJSON('["corepay","palermo-git"]'), github.actor)|
  @triggering_actor ~s|contains(fromJSON('["corepay","palermo-git"]'), github.triggering_actor)|
  @actor_gate @actor <> " && " <> @triggering_actor

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

  test "workflow runtimes come from the committed version declarations" do
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
        if Path.basename(path) == "publish.yml" do
          assert line =~ "git show HEAD:.tool-versions | python3 -I -c", path
        else
          assert line =~ "scripts/toolchain.sh ", path
        end
      end

      for [job] <- Regex.scan(~r/^  [\w-]+:\n.*?(?=^  [\w-]+:\n|\z)/ms, workflow),
          job =~
            ~r/uses: (?:erlef\/setup-beam|actions\/setup-node|actions\/setup-go|oven-sh\/setup-bun)@/ do
        if Path.basename(path) == "publish.yml" and
             job =~ ~r/\A  (?:upload|read-back):\n/ do
          assert_publish_runtime(job)
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

  test "qualification retains archives for the declared package" do
    ci = File.read!(Path.join(@root, ".github/workflows/ci.yml"))
    jobs = workflow_jobs(ci)
    qualify = Map.fetch!(jobs, "hex-qualification")
    qualified = Map.fetch!(jobs, "qualified")

    assert qualified =~ ~r/^    needs: \[[^\n]*\bhex-qualification\b[^\n]*\]$/m
    assert qualify =~ "timeout-minutes: 90 # no green run yet"
    assert qualify =~ "uses: #{@action}"
    assert qualify =~ @hex_version
    assert qualify =~ "operation: qualify"
    assert qualify =~ "package: charter_agreement_signer"
    assert qualify =~ "package-directory: ."
    refute qualify =~ "environment:"

    declaration = Path.join(@root, ".github/hex-packages.json") |> File.read!() |> JSON.decode!()

    assert %{
             "charter_agreement_signer" => %{
               "app" => "charter_agreement_signer",
               "directory" => "."
             }
           } = declaration
  end

  test "upload and read-back use the same qualification under separate permissions" do
    workflow = File.read!(Path.join(@root, ".github/workflows/publish.yml"))
    assert workflow =~ ~r/^on:\n  workflow_dispatch:\n/m
    assert workflow =~ ~r/^      release_commit:\n.*?^        required: true$/ms
    assert workflow =~ ~r/^      qualification_run:\n.*?^        required: false$/ms
    jobs = workflow_jobs(workflow)
    assert Enum.sort(Map.keys(jobs)) == ["read-back", "upload"]
    %{"upload" => upload, "read-back" => read_back} = jobs

    for job <- [upload, read_back] do
      assert job =~ "if: #{@actor_gate}"
      assert job =~ "uses: #{@action}"
      assert job =~ @hex_version
      assert job =~ "contents: read"
      assert job =~ "actions: read"
      assert job =~ "ref: ${{ inputs.release_commit }}"
      assert job =~ "fetch-depth: 0"
      assert job =~ "persist-credentials: false"
      assert job =~ "package: charter_agreement_signer"
      assert job =~ "package-directory: ."
      assert job =~ "release-commit: ${{ inputs.release_commit }}"
    end

    assert upload =~ "environment: publish"
    assert upload =~ "id-token: write"
    assert upload =~ "operation: upload"
    assert upload =~ "qualification-run: ${{ inputs.qualification_run }}"
    assert upload =~ "qualification-run: ${{ steps.upload.outputs.qualification-run }}"
    assert upload =~ "qualification-sha256: ${{ steps.upload.outputs.qualification-sha256 }}"

    key = "organization-read-key: ${{ secrets.HEX_ORG_KEY_PUBLISH_API_READ }}"
    assert upload =~ key
    assert length(:binary.matches(workflow, "HEX_ORG_KEY_PUBLISH_API_READ")) == 1
    refute workflow =~ "HEX_API_KEY"
    refute workflow =~ "HEX_ORG_KEY_BASELABS"
    refute upload =~ "scripts/"
    refute upload =~ ~r/\bmix (?:deps|compile|docs|run|hex\.)/
    refute upload =~ "uses: ./"
    assert upload =~ "install-rebar: false"

    refute read_back =~ "environment:"
    assert read_back =~ "id-token: write"
    assert read_back =~ "needs: upload"
    assert read_back =~ "operation: read-back"
    assert read_back =~ "qualification-run: ${{ needs.upload.outputs.qualification-run }}"
    assert read_back =~ "qualification-sha256: ${{ needs.upload.outputs.qualification-sha256 }}"
    assert read_back =~ "release-assets-directory: ${{ github.workspace }}/release-assets"
    assert read_back =~ "name: release-assets"
    assert read_back =~ "retention-days: 7"
  end

  test "release assets use the commit verified in the served archives" do
    workflow = File.read!(Path.join(@root, ".github/workflows/publish.yml"))
    %{"read-back" => read_back} = workflow_jobs(workflow)
    [_, assets] = String.split(read_back, "operation: read-back", parts: 2)

    assert assets =~ "PUBLISHED_COMMIT: ${{ steps.served.outputs.commit }}"
    assert assets =~ ~S|test "$(git rev-parse HEAD)" = "$PUBLISHED_COMMIT"|
    assert assets =~ "run: mix deps.get --check-locked"
    assert assets =~ "run: bash scripts/build_release_sbom.sh"
    assert assets =~ "sha256sum -- release.cdx.json >> SHA256SUMS"
    assert assets =~ "release-assets/release.cdx.json"

    script = File.read!(Path.join(@root, "scripts/build_release_sbom.sh"))
    assert script =~ "mix sbom.cyclonedx --only prod"
    assert script =~ "--exclude-system-dependencies"
    assert script =~ "--classification library --schema 1.6 --format json"

    assert read_back =~ "attestations: write"
    assert assets =~ ~s|predicate: '{"release_commit":"${{ steps.served.outputs.commit }}"}'|
    assert assets =~ "sbom-path: release-assets/release.cdx.json"

    assert assets =~ ~S"""
              digest=$(sha256sum < "$archive")
              bundle="$RUNNER_TEMP/sha256:${digest%% *}.jsonl"
              trap 'rm -f -- "$bundle"' EXIT
              (cd "$RUNNER_TEMP" && gh attestation download "$archive" --repo "$GITHUB_REPOSITORY")
              gh attestation verify "$archive" --repo "$GITHUB_REPOSITORY" --bundle "$bundle" \
                --signer-workflow "$signer" --source-ref "$GITHUB_REF" --predicate-type "$predicate" --format json |
                jq -e --arg commit "$PUBLISHED_COMMIT" \
                  'any(.[]; .verificationResult.statement.predicate.release_commit == $commit)' >/dev/null
    """
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

  defp assert_publish_runtime(job) do
    assert job =~ "git show HEAD:.tool-versions | python3 -I -c"
    assert job =~ "elixir-version: ${{ steps.toolchain.outputs.elixir }}"
    assert job =~ "otp-version: ${{ steps.toolchain.outputs.otp }}"
    assert job =~ "version-type: strict"
    assert job =~ ~S|test "$elixir_version" = "$EXPECTED_ELIXIR"|
    assert job =~ ~S|test "$otp_version" = "$EXPECTED_OTP"|
    refute job =~ "scripts/toolchain.sh"
  end

  defp workflow_jobs(workflow) do
    [_, jobs] = String.split(workflow, "\njobs:\n", parts: 2)

    Regex.scan(~r/^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\z)/ms, jobs)
    |> Map.new(fn [_, name, body] -> {name, body} end)
  end
end

# Dependency-currency gate — the portable Elixir port of the former POSIX
# shell gate (a plain clone must work on Windows too). Run:
#
#     mix run --no-start scripts/check_deps_current.exs
#
# Exits nonzero whenever `mix hex.outdated` shows RESOLVABLE drift ("Update
# possible"), so staying current is mechanical, not remembered.
# Resolver-rejected packages ("Update not possible") are printed with the
# requirement chain that holds them back — the deliberate pins stay visible
# instead of silently reading as current. A failed hex.pm lookup also exits
# nonzero: an unverified currency state must never pass the gate.
# Dev/test-only and transitive deps are covered (--all).
#
# Runs in the CALLER'S working directory: it gates whichever mix project the
# caller is in (CI's gate job and the alias run it from the repo root; CI's
# example job runs it from examples/charter_lifecycle via the job's
# working-directory). No internal cd — a script-relative cd would re-check
# the repo root from the example job, whose root deps were never fetched.
#
# hex.outdated itself exits nonzero BOTH on drift and on lookup failure, so
# the classifier is the rendered result table, not the command's exit code;
# the table pads rows with trailing whitespace, so the status anchors are
# whitespace-tolerant ([[:space:]]*$ — a hard $ fails open).

{mix_cmd, prefix_args} =
  case :os.type() do
    {:win32, _} -> {"cmd", ["/c", "mix"]}
    _ -> {"mix", []}
  end

out =
  case System.cmd(mix_cmd, prefix_args ++ ["hex.outdated", "--all"],
         stderr_to_stdout: true,
         into: ""
       ) do
    {output, _drift_or_failure_status} -> output
  end

unless Regex.match?(~r/^Dependency/m, out) do
  IO.puts("FAIL: mix hex.outdated rendered no result table — currency unverified.")
  IO.puts(out)
  System.halt(1)
end

rows = String.split(out, "\n")

drift = Enum.filter(rows, &Regex.match?(~r/Update possible[[:space:]]*$/, &1))

rejected = Enum.filter(rows, &Regex.match?(~r/Update not possible[[:space:]]*$/, &1))

unless rejected == [] do
  IO.puts(
    "Resolver-rejected updates (deliberate pins — the requirement chain below holds each back):"
  )

  for row <- rejected do
    IO.puts("  #{String.trim_trailing(row)}")

    package = row |> String.trim_trailing() |> String.split(" ") |> List.first()

    {detail, _status} =
      System.cmd(mix_cmd, prefix_args ++ ["hex.outdated", package],
        stderr_to_stdout: true,
        into: ""
      )

    detail
    |> String.split("\n")
    |> Enum.each(&IO.puts("    #{&1}"))
  end
end

if drift != [] do
  IO.puts("")

  IO.puts(
    "FAIL: #{length(drift)} resolvable update(s) available — run 'mix deps.update <pkg>' " <>
      "now, or record the deliberate pin with an inline reason in mix.exs."
  )

  Enum.each(drift, &IO.puts(String.trim_trailing(&1)))
  System.halt(1)
end

IO.puts("Dependency currency: no resolvable drift.")

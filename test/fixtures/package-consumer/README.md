# Generated project locks

`mix.lock` commits the production dependency graph for both the unpacked package
and its generated smoke consumer in `scripts/check_package.exs`. Update it with
the root production locks; `deps.get --check-locked` refuses new resolution in
either generated project.

`../reproducible/mix.lock` commits the full root graph used by the independent
reproducibility copies. Keep it aligned with the root lock.

`../protocol-candidate/` commits the signer, example and consumer graphs with the
protocol Hex entry removed because those projects use the unpacked protocol path.
Keep them aligned with the root and example locks when their dependencies move.

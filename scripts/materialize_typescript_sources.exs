# Fetch and materialize both public pins. --cached uses the last fetched
# public main refs; --check only checks the materialized stamps.
Code.require_file("typescript_sources.exs", __DIR__)
CharterAgreementSigner.TypeScriptSources.run(System.argv())

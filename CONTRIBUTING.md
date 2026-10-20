# Contributing

Reports from other upgrades are the most useful contribution: what you ran, from which version to which, and what broke.

- **A new gotcha:** one paragraph in `docs/gotchas.md`. Say what happened, why, and what to do, and link the upstream issue if there is one. Mark it fixed or open.
- **A version you tested:** a new row or table in `versions.md` with the date, the image digest, and what "tested" means (production, clone, local).
- **A script change:** keep scripts read-only unless they say otherwise in their header. Run `bash -n` and `shellcheck` on shell scripts. Never print secret values; print names, lengths, counts or hashes.
- **Before you open a pull request:** remove hostnames, IP addresses, Coolify service ids, keys, tokens and email addresses from logs and examples. Use placeholders such as `<service-uuid>` and `<host>`.

Plain English, short sentences. Say what you verified and what you did not.

# Tips for the next upgrade

> **Basis.** Our own practice after the 2026-10-19 window; each tip links back to the gotcha or chapter it comes from where there is one.

Short, in no particular order.

- **Diff against upstream, file by file.** Compose, `vector.yml`, the Envoy files, init SQL. A copy you took a year ago carries a year of upstream fixes you do not have (gotcha 17).
- **Read upstream's `docker/versions.md`** in supabase/supabase. It lists every image bump of the self-hosted compose with dates, which gives you safe intermediate versions for services that migrate on boot.
- **Pin by digest** and record the digests the week before. Tags move.
- **Pre-pull, then `docker save` the rollback images.** A nightly cleanup can remove both (gotcha 7).
- **One service block per change.** Never change two blocks between two recreates.
- **Check secret lengths, not only presence** (`scripts/check-secret-lengths.sh`).
- **Probe the internal path.** Public checks can stay green while the internal hop is broken (gotcha 1).
- **Stop autoheal for the window** and start it last.
- **Rehearse on a clone, then compare the clone to production** (sizes, cron jobs, connections). Clone timings are a lower bound.
- **Record every compose change in Coolify** as you go, not at the end (gotcha 3).
- **Write the rollback command next to every step** in the runbook, and test the rollbacks on the clone, not just the forward path. Our worst bug was in a rollback (gotcha 30).
- **Take your own dumps** with globals, per database, off the host (gotcha 10).
- **Look at `_supabase` before you plan disk and time.** Logflare can make it bigger than your app database.
- **Give migrating services a long `start_period`.**
- **Keep the old major's data for a while** and keep "delete unused volumes" off until it is gone.
- **Read a failed job's event history before counting it as window damage**, and make sure your queue consumers acknowledge only when the work is done, so a job paused by the window is delivered again (gotcha 31).
- **Move WAL archiving and backup images to the new major the same week** (gotcha 32).
- **Keep a deadline for go / no-go,** and decide in advance what a late no-go costs.

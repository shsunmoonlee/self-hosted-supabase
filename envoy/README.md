# Envoy configuration: what we changed, and where it comes from

This folder deliberately holds no config files yet (owner decision, see the drafts index). Our Envoy files are upstream's with a few deltas, and some of those deltas are specific to our app. Start from upstream's files instead:

- **Source:** `supabase/supabase`, tag `self-hosted/v0.8.3`, `docker/volumes/api/envoy/` (`envoy.yaml`, `cds.yaml`, `lds.template.yaml`, `docker-entrypoint.sh`). Apache-2.0.
- **Coolify's version** of the same files is inline in the template in [coollabsio/coolify#12004](https://github.com/coollabsio/coolify/pull/12004) (still open when we wrote this). We did not copy from the PR; we read it to cross-check our port. Nothing here derives from the PR text.

## The generic deltas, which you may want too

| File | Change | Why |
|---|---|---|
| `cds.yaml` | Cluster addresses use our compose service names; clusters for removed services dropped | Storage, Functions, Studio and Logflare were removed from our stack |
| `lds.template.yaml` | Studio catch-all replaced by a fixed 404 with Kong's 404 body | If Studio is not on your public host, the catch-all can become a fixed 404; Kong's body keeps clients that matched it working |
| `lds.template.yaml` | Proxy timeouts 60 s where upstream has 30 s | Kong's timeouts, which our clients were used to; WebSocket upgrades are not cut by the route timeout |
| `lds.template.yaml` | Basic-auth filter removed | No Studio route |
| `docker-entrypoint.sh` | Exits 1 if `ANON_KEY` or `SERVICE_ROLE_KEY` is empty; basic-auth lines removed | Defense in depth: never render key-match rules from an empty key |

App-specific deltas (extra open auth routes and a few routes answered with a fixed 403) are not listed.

## How we validated it

See `docs/04-kong-to-envoy.md`, "Validate before you swap".

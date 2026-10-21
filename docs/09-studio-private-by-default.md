# 9. Studio: private by default

> **Basis.** Verified by us: we keep Studio off our public host, and that is all this chapter says about our own setup. Everything else comes from upstream's [Docker guide](https://supabase.com/docs/guides/self-hosting/docker#studio-authentication) and [Envoy guide](https://supabase.com/docs/guides/self-hosting/self-hosted-envoy#dashboard-basic-auth), the upstream config in [`docker/volumes/api/envoy`](https://github.com/supabase/supabase/tree/master/docker/volumes/api/envoy) and [`kong.yml`](https://github.com/supabase/supabase/blob/master/docker/volumes/api/kong.yml) (read 2026-10-21), the Caddy, Traefik, Authelia, Authentik and Coolify docs, and two community references. The config snippets below are **untested by us**; treat them as starting points.

## Why Studio must never face the internet

Studio is a full admin console. It talks to postgres-meta with the service key (`SUPABASE_SERVICE_KEY` is in its environment in the stock compose), so whoever reaches Studio can read and change every table, role and policy, row level security bypassed. The stock protection is one shared basic-auth password at the gateway: upstream's Docker guide says Studio "is protected with HTTP basic authentication" and that a secure password must be set before the first start ([Studio authentication](https://supabase.com/docs/guides/self-hosting/docker#studio-authentication)). One password, no second factor, no lockout, on the same host as your public API. People keep finding their Studio open ([supabase#4934](https://github.com/supabase/supabase/issues/4934)), and community installers such as singh-inder's exist mainly to put something stronger in front of it.

## What the stock protection does, and what it does not

Both gateways attach the `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` pair to the catch-all route only:

- **Envoy.** The entrypoint hashes `DASHBOARD_PASSWORD` (SHA1, base64) into a `basic_auth` filter that applies to every route; each API route then sets `basic_auth: disabled: true` per route, so only the `/` catch-all to the `studio` cluster asks for the password ([Envoy guide, dashboard basic auth](https://supabase.com/docs/guides/self-hosting/self-hosted-envoy#dashboard-basic-auth)). The catch-all also strips the inbound `authorization` header before forwarding to Studio.
- **Kong.** `kong.yml` defines a `DASHBOARD` consumer with `basicauth_credentials` and a `dashboard` service (`url: http://studio:3000/`) at the end of the file.

What it protects: the Studio pages. What it does not touch: every API route. `/rest/v1/`, `/auth/v1/`, `/realtime/v1/` and `/storage/v1/` still answer to the anon key exactly as before, and `/pg/` (postgres-meta) is guarded separately by the gateway's RBAC policy, which admits only the service key. The dashboard password is a door in front of Studio only; it is not what keeps your database private.

## Three patterns

### (a) No public route at all

Remove Studio from the gateway and reach it over a private network or an SSH tunnel.

Envoy: replace the catch-all in `lds.template.yaml` with a fixed 404. The `/api/mcp` and `/mcp` routes also point at `cluster: studio`: remove those two routes too, or keep the cluster. Then delete the `basic_auth` filter if no route still uses it. The [`envoy/` README](../envoy/README.md) in this repo lists this delta.

```yaml
- match: { prefix: / }
  direct_response:
    status: 404
    body: { inline_string: '{"message":"no Route matched with those values"}' }
```

Kong: delete the `dashboard` service at the end of `kong.yml`, the `DASHBOARD` consumer and its `basicauth_credentials` entry (a consumer that credentials still reference fails the declarative load).

Then publish Studio to the host's loopback only, and tunnel to it:

```yaml
studio:
  ports:
    - "127.0.0.1:3000:3000"
```

```bash
ssh -L 3000:127.0.0.1:3000 <host>     # then open http://localhost:3000
```

Over WireGuard or Tailscale, bind to the private interface address instead of `127.0.0.1`. Studio reaches postgres-meta and the gateway over the compose network, so a tunnel to port 3000 is enough; pages that open `SUPABASE_PUBLIC_URL` in the browser keep working because that URL stays public (untested by us).

Verify: `curl -s -o /dev/null -w '%{http_code}\n' https://<api-host>/` returns 404; `nc -z -v -w 3 <public-ip> 3000` reports "refused" or "timed out" (`; echo $?` is non-zero).

### The gateway step shared by (b) and (c)

Both gateways match the Studio catch-all by path only (Envoy `match: { prefix: / }`, Kong `paths: [/]`), so a rule in the reverse proxy on a Studio hostname leaves Studio reachable on the API host too. Pin the catch-all to the Studio host first (untested by us):

Envoy, in `lds.template.yaml`: add a host match to the catch-all, then the fixed-404 route from pattern (a) after it.

```yaml
- match:
    prefix: /
    headers:
      - name: ':authority'
        string_match: { exact: studio.example.com }
  route: { cluster: studio, timeout: 30s }
  # ... the rest of the upstream catch-all unchanged
- match: { prefix: / }
  direct_response:
    status: 404
    body: { inline_string: '{"message":"no Route matched with those values"}' }
```

Kong, in `kong.yml`: add `hosts: [studio.example.com]` to the `dashboard-all` route.

### (b) An allowlist in front of the gateway

Keep the stock basic auth and add a network rule in your reverse proxy, on a Studio hostname of its own so the API host is untouched. The ranges `203.0.113.0/24` and `198.51.100.0/24` below are documentation placeholders for your office or VPN range. For Tailscale, use `100.64.0.0/10`.

Caddy ([request matchers](https://caddyserver.com/docs/caddyfile/matchers)):

```
studio.example.com {
    @blocked not remote_ip 203.0.113.0/24 198.51.100.0/24
    respond @blocked 403
    reverse_proxy api-gw:8000
}
```

Traefik v3 ([ipAllowList](https://doc.traefik.io/traefik/middlewares/http/ipallowlist/)), as a file-provider middleware attached to the Studio router:

```yaml
http:
  middlewares:
    studio-allowlist:
      ipAllowList:
        sourceRange:
          - 203.0.113.0/24
          - 198.51.100.0/24
```

Behind another proxy or a CDN the client address is the proxy's: Caddy needs `client_ip` with `trusted_proxies`, Traefik needs `ipStrategy`.
Verify: from an allowed address, `curl -s -o /dev/null -w '%{http_code}\n' https://studio.example.com/` returns 401 (basic auth); from any other address, 403; `https://<api-host>/` returns 404 from anywhere.

### (c) Single sign-on in front of Studio

Put a forward-auth provider in front of the Studio hostname only; on the API host it would block your apps' API calls.

Caddy with Authelia ([Authelia Caddy guide](https://www.authelia.com/integration/proxies/caddy/)):

```
studio.example.com {
    forward_auth authelia:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
    }
    reverse_proxy api-gw:8000
}
```

Traefik with Authelia ([Authelia Traefik guide](https://www.authelia.com/integration/proxies/traefik/)):

```yaml
http:
  middlewares:
    studio-sso:
      forwardAuth:
        address: http://authelia:9091/api/authz/forward-auth
        trustForwardHeader: true
        authResponseHeaders: [Remote-User, Remote-Groups, Remote-Email, Remote-Name]
```

Authentik works the same way through its proxy outpost ([Caddy](https://docs.goauthentik.io/add-secure-apps/providers/proxy/server_caddy), [Traefik](https://docs.goauthentik.io/add-secure-apps/providers/proxy/server_traefik)). With SSO in place you can keep basic auth as a second door or remove the filter from the Studio route.

References, not copies: [Vadko's Studio gist](https://gist.github.com/Vadko/bb21b01757a3ca2c82f04343babcf333) puts Studio on its own host under Cloudflare Access or oauth2-proxy with the check done in Envoy itself, on Coolify; the [singh-inder installer](https://github.com/singh-inder/supabase-automated-self-host) sets up Caddy (or nginx) with Authelia for a fresh install.

Verify: an unauthenticated `curl -s -o /dev/null -w '%{http_code}\n' https://studio.example.com/` returns 302 to the sign-in page or 401, never 200; `https://<api-host>/` returns 404; the API checks below still pass.

## Coolify specifics

- In Coolify's Supabase template only the gateway service (`supabase-kong`) carries a domain (`SERVICE_URL_SUPABASEKONG`); Studio has none of its own and is reached through the gateway's catch-all, so the gateway's **Domains** field is where Studio becomes public. A second domain in that field, API domain first, is how Vadko's gist gives Studio its own host.
- Pattern (a) on Coolify: edit the gateway config file storage on the host, then press "Load from server" ([Coolify chapter, item 5](08-coolify.md)), or the next Save writes the old route back.
- Patterns (b) and (c): Coolify's proxy is Traefik, and file-based dynamic configuration lives under `/data/coolify/proxy/dynamic/` on the server, mounted at `/traefik/dynamic/` in the proxy container ([Coolify docs](https://coolify.io/docs/core/networking/proxy/traefik/dynamic-config)). Coolify writes its own files there, and a proxy restart through Coolify writes its saved configuration back to disk and can overwrite disk-only edits, so add your middleware as its own file (`studio.yaml`) through Servers > your server > Proxy > Dynamic Configurations, where it is saved, and attach it to the service with a label such as `traefik.http.routers.<router>.middlewares=studio-allowlist@file` ([protect a resource](https://coolify.io/docs/core/networking/proxy/traefik/basic-auth)). Untested by us.

## Verify, from outside

```bash
ANON=<anon key>
curl -s -o /dev/null -w 'studio %{http_code}\n' https://<api-host>/                       # 404 for (a), (b) and (c); never 200 or 401
curl -s -o /dev/null -w 'rest %{http_code}\n' https://<api-host>/rest/v1/<table>?limit=1 -H "apikey: $ANON" -H "Authorization: Bearer $ANON"   # 200
curl -s -o /dev/null -w 'pg anon %{http_code}\n' https://<api-host>/pg/tables -H "apikey: $ANON"   # 401 or 403, never 200
curl -s -o /dev/null -w 'pg none %{http_code}\n' https://<api-host>/pg/tables                      # 401
```

If the first line returns 200, Studio is public; 401 means it is still there behind one shared password. If the third returns 200, postgres-meta is open to the anon key: stop and fix the gateway before anything else.

# Domain migration: gabro.ovh → gbroccoli.dev

Done on 2026-11-15 as two MRs: !175 (`chore/domain-prep`) and !176 (`feat/domain-gbroccoli-dev`).
In git the switch is two values in `cluster-settings`: `PUBLIC_DOMAIN` and `LOCAL_DOMAIN`.
Everything below is state outside git that the merge does not touch. It was captured from the
live cluster on 2026-11-11, and the notes from the actual cutover are folded in.

Merging switches every ingress at once. The old hostnames stop matching in Traefik, so do
phase 1 before you merge and phase 3 right after.

## Deliberately unchanged

- **Matrix identity**: `MATRIX_SERVER_NAME: matrix.gabro.ovh`. `server_name` is baked into every
  user ID, room ID and signature, and changing it means wiping Matrix. Only
  `public_baseurl` / MAS `public_base` move. Mobile clients must log in again using
  `https://matrix.gbroccoli.dev` as the homeserver URL, because discovery via the old
  `server_name` stops working once gabro.ovh is gone.
- **`registry.local.gabro.ovh/mirror/minio`** (minio, gitlab-runner): the registry and its
  `registry-pull` dockerconfigjson (keyed by hostname) belong to the work/infra repo.
  Move it there first, then update the four image refs and the pull secret.

## Phase 0: DNS delegation

1. OVH: DNSSEC off, nameservers `anirban.ns.cloudflare.com` / `virginia.ns.cloudflare.com`.
2. Check the registry until it lists the Cloudflare nameservers:
   `dig +norec NS gbroccoli.dev @ns-tld1.charlestonroadregistry.com`
3. Cloudflare zone shows **Active**.
4. Placeholder mail records, until mailbox.org is set up: `TXT @ "v=spf1 -all"`,
   `TXT _dmarc "v=DMARC1; p=reject;"`.

## Phase 1: before the merge

1. **Cloudflare API token** used by cert-manager (`cert-manager/cloudflare-api-token/api-token`):
   Zone:DNS:Edit and Zone:Zone:Read on **both** zones. `registry-tls` (`registry.local.gabro.ovh`)
   still renews through the same issuer until the registry moves. Then run `task rotate-cloudflare-api`.
   The ClusterIssuers must have no `dnsZones` selector (removed in !175): one pinned to
   `${PUBLIC_DOMAIN}` stops matching the old zone after the switch.
2. **Tunnel public hostnames**: in each tunnel, add the gbroccoli.dev name next to the gabro.ovh one,
   with the same service URL. Names: `account adguard authentik centralino chat flux-webhook
   gitlab grafana home immich jellyfin matrix navidrome nextcloud tv`.
   `flux-webhook` rides the authentik tunnel.
   The CV site moves from `website.gabro.ovh` to `resume.gbroccoli.dev` (websites tunnel). Its host is
   `HOST` in `work/infra/gitops` `clusters/homelab/tenants.yaml`, which deploys independently of this merge.
3. **New cluster-settings keys go in a separate MR first.** `kubectl apply` of the ConfigMap does not
   work: the `flux-system` Kustomization reverts it to `main` within minutes. Merge a MR that only
   adds `MATRIX_SERVER_NAME`, check it is live
   (`kubectl -n flux-system get cm cluster-settings -o jsonpath='{.data.MATRIX_SERVER_NAME}'`),
   then merge the switch.
4. **Authentik OIDC redirect URIs**: add the gbroccoli.dev URIs next to the old ones now
   (Immich 6, Nextcloud 2, Grafana 1, GitLab 1). Edit the existing providers; don't duplicate them,
   because a new application gets a new slug, client ID and secret.
5. **DNS-01 check** (after step 3's MR): a throwaway `letsencrypt-staging` Certificate for
   `dns01-test.local.gbroccoli.dev` should go Ready within about 2 minutes. Delete it afterwards.

## Phase 2: merge

Push, merge, then **force-reconcile every Kustomization**. The per-app Kustomizations apply the new
commit before `flux-system` has updated `cluster-settings`, so they substitute the old values and still
report `Applied revision: <new sha>`. Nothing re-triggers them, because the revision doesn't change.

```bash
for k in $(kubectl -n flux-system get ks -o jsonpath='{range .items[?(@.spec.sourceRef.name=="flux-system")]}{.metadata.name}{"\n"}{end}'); do
  flux reconcile ks "$k"
done
flux reconcile ks centralino --with-source
kubectl get ingress -A -o jsonpath='{range .items[*]}{.spec.rules[*].host}{"\n"}{end}' | grep gabro.ovh
```

The last command should list only the gitops-repo hosts (`registry`, `nirvastudio`).
`centralino` has its own GitRepository, so the loop skips it.

Watch the certificates (`wildcard-local-tls`, `authentik-public-tls`, `gitlab-*`):

```bash
kubectl get certificate -A
```

Don't continue until they are all `Ready=True`.

## Phase 3: after the merge

### AdGuard rewrites (API is unauthenticated on the LAN)

Current: `*.local.gabro.ovh`, `authentik.gabro.ovh`, `gitlab.gabro.ovh` → `192.168.1.55`.

```bash
AG=http://192.168.1.60
for d in '*.local.gbroccoli.dev' authentik.gbroccoli.dev gitlab.gbroccoli.dev; do
  curl -s -X POST $AG/control/rewrite/add -H 'Content-Type: application/json' \
    -d "{\"domain\":\"$d\",\"answer\":\"192.168.1.55\"}"
done
curl -s $AG/control/rewrite/list
```

Delete the three old entries once nothing uses gabro.ovh any more
(`POST /control/rewrite/delete` with the same body).

### Authentik

Log in and edit on the **same host**. The session cookie is domain-wide (`AUTHENTIK_COOKIE_DOMAIN`), but
the CSRF cookie is host-only. If you log in on `authentik.<domain>` and edit on `authentik.local.<domain>`,
or the other way round, pages load but every save fails with "CSRF cookie not set".
After the merge everyone has to log in again once, because old sessions belong to the old cookie domain.

- Proxy (`forward_single`) external hosts: **Dispatcharr** (`tv.`), **Jellyfin**, **Adguard**,
  **Centralino**, **Navidrome**, **Homepage** (`home.`), **Longhorn** (`longhorn.local.`).
  They have a single external host, so change them right after the merge, not before.
- **Embedded Outpost** (Applications → Outposts → Advanced settings): `authentik_host` →
  `https://authentik.gbroccoli.dev`. Without it, forward-auth logins redirect to the old domain.

### Nextcloud (config.php ignores env changes after install)

Current: trusted_domains `localhost`, `nextcloud.gabro.ovh`, `nextcloud.local.gabro.ovh`;
overwrite.cli.url `https://nextcloud.gabro.ovh`; OIDC provider `Authentik`.
Nextcloud is down (503) until this runs: the readiness probe sends `Host: nextcloud.${PUBLIC_DOMAIN}`,
which isn't a trusted domain yet, so `status.php` returns 400.

```bash
occ() { kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- su -s /bin/sh www-data -c "php occ $*"; }
occ config:system:set trusted_domains 1 --value=nextcloud.gbroccoli.dev
occ config:system:set trusted_domains 2 --value=nextcloud.local.gbroccoli.dev
occ config:system:set overwrite.cli.url --value=https://nextcloud.gbroccoli.dev
occ user_oidc:provider Authentik \
  --discoveryuri=https://authentik.gbroccoli.dev/application/o/nextcloud/.well-known/openid-configuration
```

### Immich (Administration → Settings)

- OAuth → Issuer URL: `https://authentik.gbroccoli.dev/application/o/immich/`
- Server → External domain: `https://immich.gbroccoli.dev`

If OAuth is the only login, the UI can't be reached. Set both values in the database and restart the server:

```bash
kubectl -n immich exec immich-postgresql-0 -- psql -U immich -d immich -c "
update system_metadata set value = jsonb_set(jsonb_set(value,
  '{oauth,issuerUrl}', '\"https://authentik.gbroccoli.dev/application/o/immich/\"'),
  '{server,externalDomain}', '\"https://immich.gbroccoli.dev\"')
where key = 'system-config';"
kubectl -n immich rollout restart deploy/immich-server
```

Mobile apps: change the server URL to `https://immich.gbroccoli.dev`.

### GitLab

- Project → Settings → Webhooks: change the push hook URL to `https://flux-webhook.gbroccoli.dev/hook/...`
  (same path, see `task webhook-url`). **Changing the URL clears the secret token**, so paste it again
  (`kubectl -n flux-system get secret github-webhook-token -o jsonpath='{.data.token}' | base64 -d`).
  Otherwise the Receiver returns 400 ("X-Gitlab-Token header value does not match"). Keep the
  secret token and ignore GitLab's suggestion to switch to a signing token. The Flux `gitlab`
  Receiver checks `X-Gitlab-Token`.
- Local clones: `git remote set-url origin https://gitlab.gbroccoli.dev/<path>.git` in each one, and copy the
  `~/.git-credentials` entry to the new hostname (credentials are stored per host).

### Apps with the server URL stored on the client

Jellyfin, Navidrome (Subsonic clients), Nextcloud desktop/mobile, Immich mobile, Element mobile:
re-add the server under the new name.

## Phase 4: retire gabro.ovh

Prerequisite: move the remaining gabro.ovh names that live in `work/infra/gitops`:
- `REGISTRY_HOST: registry.local.gabro.ovh` (`clusters/homelab/settings.yaml`). The `registry-pull`
  dockerconfigjson in Bitwarden (`registry/registry-pull/dockerconfigjson`) is keyed by hostname, and the
  site CI pipelines push to that host. Change all of them together, then the four image refs in this repo
  (minio, gitlab-runner).
- `nirvastudio.gabro.ovh` (client site): needs a new tunnel hostname, and the client should know first.
- `EMAIL_FROM_ADDRESS=noreply@gabro.ovh` in the nirva-presentation tenant (mail domain).

1. Keep the gabro.ovh tunnel hostnames for a while, or replace them with a Cloudflare redirect
   rule on the gabro.ovh zone: `*.gabro.ovh/*` → `https://${1}.gbroccoli.dev/${2}` (301, keep the
   query string). That needs a proxied wildcard record, e.g. `* AAAA 100::`.
2. Remove the old tunnel hostnames, AdGuard rewrites and Authentik local redirect URIs.
3. Re-enable DNSSEC from Cloudflare and publish its DS record at OVH.

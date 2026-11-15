# Domain migration: gabro.ovh → gbroccoli.dev

Branch `feat/domain-gbroccoli-dev`. In git the switch is two values in `cluster-settings`:
`PUBLIC_DOMAIN` and `LOCAL_DOMAIN`. Everything below is state outside git that the merge
does not touch. It was captured from the live cluster on 2026-11-11.

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
   add gbroccoli.dev to Zone:DNS:Edit.
2. **Tunnel public hostnames**: in each tunnel, add the gbroccoli.dev name next to the gabro.ovh one,
   with the same service URL. Names: `account adguard authentik centralino chat flux-webhook
   gitlab grafana home immich jellyfin matrix navidrome nextcloud tv`.
   `flux-webhook` rides the authentik tunnel.
   The CV site moves from `website.gabro.ovh` to `resume.gbroccoli.dev` (websites tunnel). Its host is
   `HOST` in `work/infra/gitops` `clusters/homelab/tenants.yaml`, which deploys independently of this merge.
3. **cluster-settings**: apply it first, so `${MATRIX_SERVER_NAME}` is never substituted empty:
   `kubectl apply -f clusters/homelab/cluster-settings.yaml`.
   From then on the cluster is on the new values. Merge right away.

## Phase 2: merge

Push, merge, then `flux reconcile source git flux-system && flux reconcile kustomization apps`.
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

### Authentik (UI → Applications → Providers)

Replace `gabro.ovh` with `gbroccoli.dev` in:

- OIDC redirect URIs: **Immich** (6, public and local), **Nextcloud** (2), **Grafana** (1), **GitLab** (1).
- Proxy (`forward_single`) external hosts: **Dispatcharr** (`tv.`), **Jellyfin**, **Adguard**,
  **Centralino**, **Navidrome**, **Homepage** (`home.`), **Longhorn** (`longhorn.local.`).

### Nextcloud (config.php ignores env changes after install)

Current: trusted_domains `localhost`, `nextcloud.gabro.ovh`, `nextcloud.local.gabro.ovh`;
overwrite.cli.url `https://nextcloud.gabro.ovh`; OIDC provider `Authentik`.

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

Mobile apps: change the server URL to `https://immich.gbroccoli.dev`.

### GitLab

- Project → Settings → Webhooks: change the push hook URL to `https://flux-webhook.gbroccoli.dev/hook/...`
  (same path, see `task webhook-url`).
- Local clones: `git remote set-url origin https://gitlab.gbroccoli.dev/server/k-homelab.git`.

### Apps with the server URL stored on the client

Jellyfin, Navidrome (Subsonic clients), Nextcloud desktop/mobile, Immich mobile, Element mobile:
re-add the server under the new name.

## Phase 4: retire gabro.ovh

1. Keep the gabro.ovh tunnel hostnames for a while, or replace them with a Cloudflare redirect
   rule on the gabro.ovh zone: `*.gabro.ovh/*` → `https://${1}.gbroccoli.dev/${2}` (301, keep the
   query string). That needs a proxied wildcard record, e.g. `* AAAA 100::`.
2. Remove the old tunnel hostnames, AdGuard rewrites and Authentik local redirect URIs.
3. Re-enable DNSSEC from Cloudflare and publish its DS record at OVH.

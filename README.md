<div align="center">

# 🏠 Gabro's Homelab

_My home Kubernetes cluster — fully self-hosted, GitOps-managed, and reconciled straight from this repo._

[![k3s](https://img.shields.io/badge/k3s-FFC61C?style=for-the-badge&logo=k3s&logoColor=black)](https://k3s.io)
[![Flux](https://img.shields.io/badge/Flux-5468FF?style=for-the-badge&logo=flux&logoColor=white)](https://fluxcd.io)
[![Renovate](https://img.shields.io/badge/Renovate-1A1F6C?style=for-the-badge&logo=renovate&logoColor=white)](https://www.mend.io/renovate)

[![CI](https://img.shields.io/gitlab/pipeline-status/server%2Fk-homelab?gitlab_url=https%3A%2F%2Fgitlab.gabro.ovh&branch=main&style=for-the-badge&logo=gitlab&logoColor=white&label=kubeconform%20%2B%20flate)](https://gitlab.gabro.ovh/server/k-homelab/-/pipelines?ref=main)
[![Last Commit](https://img.shields.io/gitlab/last-commit/server%2Fk-homelab?gitlab_url=https%3A%2F%2Fgitlab.gabro.ovh&branch=main&style=for-the-badge&logo=gitlab&logoColor=white)](https://gitlab.gabro.ovh/server/k-homelab/-/commits/main)

</div>

---

## Overview

This is the single source of truth for my home Kubernetes cluster. Every workload, controller and config lives here and is applied through GitOps — there is no manual `kubectl apply`, the `main` branch _is_ the desired state of the cluster. Most of the hardware was recycled from old upgrades or gifted by friends, plus some cheap micro-ATX bits.

It started as a way to learn Kubernetes and grew into the thing that handles my photos, media and files. Along the way I tried to hold it to the standards I'd want at work: declarative config, no secrets in Git, automated dependency and node upgrades, append-only backups and a good amount of observability.

The cluster is self-hosted. The only door to the outside world is a set of Cloudflare Tunnels — there are no ports forwarded on my router.

## Hardware

Single node, runs every workload and carries all persistent disks

| Node      | Arch   | Role                                | Notes                |
| --------- | ------ | ----------------------------------- | -------------------- |
| `homelab` | x86_64 | control-plane + storage + workloads | Ryzen 2600x 32GB ram |

All storage is attached to `homelab`:

- **[Longhorn](https://longhorn.io)** manages two NVMe drives (1 TB + 500 GB)
- A separate **2 TB HDD** holds the append-only restic repository for backups, kept off the Longhorn pool
- Media and music sit on their own host-path disks, mounted straight into the pods

Power & thermals:

- The box runs behind a **UPS**, exposed on the LAN through [NUT](https://networkupstools.org); `nut-exporter` scrapes battery charge, runtime, load and line voltage into Prometheus so i get alerts on a power event or a tired battery.
- Fan curves are driven by **Pankha**, reading the motherboard's sensors with an emergency ramp if a reading goes out of control.

## Cluster

[k3s](https://k3s.io) on a single x86 node that is control-plane, storage and worker in one. Lightweight, no-state pods (like the tunnels) still carry node affinity for `${STATELESS_NODE}` and a toleration for a `workload=stateless` taint, so pointing that setting at a new, tainted node moves them off the main box without touching any manifest (leftover from previous 2 node setup).

### Core components

- **GitOps & automation** — [Flux](https://fluxcd.io) reconciles the cluster from this repo, [Renovate](https://www.mend.io/renovate) raises PRs for chart and image updates, and [system-upgrade-controller](https://github.com/rancher/system-upgrade-controller) upgrades k3s itself inside a weeknight maintenance window. A `Taskfile` covers the day-to-day commands, and a bootstrap script rebuilds the whole cluster on a fresh machine.
- **Networking & ingress** — [Traefik](https://traefik.io) handles ingress, [MetalLB](https://metallb.io) gives it a stable LAN IP, [AdGuard Home](https://adguard.com/adguard-home/overview.html) does local DNS and filtering, and [cloudflared](https://github.com/cloudflare/cloudflared) publishes the public services over Cloudflare Tunnels.
- **Security & secrets** — [cert-manager](https://cert-manager.io) issues a wildcard certificate via Let's Encrypt DNS-01, [External Secrets](https://external-secrets.io) pulls every credential from [Bitwarden Secrets Manager](https://bitwarden.com/products/secrets-manager/) at runtime, and [Authentik](https://goauthentik.io) provides SSO and forward-auth. Namespaces enforce Pod Security Standards and each app carries a default-deny NetworkPolicy.
- **Storage & data** — [Longhorn](https://longhorn.io) for block PVCs (installed by the bootstrap script, deliberately outside Flux), [MinIO](https://min.io) as an in-cluster S3 store behind Nextcloud, and [VolSync](https://github.com/backube/volsync) + [restic](https://restic.net) for backups against an append-only server.
- **Observability** — [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts) for metrics and Alertmanager (routed to Telegram), [Loki](https://grafana.com/oss/loki/) + [Alloy](https://grafana.com/docs/alloy/latest/) for logs, and [Grafana](https://grafana.com) for dashboards.

### GitOps

[Flux](https://fluxcd.io) watches this repo and applies changes the moment they land on `main`. The entrypoint is `clusters/homelab`, which wires up the root Kustomizations in dependency order. Cluster-wide values — domains, timezone, IP ranges, host paths — live once in a `cluster-settings` ConfigMap and get substituted everywhere through `postBuild.substituteFrom`. A GitHub webhook hits the in-cluster `flux-webhook` receiver so reconciliation is near-instant instead of waiting on the poll interval.

```mermaid
graph TD
    A[GitRepository: flux-system] -->|reconciles| B[Kustomization: infrastructure-configs]
    B -->|namespaces · netpols| C[Kustomization: infrastructure-controllers]
    C -->|cert-manager · ESO · MetalLB · VolSync · VPA · Kyverno| D[Kustomization: apps]
    D -->|per-app ks.yaml| E[HelmReleases / Deployments]
```

### Layout

```
clusters/homelab     # Flux entrypoint — bootstrap + root Kustomizations + cluster-settings
infrastructure
├── configs          # namespaces, network policies
└── controllers      # cert-manager, external-secrets, metallb, volsync, vpa, kyverno, system-upgrade, ...
apps                 # one folder per workload (ks.yaml + manifests or HelmRelease)
bootstrap            # from-zero install script, site.env template, pinned Longhorn
docs                 # operator handbook (INSTRUCTIONS.md) and runbooks
scripts              # Bitwarden rotation and settings validation helpers
schema               # cluster diagrams (PlantUML source + rendered PNGs)
```

<details>
<summary>Cluster diagram</summary>

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="schema/cluster-schema-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="schema/cluster-schema-light.png">
  <img alt="Cluster architecture diagram" src="schema/cluster-schema-light.png">
</picture>

</details>

## Services

### Public — via Cloudflare Tunnel

Each public service runs its own `cloudflared` deployment (named tunnel, token from Bitwarden), two replicas behind a PodDisruptionBudget with a `/ready` check on the edge connection so a disconnected tunnel actually fails its probe. Several sit behind Authentik forward-auth.

| Service                                                   | Purpose                                          |
| --------------------------------------------------------- | ------------------------------------------------ |
| [Jellyfin](https://jellyfin.org)                          | Film & TV streaming                              |
| [Dispatcharr](https://github.com/Dispatcharr/Dispatcharr) | Live TV / IPTV streams                           |
| [Nextcloud](https://nextcloud.com)                        | General-purpose cloud storage (MinIO S3 backend) |
| [Immich](https://immich.app)                              | Self-hosted photo backup                         |
| [Navidrome](https://navidrome.org)                        | Music streaming                                  |
| [Matrix](https://matrix.org)                              | Chat — Synapse, Element Web and MAS for login    |
| [Authentik](https://goauthentik.io)                       | Centralized SSO / identity provider              |
| [Grafana](https://grafana.com)                            | Monitoring & dashboards                          |
| Centralino                                                | Home-automation panel for the ESP32 boards       |

### Local — via Traefik

Served on the LAN at `*.local.gabro.ovh`; AdGuard rewrites those hostnames to Traefik's MetalLB IP and Traefik presents the wildcard cert.

| Service                                                        | Purpose                                                                   |
| -------------------------------------------------------------- | ------------------------------------------------------------------------- |
| \*arr stack                                                    | Prowlarr, Radarr, Sonarr, Lidarr, qBittorrent, Seerr, tvheadend           |
| [AdGuard Home](https://adguard.com/adguard-home/overview.html) | Network filtering + local DNS (admin UI also public, behind forward-auth) |
| [Headlamp](https://headlamp.dev)                               | Kubernetes UI                                                             |
| Pankha                                                         | Fan / thermal control dashboard                                           |
| Homepage                                                       | Service dashboard (also public, behind forward-auth)                      |

The nodes themselves are reachable only over VPN + SSH.

## Network

Both ingress paths land on the same Traefik instance — what differs is the hostname. Public hosts (`*.gabro.ovh`) arrive **only** through a Cloudflare Tunnel, with no inbound ports open on the router, and Traefik gates them with Authentik forward-auth. Local hosts (`*.local.gabro.ovh`) resolve through AdGuard's DNS rewrites straight to Traefik's MetalLB IP, never touching the public internet or the auth hop.

```mermaid
flowchart LR
    subgraph cluster ["k3s cluster"]
        direction LR
        CFD["cloudflared"] --> TR["Traefik"]
        LB(["MetalLB IP"]) --> TR
        TR -- "public host" --> AK{"Authentik<br/>forward-auth"}
        AK -- "authenticated" --> APP["App pod"]
        TR -- "local host" --> APP
    end

    PU(["Public user"]) --> CFE["Cloudflare edge"]
    CFE -. "QUIC tunnel" .-> CFD
    LU(["Local device"]) -- "*.local.gabro.ovh" --> AG["AdGuard Home"]
    AG -. "DNS rewrite" .-> LB
```

## Storage & backups

[Longhorn](https://longhorn.io) is the default `StorageClass`; a second `longhorn-single` class (one replica) is used where in-cluster replication buys nothing on a single storage node. [MinIO](https://min.io) runs standalone as the S3 backend for Nextcloud, with bucket versioning on.

Backups are [VolSync](https://github.com/backube/volsync) `ReplicationSource`s using [restic](https://restic.net), plus scheduled `pg_dump` jobs for the databases. They target an in-cluster `restic-rest-server` running in **`--append-only`** mode, so a compromised client can add snapshots but never delete or overwrite existing ones. Retention is 7 daily / 4 weekly / 12 monthly with a weekly prune, and a `restic-exporter` feeds Prometheus — I get alerted on stale repos, failed integrity checks, and jobs that "succeed" without actually writing data.

## Secrets

Nothing secret is committed. The repo references only **keys**; [External Secrets](https://external-secrets.io) resolves them from [Bitwarden Secrets Manager](https://bitwarden.com/products/secrets-manager/) at runtime, and [Reloader](https://github.com/stakater/Reloader) rolls workloads when a value changes. Rotation is scripted end-to-end in the `Taskfile`:

```sh
task autorotate-postgres app=nextcloud   # generate → write BW → ALTER USER → roll consumers
task rotate-tunnel       svc=jellyfin    # rotate a Cloudflare tunnel token
task autorotate-minio-nc-user            # rotate the shared MinIO / Nextcloud S3 user
task rotate-cloudflare-api               # rotate the cert-manager Cloudflare API token
```

## Bootstrap

The cluster can be rebuilt from zero on a fresh Ubuntu machine with one script. It reproduces the stack, not the data — restoring from restic is a separate step.

```sh
cp bootstrap/site.env.example bootstrap/site.env   # domains, IPs, disks, tokens (gitignored)
task render-settings                               # write cluster-settings.yaml, then commit + push it
task bootstrap                                     # sudo bootstrap/bootstrap.sh on the new machine
```

In order, the script prepares the host (packages, multipathd, mounts, hostPath dirs), installs a pinned k3s, seeds `cluster-settings` and the Bitwarden token, installs a pinned [Longhorn](https://longhorn.io) with its disk tags, then runs `flux bootstrap` and waits until the whole tree is Ready. It is idempotent, so a failed run can simply be re-run, and it refuses to touch a host that already runs workloads. Longhorn stays out of Flux on purpose: its chart ships the CRDs without a keep policy, so a pruned HelmRelease would delete every volume record with it. The external accounts (GitHub, Bitwarden, Cloudflare) and the post-install steps are covered in [`docs/INSTRUCTIONS.md`](docs/INSTRUCTIONS.md).

## Operations

```sh
task status    # overview of every Flux Kustomization, HelmRelease and source
task bad       # show everything that is NOT Ready / Running
task reconcile # pull latest from Git and reconcile all root Kustomizations
task tree name=nextcloud   # list every resource a Kustomization manages
```

Every push to `main` and every merge request is validated in GitLab CI (`.gitlab-ci.yml`) by [kubeconform](https://github.com/yannh/kubeconform) (schema validation) and [flate](https://github.com/home-operations/flate) (offline build and diff of the Flux tree).

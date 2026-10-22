<div align="center">

# 🏠 K-Homelab

_My home Kubernetes cluster, fully self-hosted and run straight from this repo._

[![k3s](https://img.shields.io/badge/k3s-FFC61C?style=for-the-badge&logo=k3s&logoColor=black)](https://k3s.io)
[![Flux](https://img.shields.io/badge/Flux-5468FF?style=for-the-badge&logo=flux&logoColor=white)](https://fluxcd.io)
[![Renovate](https://img.shields.io/badge/Renovate-1A1F6C?style=for-the-badge&logo=renovate&logoColor=white)](https://www.mend.io/renovate)

[![CI](https://img.shields.io/github/actions/workflow/status/gabroz42/k-homelab/ci.yaml?branch=main&style=for-the-badge&logo=github&logoColor=white&label=kubeconform%20%2B%20flate)](https://github.com/gabroz42/k-homelab/actions/workflows/ci.yaml)
[![Last Commit](https://img.shields.io/github/last-commit/gabroz42/k-homelab/main?style=for-the-badge&logo=github&logoColor=white)](https://github.com/gabroz42/k-homelab/commits/main)

</div>

---

Welcome to my homelab repo,
here is a full presentation of my own Kubernetes cluster.

Everything running on the server is described in this repo. I edit a file, push it, and the cluster updates itself to match, so nothing is configured by hand.

## The hardware

Almost all hardware used was recycled from previous upgrades, found lying around or gifted by friends. The only things I had to buy were the micro-ATX parts (mobo, case and PSU, the cheapest I could find).

| Part              | What                       |
| ----------------- | -------------------------- |
| **CPU**           | AMD Ryzen 2600X            |
| **RAM**           | 32GB DDR4                  |
| **Main drive**    | 1TB Sabrent NVMe           |
| **Storage NVMe**  | 500GB Samsung NVMe (photos)|
| **Films drive**   | 4TB HDD                    |
| **Backup drive**  | 2TB HDD                    |
| **UPS**           | 600W                       |

The system and the cloud storage services that need to be fast run on the NVMe drives. The UPS is monitored too, so I get an alert on a power cut or when the battery is getting tired, and the fans are controlled by Pankha based on the motherboard sensors.

## The software

This is how my home Kubernetes cluster is configured:

| Software                                                       | Used for                                               |
| -------------------------------------------------------------- | ------------------------------------------------------ |
| [k3s](https://k3s.io)                                          | Lightweight Kubernetes distribution                    |
| [Flux](https://fluxcd.io)                                      | Keeps the cluster in sync with this repo               |
| [Renovate](https://www.mend.io/renovate)                       | Opens merge requests when a new app or chart version comes out |
| [Traefik](https://traefik.io)                                  | Ingress controller                                     |
| [MetalLB](https://metallb.io)                                  | Load balancer                                          |
| [Cloudflare Tunnels](https://github.com/cloudflare/cloudflared) | Remote access to the public services                  |
| [AdGuard Home](https://adguard.com/adguard-home/overview.html) | DNS and ad blocking                                    |
| [Authentik](https://goauthentik.io)                            | Single login for every app                             |
| [cert-manager](https://cert-manager.io)                        | HTTPS certificates                                     |
| [Longhorn](https://longhorn.io)                                | App storage                                            |
| [Prometheus](https://prometheus.io), [Loki](https://grafana.com/oss/loki/), [Grafana](https://grafana.com) | Metrics, logs and alerts |

When I push to `main`, a webhook tells Flux right away and the change gets applied in three steps: first the shared settings, then the core services, then the apps. Values that change between setups (domain, timezone, IPs, disk paths) are written once in a single settings file instead of being repeated everywhere.

```mermaid
graph TD
    A[This repo] --> B[Shared settings<br/>namespaces · network rules]
    B --> C[Core services<br/>certificates · secrets · storage · backups]
    C --> D[Apps]
```

### Repo layout

```
clusters/homelab     # where Flux starts, plus the shared settings
infrastructure       # core services the apps depend on
apps                 # one folder per app
bootstrap            # script to rebuild the cluster on a new machine
docs                 # detailed handbook and runbooks
scripts              # helper scripts
schema               # architecture diagrams
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

## Networking

First, a pool of IP addresses is reserved for MetalLB and Traefik is given an IP.
Then, a DNS rewrite is configured in AdGuard Home so browsers in my network can reach every local service at `*.local.gabro.ovh` by asking Traefik for it via hostname. For publicly exposed services Traefik is set as the target of the Cloudflare tunnels.

All services exposed to the outside world do so via a Cloudflare tunnel pod, so no ports are open on my router. Each tunnel runs two pods, so if one goes down the service stays up. Public services also go through Authentik, so you have to log in before reaching any app.

```mermaid
flowchart LR
    subgraph cluster ["Home server"]
        direction LR
        CFD["Cloudflare Tunnel"] --> TR["Traefik"]
        TR -- "from internet" --> AK{"Login<br/>(Authentik)"}
        AK --> APP["App"]
        TR -- "from home" --> APP
    end

    PU(["Internet user"]) --> CFE["Cloudflare"]
    CFE -.-> CFD
    LU(["Home device"]) --> AG["AdGuard DNS"]
    AG -.-> TR
```

### Public services

Here are the services that are exposed to the internet:

| Service                                                   | Used for                                        |
| --------------------------------------------------------- | ----------------------------------------------- |
| [Jellyfin](https://jellyfin.org)                          | Streaming films and TV                          |
| [Dispatcharr](https://github.com/Dispatcharr/Dispatcharr) | Live TV                                         |
| [Nextcloud](https://nextcloud.com)                        | General purpose cloud storage for files         |
| [Immich](https://immich.app)                              | Personal Google Photos substitute               |
| [Navidrome](https://navidrome.org)                        | Music streaming                                 |
| [Matrix](https://matrix.org)                              | Chat                                            |
| [Grafana](https://grafana.com)                            | Monitoring                                      |
| [GitLab](https://about.gitlab.com)                        | Hosting this repo and running the CI            |
| [Authentik](https://goauthentik.io)                       | Centralized authentication provider             |
| Centralino                                                | Home automation panel for the ESP32 boards      |

### Private services

| Service                                                        | Used for                                                 |
| -------------------------------------------------------------- | -------------------------------------------------------- |
| Arr stack                                                      | Feeding Jellyfin and Navidrome                           |
| [AdGuard Home](https://adguard.com/adguard-home/overview.html) | Network filter and DNS rewrites in the local network     |
| [Headlamp](https://headlamp.dev)                               | Kubernetes dashboard                                     |
| Pankha                                                         | Fan and temperature control                              |
| [Homepage](https://gethomepage.dev)                            | Start page with every service                            |

The server itself is only reachable over VPN.

## Storage and backups

- **Longhorn** manages the NVMe drives for the apps
- **MinIO** is used as S3 storage behind Nextcloud
- **Backup jobs** copy app data and databases with restic to the backup drive every week

The backup server only accepts new backups and never lets anyone delete or overwrite the old ones, so even a hacked app can't wipe them. I keep 7 daily, 4 weekly and 12 monthly copies and get an alert if a backup fails.

## Secrets

No passwords or tokens are in this repo. They are stored in Bitwarden Secrets Manager and pulled into the cluster when needed, and when one changes the apps using it restart by themselves. Rotating a password is a single command:

```sh
task autorotate-postgres app=nextcloud   # new database password, everywhere
task rotate-tunnel svc=jellyfin          # new Cloudflare tunnel token
```

## Rebuilding from scratch

If the server dies, a single script sets the whole cluster up again on a fresh Ubuntu machine:

```sh
cp bootstrap/site.env.example bootstrap/site.env   # fill in your domain, IPs and tokens
task render-settings                               # turn it into the settings file, then push
task bootstrap                                     # run on the new machine
```

This brings back the apps and the config, the data comes back separately from the backups. The full walkthrough is in [`docs/INSTRUCTIONS.md`](docs/INSTRUCTIONS.md).

## Day to day

```sh
task status      # what's running
task bad         # anything broken
task reconcile   # sync with Git right now
```

Every change is checked automatically before it's merged, using [kubeconform](https://github.com/yannh/kubeconform) and [flate](https://github.com/home-operations/flate).

# Apps

This folder holds the configuration for the services running in the lab. Each one lives in its own subfolder with its Docker Compose file and any supporting config.

## What's here

These are the self-hosted, open-source services. The compose files show how each is wired up, with real secrets and network specifics pulled out into gitignored `.env` files (see the `.example` templates for the shape of what they expect).

| Service | What it does |
|---|---|
| authelia | Single sign-on and forward-auth that protects the lab behind one login |
| navidrome | Self-hosted music streaming server |
| npm | Nginx Proxy Manager, handles routing and TLS for all services |
| pihole-unbound | Network-wide ad blocking with a private recursive DNS resolver |
| portainer | Web UI for managing the Docker containers |
| vaultwarden | Self-hosted password vault, compatible with Bitwarden apps |
| webserver | Nginx serving the dashboard and proxying the app APIs |
| kuma | Uptime Kuma, monitoring and status dashboards for all services |

## What's not here

This folder does not contain everything running in the lab. The custom apps I built myself are kept private and are intentionally excluded from this repo. Only the open-source services above are published here.

## Secrets

Anything sensitive (passwords, session keys, real network addresses) lives in `.env` or config files that are gitignored. Each service that needs them ships an `.example` template showing what to fill in. To set one up, copy the example and drop in your real values:

```bash
cp example-file.example real-file
# then edit the real file with your values
```

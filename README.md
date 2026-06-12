# Nano Lab

A self-hosted homelab running a handful of containerized apps behind a single login, with automated backups, monitoring, and secure remote access. It all runs on one Ubuntu server. No third-party clouds involved.

## Why I built it

A few reasons:

- I wanted my data on hardware I actually own instead of scattered across cloud services
- I wanted backups that I could trust, which meant verifying them rather than hoping they work
- I wanted one login to get into everything, with nothing exposed to the public internet
- I wanted a solid disaster recovery plan, so the whole thing can come back quickly if something fails

## Network

The physical layout, from the internet down to the lab:

```
                    Internet
                       |
              +--------v--------+
              |   ISP Modem     |   bridge mode (no routing/NAT)
              +--------+--------+
                       |
              +--------v--------+
              | Firewalla Gold  |   router, firewall, VPN gateway
              |      Pro        |
              +--------+--------+
                       |
                       |  LAG (bonded links)
                       |
              +--------v--------+
              | Ubiquiti Flex   |   managed switch
              |    Switch       |
              +--+----+------+--+
                 |    |      |
        +--------+    |      +---------+
        |             |                |
   +----v----+   +----v----+    +------v------+
   | Access  |   |   NAS   |    |  Homelab    |
   | Point   |   | (backup |    |  Server     |
   | (WiFi 7)|   | storage)|    | (this repo) |
   +---------+   +---------+    +-------------+
```

The modem runs in bridge mode so the Firewalla handles all routing, firewalling, NAT, and the VPN gateway. The Firewalla connects to the switch over a bonded LAG for extra throughput and redundancy on that link. The switch then fans out to the access point, the NAS that holds backups, and the homelab server itself.

## Hardware

The gear that makes up the lab and what each piece does:

| Device | Role |
|---|---|
| BOSGAME E4 Air Mini PC | The homelab server. Runs Ubuntu and hosts every container in the stack. |
| UGREEN NAS | Network-attached storage that holds the nightly backups. |
| Firewalla Gold Pro | Router, firewall, and VPN gateway. Everything in and out of the network goes through it. |
| Ubiquiti Flex Switch | Managed switch that ties the Firewalla, access point, NAS, and server together. |
| Firewalla AP 7 | WiFi 7 access point for wireless devices on the network. |
| ISP Modem | Runs in bridge mode so it just passes the connection through to the Firewalla. |

Running everything on a mini PC keeps the whole lab small and power-efficient, which matters for something that's on around the clock.

## Software Architecture

```
                    Internet
                       |
                       | (Tailscale VPN only, no public ports)
                       |
              +--------v--------+
              |  Reverse Proxy  |   TLS termination, routing
              +--------+--------+
                       |
              +--------v--------+
              | Single Sign-On  |   one login protects everything
              +--------+--------+
                       |
        +--------------+--------------+
        |              |              |
   +----v---+    +-----v----+   +-----v-----+
   |  Web   |    |  Self-   |   | Utility & |
   |  Apps  |    |  hosted  |   | Dashboards|
   |        |    | Services |   |           |
   +--------+    +----------+   +-----------+
```

## What's running

A mix of small web apps I built myself and self-hosted open-source services. Here's the breakdown of what runs and why it's there:

**Custom web apps.** A handful of small applications I built for personal and household use. Each one runs as its own containerized service with a Node.js backend and its own data store, kept separate so a problem with one never touches the others. They cover everyday things like tracking, planning, and shared household tools.

**Navidrome (music streaming).** A self-hosted music server that lets me stream my own library to any device through a browser or a Subsonic-compatible app, so my music stays mine instead of living on a streaming service.

**Vaultwarden (password vault).** A lightweight, self-hosted password manager that's compatible with the Bitwarden apps and browser extensions. All my credentials stay on my own hardware instead of a company's servers.

**Pi-hole and Unbound (DNS and ad blocking).** Pi-hole blocks ads and trackers for every device on the network at the DNS level, so there's nothing to install per device. Unbound sits behind it as a recursive resolver, which means DNS lookups go straight to the source instead of through a third-party provider.

**Uptime Kuma (monitoring).** Watches all the services and tracks their uptime, with status dashboards and alerts if anything goes down.

**Portainer (container management).** A web UI for managing the Docker stack, which makes it easy to check logs, restart services, and see what's running without dropping into a terminal every time.

**Authelia (single sign-on).** The authentication layer that everything else sits behind, so one login covers the whole lab.

**Nginx Proxy Manager (reverse proxy).** Handles routing and TLS for all the services, so each app is reachable at its own clean internal address over HTTPS.

There's also a central dashboard that acts as the front door to all of it.

## Features worth mentioning

**Single sign-on.** Every app sits behind a forward-auth layer. The reverse proxy hands each incoming request to the auth service first, and only forwards it to the app once there's a valid session. That means individual apps don't have to implement their own login, and access policies are enforced in one place instead of scattered across services.

**Secure remote access.** The lab is only reachable through a private mesh VPN, so there are no inbound ports open on the public internet and nothing to find with a port scan. Devices on the VPN get a stable address to reach the lab from anywhere, while everything else only answers on the local network. This keeps the attack surface to essentially zero without giving up remote access.

**Trusted certificates.** Internal services are served over HTTPS using a private certificate authority. Once the root CA is trusted on a device, every internal domain gets a valid certificate with no browser warnings, which means real TLS everywhere instead of self-signed cert prompts or unencrypted internal traffic.

**Automated backups.** A scheduled job backs up each service's data nightly to a NAS over a mounted share. Backups rotate on a rolling retention window so old ones clean themselves up, every run reports success or failure through a webhook notification, and any source that fails is retried automatically before the run is marked failed.

**Backup verification.** Backups that exist but can't be restored are worthless, so a separate weekly job opens each backup and checks that the expected data is actually present and readable. If a backup fails the check, the system attempts an automatic restore from the last known good copy and reports what it did, so a silent backup failure can't go unnoticed for weeks.

**Rebuildable from scratch.** A single provisioning script recreates the entire lab: every container and its compose config, all the proxy routes, DNS settings, firewall rules, scheduled jobs, and directory structure. Combined with the backup data, a bare Ubuntu install can be brought back to a fully working lab without manual reconfiguration, which turns disaster recovery into running one script and restoring one set of files.

## Stack

| Layer | What I'm using |
|---|---|
| Host OS | Ubuntu Server |
| Containers | Docker and Docker Compose |
| Reverse proxy | Nginx-based proxy manager |
| Auth | Self-hosted SSO |
| Remote access | Mesh VPN |
| DNS and ad blocking | Pi-hole and Unbound |
| Custom backends | Node.js |
| Storage | Network-attached storage |
| Alerts | Webhook notifications |

---

This is a personal project. Internal addresses, credentials, and the details of the personal apps are left out on purpose.

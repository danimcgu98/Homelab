# Scripts

The automation behind the lab: nightly backups, weekly verification, restores, and a full rebuild script. These run on the homelab server and lean on cron for scheduling.

## What's here

### backup.sh

Backs up every app's data directory to the NAS. Runs nightly at 2 AM via cron. Walks through each source, rsyncs it over to `/mnt/nas-backup/homelab/<timestamp>/`, and writes a small manifest. Old backups rotate out automatically so only the last 7 are kept.

A few things it handles on its own:

- Checks the NAS is actually mounted before doing anything, and bails if it isn't
- Retries a source once if its rsync fails, deleting the partial copy first
- Uses sudo for the root-owned sources (authelia, pihole, portainer)
- Sends a Discord notification at the end, green if everything worked, red if anything failed

### verify-backup.sh

Backups are only useful if they actually restore, so this checks them. Runs weekly on Sunday at 6 AM. It opens the most recent backup and confirms each source has its expected file or directory and that it isn't empty.

If something fails the check, it tries to auto-restore that source from the same backup and flags it. Three possible Discord outcomes: green if all good, yellow if it had to restore something, red if a restore failed and needs hands on it.

### restore.sh

Interactive restore tool for when you need to pull data back from a backup. Run it directly and it lists the available backups, lets you pick one, then lets you choose which apps to restore (or all of them). Stops the relevant container, rsyncs the data back, and starts it again. Asks for confirmation before overwriting anything since this isn't reversible.

### provision.sh

The big one. Rebuilds the entire lab from a fresh Ubuntu install: every container and its compose config, all the nginx routes, DNS settings, directory structure, cron jobs, and these backup scripts. Pair it with the latest backup and a dead server comes back to fully working without manual reconfiguration.

## Secrets

The backup and verify scripts send Discord notifications, which means they need a webhook URL. That lives in a `secrets.env` file next to the scripts that's never committed.

To set it up, copy the example and fill in your real webhook:

```bash
cp secrets.env.example secrets.env
# then edit secrets.env and paste in your webhook
```

The scripts source this file at startup. If it's missing they'll still run, they just skip the notifications and log a warning.

## Scheduling

These are wired up through cron on the server:

```cron
0 2 * * 0 /home/porkchop/scripts/backup.sh          # nightly backup, 2 AM
0 6 * * 0 /home/porkchop/scripts/verify-backup.sh   # weekly verify, Sunday 6 AM
* * * * * docker exec calendar-api node /app/notify.js   # calendar reminders, every minute
```

## Assumptions

These scripts expect a few things about the environment:

- The NAS is mounted at `/mnt/nas-backup`
- App data lives under `/home/porkchop/docker/<app>/`
- Docker and Docker Compose are installed and running
- The user has passwordless sudo for rsync (set up by provision.sh)

Logs land in `/var/log/homelab-backup.log` and `/var/log/homelab-backup-verify.log`.

# Netpicker UID/GID Overview

## EC2 Podman (rootless)

### Container processen (runtime user)

| Container | UID | GID | User |
|---|---|---|---|
| **agent** | 911 | 911 | agent |
| **api** | 911 | 911 | netpicker |
| **celery** | 911 | 911 | netpicker |
| **db** | 0 | 0 | root |
| **frontend** | 911 | 911 | netpicker |
| **gitd** | 911 | 911 | gitd |
| **gitdctrl** | 911 | 911 | gitd |
| **kibbitzer** | 911 | 911 | netpicker |
| **redis** | 0 | 0 | root |
| **swagger** | 0 | 0 | root |
| **syslog-ng** | — | — | *container crasht (Exited status 2, restarting)* |

### Volume ownership (UID:GID in container)

| Volume | Mountpoint | UID:GID |
|---|---|---|
| **pg_data** | /var/lib/postgresql/data | 999:999 |
| **git** | /git | 911:911 |
| **policy-data** | /data (api/celery) | 911:911 |
| **dc-vol** | /dc-vol (agent) | 911:911 |
| **transferium** | /transferium (agent) | 911:911 |
| **transferium** | /transferium (kibbitzer) | 0:0 |
| **kibbitzer** | /celery-worker | 911:911 |
| **secret** | /run/secrets | 911:911 (agent/kibbitzer), 0:0 (overige) |
| **redis** | /data (redis) | 999:1000 |
| **syslog** | /var/lib/syslog-ng | 911:911 (host: 100910:100910) |
| **plugins** | /plugins (kibbitzer) | 0:0 |
| **textfsm** | /textfsm (kibbitzer, bind) | 0:0 |

---

## Sandbox (Docker)

### Container processen (runtime user)

| Container | UID | GID | User |
|---|---|---|---|
| **agent** | 911 | 911 | agent |
| **api** | 911 | 911 | netpicker |
| **celery** | 911 | 911 | netpicker |
| **cisco_ios_mockit** | 0 | 0 | root |
| **db** | 0 | 0 | root |
| **frontend** | 911 | 911 | netpicker |
| **gitd** | 911 | 911 | gitd |
| **gitdctrl** | 911 | 911 | gitd |
| **kibbitzer** | 911 | 911 | netpicker |
| **redis** | 0 | 0 | root |
| **swagger** | 0 | 0 | root |
| **syslog-ng** | 911 | 911 | syslog-ng |
| **transferium** | 911 | 911 | nepicker (typo in image) |

### Volume ownership (UID:GID op mountpoint)

| Volume | Mountpoint | UID:GID |
|---|---|---|
| **dc-vol** | /dc-vol | 911:911 |
| **git** | /git | 911:911 |
| **kibbitzer** | /celery-worker | 911:911 |
| **pg_data** | /var/lib/postgresql/data | 999:999 |
| **policy-data** | /data | 911:911 |
| **redis** | /data (redis) | 999:1000 |
| **secret** | /run/secrets | 911:911 |
| **syslog** | /var/lib/syslog-ng | 911:911 |
| **transferium** | /transferium | 911:911 |

---

## Verschillen tussen Sandbox (Docker) en EC2 (Podman)

| Verschil | Sandbox (Docker) | EC2 (Podman) |
|---|---|---|
| **syslog-ng** | Draait normaal (911:911) | Crasht (exit code 2) |
| **transferium in kibbitzer** | 911:911 | 0:0 |
| **textfsm in kibbitzer** | 1000:1000 | 0:0 |
| **cisco_ios_mockit** | Aanwezig (root) | Ontbreekt |
| **Host UID mapping** | Geen offset (root Docker) | Rootless offset +100000 (bijv. 911 → 100910 op host) |

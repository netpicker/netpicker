# Netpicker on rootless Podman

Rootless Podman runs as a non-root user, so privileged ports and bind mounts
that work on Docker break. [`compose.yml`](compose.yml) is a separate file with
the fixes below; `docker-compose.yml` is left for Docker.

## Run

```bash
./podman/up.sh
# or;
systemctl --user enable --now podman.socket
podman compose -f podman/compose.yml up -d
```

Frontend: http://localhost:8081

## Fixes

**Frontend**; can't bind port 80 (host or container). [`default.conf`](default.conf)
moves nginx to 8081; compose maps `8081:8081`.

**Agent**; default git URL assumes port 80. Set `NETPICKER_GIT_URL: http://frontend:8081/git`.

**api / celery**; mount the Podman socket instead of the (nonexistent) Docker
socket; `${XDG_RUNTIME_DIR}/podman/podman.sock:/var/run/docker.sock:Z`, and drop
`group_add`. Needs `systemctl --user enable --now podman.socket`. Only powers the
in-app service-status panel; the stack runs without it.

**syslog-ng**; cant bind ports 514/601 (exits with code 2). Allow low ports:
`sysctls: { net.ipv4.ip_unprivileged_port_start: "0" }`.

**kibbitzer textfsm**; add `:Z` to the `./textfsm` bind mount or SELinux blocks reads.

`:Z` on a bind mount tells Podman to set the SELinux label so the container can
read it.

## Not handled

`backup.sh`, `restore.sh`, `fix-volume-permissions.sh` are Docker only and assume
no UID offset. Rootless maps uid 911 to ~100910 on the host; adapt before use.

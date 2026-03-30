# Netpicker - Podman Compatibility Changes

Podman rootless runs containers as a non-root user, causing permission issues that don't occur in Docker. The following changes are required.

## Frontend (tester-frontend)

### Problem

Nginx cannot bind to port 80 inside the container (privileged port).

### Solution

1. Create a custom [`default.conf`](default.conf) with nginx listening on port 8081 instead of 80
2. Mount it into the container and update the port mapping in `docker-compose.yml`:

   ```yaml
   frontend:
     ports:
       - '8081:8081'
     volumes:
       - ./default.conf:/etc/nginx/conf.d/default.conf:Z
   ```

> The `:Z` mount option is required for Podman to apply the correct SELinux label so the container process can read the file.

Note that Podman rootless binds to `0.0.0.0`.

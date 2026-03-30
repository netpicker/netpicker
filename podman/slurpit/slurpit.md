# Slurp'it - Podman Compatibility Changes

Podman rootless runs containers as a non-root user, causing permission issues that don't occur in Docker. The following changes are required.

## Portal

### Problem

Nginx workers run as `nobody` by default, but PHP-FPM creates its socket (`/run/php/php8.4-fpm.sock`) owned by `nginx:nginx` with `rw-rw----` permissions. The `nobody` user cannot access the socket, causing all requests to fail.

### Solution

1. Create a custom [`nginx.conf`](nginx.conf) that adds `user nginx;` at the top, so nginx workers run as the `nginx` user (matching the socket owner).
2. Mount it into the container and publish ports in `docker-compose.yml`:
   ```yaml
   slurpit-portal:
     ports:
       - "8082:80"
       - "8443:443"
     volumes:
       - ./nginx.conf:/etc/nginx/nginx.conf:Z
   ```

> The `:Z` mount option is required for Podman to apply the correct SELinux label so the container process can read the file.

Note that Podman rootless binds to `0.0.0.0`.

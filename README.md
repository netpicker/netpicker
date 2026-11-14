# Netpicker

Advance your network automation with Netpicker

Config backup, security / compliance testing and job automation in one platform. Check out our website at https://netpicker.io to get started.

## Documentation

- [Authentication Configuration](docs/authentication/README.md) - Configure LDAP, SAML, or OAuth authentication

## Updating

Run `./update.sh` in this directory. It checks the installation first (local
edits of the compose files, the pinned compose file, the docker socket group,
outdated images, disk space), explains what it finds and fixes it after asking,
then backs up the volumes and updates to the latest version. Use
`./update.sh --dry-run` to only see what it would do, and
`./update.sh --rollback` to go back to the version of before the last update.

Keep local settings in `docker-compose.override.yml` (see
`docker-compose.override.yml.sample`), not in the compose files of the repo, so
updates keep them. An installation older than update.sh can get it with:

    curl -fsSLO https://raw.githubusercontent.com/netpicker/netpicker/main/update.sh && bash update.sh

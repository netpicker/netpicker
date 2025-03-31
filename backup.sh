#!/bin/bash

set -e

echo "Stopping containers with docker compose..."
docker compose down

VOLUMES=$(docker volume ls -q | grep '^netpicker')

if [ -z "$VOLUMES" ]; then
    echo "No netpicker volumes found to backup."
    exit 1
fi

# Create a temporary directory for staging
TMP_DIR=$(mktemp -d)

# Copy contents of each volume into the staging directory
echo "Staging volume data..."
for VOLUME in $VOLUMES; do
    VOLUME_PATH=$(docker volume inspect "$VOLUME" -f '{{ .Mountpoint }}')
    mkdir -p "$TMP_DIR/$VOLUME"
    sudo cp -a "$VOLUME_PATH/." "$TMP_DIR/$VOLUME"
done

# Create the backup tarball
echo "Creating backup archive..."
tar -cf netpicker_backup.tar -C "$TMP_DIR" .

# Clean up
rm -rf "$TMP_DIR"

echo "Backup completed successfully!"
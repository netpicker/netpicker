#!/bin/bash

set -e

# Check if backup file exists
if [ ! -f "netpicker_backup.tar" ]; then
    echo "Error: netpicker_backup.tar not found!"
    exit 1
fi

echo "Stopping containers with docker compose..."
docker compose down

# Create a temporary directory for staging
TMP_DIR=$(mktemp -d)

# Extract the backup archive
echo "Extracting backup archive..."
sudo tar -xf netpicker_backup.tar -C "$TMP_DIR"

# Restore each volume
echo "Restoring volumes..."
for VOLUME_DIR in "$TMP_DIR"/*; do
    if [ -d "$VOLUME_DIR" ]; then
        VOLUME_NAME=$(basename "$VOLUME_DIR")
        echo "Restoring volume: $VOLUME_NAME"
        
        # Create the volume if it doesn't exist
        if ! docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
            docker volume create "$VOLUME_NAME"
        fi
        
        # Get the volume mount point
        VOLUME_PATH=$(docker volume inspect "$VOLUME_NAME" -f '{{ .Mountpoint }}')
        
        # Copy the restored data to the volume
        sudo cp -a "$VOLUME_DIR/." "$VOLUME_PATH/"
    fi
done

# Clean up
sudo rm -rf "$TMP_DIR"

echo "Restore completed successfully!" 
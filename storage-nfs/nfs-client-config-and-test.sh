#!/bin/bash
# NFS Client Setup Script for Kubernetes Nodes

# Install NFS client packages
echo "Installing NFS client packages..."
apt-get update
apt-get install -y nfs-common

# Test NFS mount
echo "Testing NFS mount from server 192.168.48.19..."
mkdir -p /mnt/nfs-test
mount -t nfs 192.168.48.19:/exports/data /mnt/nfs-test

if [ $? -eq 0 ]; then
    echo "NFS mount successful!"
    echo "Test: Creating a file in the NFS share..."
    touch /mnt/nfs-test/test-file-from-$(hostname)
    echo "Test complete. Unmounting test directory..."
    umount /mnt/nfs-test
    rmdir /mnt/nfs-test
else
    echo "NFS mount failed. Please check your network connection and NFS server configuration."
fi

echo "NFS client setup complete"

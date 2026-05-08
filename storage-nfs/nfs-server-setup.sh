#!/bin/bash
# NFS Server Setup Script for IP 192.168.48.19

# Install NFS server packages
echo "Installing NFS server packages..."
apt-get update
apt-get install -y nfs-kernel-server

# Create export directory
echo "Creating NFS export directory..."
mkdir -p /exports/data

# Set permissions
echo "Setting directory permissions..."
chown nobody:nogroup /exports/data
chmod 777 /exports/data

# Configure exports
echo "Configuring NFS exports..."
cat > /etc/exports << EOF
/exports/data    192.168.48.0/24(rw,sync,no_subtree_check,no_root_squash)
EOF

# Apply exports configuration
echo "Applying NFS export configuration..."
exportfs -a

# Restart NFS server
echo "Restarting NFS server..."
systemctl restart nfs-kernel-server

# Enable NFS server to start on boot
echo "Enabling NFS server on boot..."
systemctl enable nfs-kernel-server

# Show status
echo "NFS server status:"
systemctl status nfs-kernel-server

# Show exported filesystems
echo "Exported filesystems:"
showmount -e localhost

echo "NFS Server setup complete at 192.168.48.19"
echo "Export path: 192.168.48.19:/exports/data"

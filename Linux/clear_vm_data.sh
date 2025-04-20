#!/bin/bash

# Exit on any error
set -e

echo "Starting VM cleanup process..."

# 1. Stop any running services
echo "Stopping unnecessary services..."
# sudo systemctl stop apache2 || true
# sudo systemctl stop mysql || true

# 2. Clear temporary files
echo "Clearing temporary files..."
sudo rm -rf /tmp/*
sudo rm -rf /var/tmp/*

# 3. Clear DNS configuration
#echo "Clearing DNS configuration..."
#sudo sed -i '/^search/d' /etc/resolv.conf

# 4. Remove user-specific data
echo "Checking for home directories..."

# Check if any directories exist under /home
if [ "$(ls -A /home 2>/dev/null)" ]; then
echo "Home directories found. Proceeding with cleanup..."
# Remove specific user files
sudo find /home/* -type f \( -name "*.log" -o -name "*.cache" \) -exec rm -f {} \;
sudo rm -rf /home/*/.bash_history
else
echo "No home directories found. Skipping cleanup."
fi

# Always clean root's bash history
sudo rm -rf /root/.bash_history
history -c

# 5. Clear log files
echo "Clearing log files..."
sudo truncate -s 0 /var/log/*.log
sudo truncate -s 0 /var/log/**/*.log || true

# 6. Remove SSH keys (if applicable)
echo "Removing SSH keys..."
sudo rm -rf /etc/ssh/ssh_host_*

# 7. Clear package cache
echo "Clearing package cache..."
sudo apt-get clean
sudo apt-get autoclean

# 8. Remove unnecessary packages and old kernels
echo "Removing unnecessary packages..."
sudo apt-get autoremove -y --purge

# 9. Reset machine ID (optional for templates)
echo "Resetting machine ID..."
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id

# 10. Reset cloud-init instance
echo "Resetting cloud-init..."
sudo cloud-init clean

echo "Cleanup complete! The VM is ready for templating."

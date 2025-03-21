#!/bin/bash
set -e

# This must be run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root"
    exit 1
fi

# Install prerequisites
echo "Installing system prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y python3 python3-pip libyaml-dev python3-venv sudo apt-transport-https \
    ca-certificates curl software-properties-common openssh-server rsync iptables-persistent iptables

# Add Docker's official GPG key
echo "Adding Docker repository"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Add Docker repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update again to include Docker repository and install Docker
echo "Installing Docker"
apt update -y
apt install -y docker-ce docker-ce-cli containerd.io

# Stop Docker service before configuring storage
echo "Stopping Docker service for data directory configuration"
systemctl stop docker || echo "Docker was not running, continuing..."

# Configure Docker storage on /dev/vda
echo "Setting up Docker data directory on dedicated disk (/dev/vda)"

# Find where /dev/vda is currently mounted (if at all)
CURRENT_MOUNT=$(df -h | grep "/dev/vda" | awk '{print $6}' | head -1)

if [ -n "$CURRENT_MOUNT" ]; then
    echo "Device /dev/vda is currently mounted at $CURRENT_MOUNT"
    
    # Create Docker directory on the existing mount
    mkdir -p "${CURRENT_MOUNT}/docker"
    
    # Migrate existing Docker data if any
    if [ -d "/var/lib/docker" ] && [ -n "$(ls -A /var/lib/docker 2>/dev/null)" ]; then
        echo "Migrating existing Docker data to ${CURRENT_MOUNT}/docker..."
        rsync -a /var/lib/docker/ "${CURRENT_MOUNT}/docker/"
    fi
    
    # Configure Docker to use this directory
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << EOF
{
  "data-root": "${CURRENT_MOUNT}/docker",
  "iptables": true
}
EOF
    echo "Docker data will be stored at ${CURRENT_MOUNT}/docker"
else
    echo "Device /dev/vda is not currently mounted"
    
    # Check if /dev/vda exists
    if [ -b "/dev/vda" ]; then
        echo "Found /dev/vda device"
        
        # Create partition if needed
        if ! fdisk -l "/dev/vda" | grep -q "Linux filesystem"; then
            echo "Partitioning disk /dev/vda..."
            (
                echo g # Create a new empty GPT partition table
                echo n # Add a new partition
                echo   # Accept default partition number
                echo   # Accept default first sector
                echo   # Accept default last sector (use entire disk)
                echo w # Write changes
            ) | fdisk "/dev/vda" || { echo "Partitioning failed"; exit 1; }
            
            # Format the partition
            echo "Formatting new partition..."
            mkfs.ext4 "/dev/vda1" || { echo "Formatting failed"; exit 1; }
        fi
        
        # Mount the proper partition
        PARTITION=$(fdisk -l "/dev/vda" | grep "Linux filesystem" | head -1 | awk '{print $1}')
        
        if [ -n "$PARTITION" ]; then
            echo "Found usable partition: $PARTITION"
            
            # Backup and migrate existing Docker data
            TEMP_MOUNT=$(mktemp -d)
            echo "Temporarily mounting $PARTITION to $TEMP_MOUNT"
            mount "$PARTITION" "$TEMP_MOUNT" || { echo "Mount failed"; rmdir "$TEMP_MOUNT"; exit 1; }
            
            # Create Docker directory
            mkdir -p "$TEMP_MOUNT/docker"
            
            # Migrate existing Docker data if any
            if [ -d "/var/lib/docker" ] && [ -n "$(ls -A /var/lib/docker 2>/dev/null)" ]; then
                echo "Migrating existing Docker data to $TEMP_MOUNT/docker..."
                rsync -a /var/lib/docker/ "$TEMP_MOUNT/docker/"
            fi
            
            # Unmount temporary location
            umount "$TEMP_MOUNT"
            rmdir "$TEMP_MOUNT"
            
            # Mount to the actual Docker data directory
            echo "Mounting $PARTITION to /var/lib/docker"
            mkdir -p /var/lib/docker
            mount "$PARTITION" /var/lib/docker || { echo "Failed to mount to /var/lib/docker"; exit 1; }
            
            # Add to fstab for persistence
            if ! grep -q "$PARTITION /var/lib/docker" /etc/fstab; then
                echo "Adding entry to fstab for persistence"
                echo "$PARTITION /var/lib/docker ext4 defaults 0 2" >> /etc/fstab
            fi
        else
            echo "No usable partition found on /dev/vda"
            echo "Continuing with default Docker data location"
        fi
    else
        echo "Device /dev/vda not found"
        echo "Continuing with default Docker data location"
    fi
fi

# Start Docker with new settings
echo "Starting Docker with new configuration"
systemctl daemon-reload
systemctl enable docker
systemctl start docker

# Verify Docker is working
echo "Verifying Docker is working properly..."
if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker failed to start properly with the new configuration"
    echo "Rolling back changes..."
    
    if ls /var/lib/docker-backup/docker-data-* >/dev/null 2>&1; then
        # Restore from backup
        BACKUP_FILE=$(ls -t /var/lib/docker-backup/docker-data-* | head -1)
        echo "Restoring from backup: $BACKUP_FILE"
        rm -rf /var/lib/docker/* 2>/dev/null || true
        tar -xzf "$BACKUP_FILE" -C /var/lib/docker
        rm -f /etc/docker/daemon.json
        systemctl start docker
        
        if ! docker info >/dev/null 2>&1; then
            echo "Docker still not working after rollback. Manual intervention required."
            exit 1
        fi
    else
        echo "No backup found, cannot rollback. Manual intervention required."
        exit 1
    fi
else
    echo "✅ Docker is running successfully with the new data directory"
fi

# Create new admin user
NEW_USER="tutor"
USER_PASSWORD="tutorpassword"
echo "Creating new admin user: $NEW_USER with password: $USER_PASSWORD"
useradd -m -s /bin/bash "$NEW_USER" || echo "User $NEW_USER already exists"

# Set password non-interactively
echo "$NEW_USER:$USER_PASSWORD" | chpasswd

# Add to sudo and docker groups
usermod -aG sudo "$NEW_USER"
usermod -aG docker "$NEW_USER"

# Configure passwordless sudo for the new user
echo "$NEW_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$NEW_USER
chmod 440 /etc/sudoers.d/$NEW_USER

# Create SSH directory for the new user
mkdir -p /home/$NEW_USER/.ssh
chmod 700 /home/$NEW_USER/.ssh
touch /home/$NEW_USER/.ssh/authorized_keys
chmod 600 /home/$NEW_USER/.ssh/authorized_keys
chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/.ssh

# Secure SSH server - disable password authentication
echo "Configuring SSH for key-based authentication only"
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
# In case the line is not commented out already
sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
# Make sure it's in the config even if it wasn't there
if ! grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
fi

# Restart SSH service to apply changes (using correct service name)
echo "Restarting SSH service"
if systemctl is-active --quiet ssh.service; then
    systemctl restart ssh.service
elif systemctl is-active --quiet sshd.service; then
    systemctl restart sshd.service
else
    echo "Warning: Could not identify SSH service name. Manual restart may be required."
    # Try both common service names
    systemctl restart ssh.service 2>/dev/null || true
    systemctl restart sshd.service 2>/dev/null || true
fi

# Set up Tutor for the new user
echo "Setting up Tutor for user $NEW_USER"
mkdir -p /home/$NEW_USER/tutor-env
python3 -m venv /home/$NEW_USER/tutor-env
/home/$NEW_USER/tutor-env/bin/pip install --upgrade pip
/home/$NEW_USER/tutor-env/bin/pip install "tutor[full]"

# Add tutor to PATH in user's .bashrc
echo 'export PATH="$HOME/tutor-env/bin:$PATH"' >> /home/$NEW_USER/.bashrc

# Create directories for Tutor data
mkdir -p /home/$NEW_USER/.local/share/tutor
chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/.local

# Fix permissions
chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/tutor-env

# Simple security configuration that works with Docker
echo "Setting up basic security rules..."

# Make sure Docker is running (to ensure its chains are created)
systemctl start docker

# Wait a moment for Docker to set up its chains
sleep 5

# Now add our rules in a way that doesn't interfere with Docker's chains
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# Set default policy after allowing necessary traffic
iptables -P INPUT DROP

# Save iptables rules for persistence
echo "Saving iptables rules for persistence..."
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

# Cluster parameters
CLUSTER_TOKEN="threefold-secure-token"
VIRTUAL_IP="10.1.0.100"

# First node as init server
if [ "$(hostname)" == "k8s-node-0" ]; then
  curl -sfL https://get.k3s.io | K3S_TOKEN=${CLUSTER_TOKEN} sh -s - server \
    --cluster-init \
    --node-ip 10.1.0.2 \
    --tls-san ${VIRTUAL_IP} \
    --disable traefik \
    --kubelet-arg="--cloud-provider=external" \
    --etcd
else
  # Join other nodes
  curl -sfL https://get.k3s.io | K3S_TOKEN=${CLUSTER_TOKEN} sh -s - agent \
    --server https://${VIRTUAL_IP}:6443 \
    --node-ip 10.1.0.$((${HOSTNAME##*-}+2))
fi

# Install Ceph storage
if [ "$(hostname)" == "k8s-node-0" ]; then
  kubectl apply -f https://raw.githubusercontent.com/rook/rook/v1.9.12/deploy/examples/crds.yaml
  kubectl apply -f https://raw.githubusercontent.com/rook/rook/v1.9.12/deploy/examples/common.yaml
  kubectl apply -f https://raw.githubusercontent.com/rook/rook/v1.9.12/deploy/examples/operator.yaml

  cat <<EOF | kubectl apply -f -
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: threefold-ceph
  namespace: rook-ceph
spec:
  dataDirHostPath: /var/lib/rook
  mon:
    count: 3
    allowMultiplePerNode: false
  cephVersion:
    image: ceph/ceph:v16.2.9
  storage:
    useAllNodes: true
    useAllDevices: true
  healthCheck:
    daemonHealth:
      status:
        interval: 10s
EOF
fi

# Install Tutor
python3 -m venv /opt/tutor
/opt/tutor/bin/pip install "tutor[full]"
ln -s /opt/tutor/bin/tutor /usr/local/bin/tutor

# Configure HA Tutor
tutor config save \
  --set DOCKER_REGISTRY=ghcr.io/overhangio \
  --set K8S_ANTI_AFFINITY=true \
  --set K8S_POD_REPLICAS_LMS=3 \
  --set K8S_POD_REPLICAS_CMS=2 \
  --set ENABLE_WEB_PROXY=true

# Generate Kubernetes manifests
tutor k8s configure --ha

# Launch Open edX
tutor k8s launch

echo "======== Deployment Completed Successfully ========"
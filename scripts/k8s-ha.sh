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

# Install k3s (Kubernetes)
echo "Installing k3s (Kubernetes)"

# Cluster parameters
CLUSTER_TOKEN="threefold-secure-token"
VIRTUAL_IP="10.1.0.100"

# Determine the node's IP based on hostname
NODE_IP=""
if [ "$(hostname)" == "k8s-node-1" ]; then
  NODE_IP="10.1.3.2"
elif [ "$(hostname)" == "k8s-node-2" ]; then
  NODE_IP="10.1.4.2"
elif [ "$(hostname)" == "k8s-node-3" ]; then
  NODE_IP="10.1.5.2"
else
  echo "Unknown hostname: $(hostname). Cannot determine node IP."
  exit 1
fi

# First node as init server
if [ "$(hostname)" == "k8s-node-1" ]; then
  curl -sfL https://get.k3s.io | K3S_TOKEN=${CLUSTER_TOKEN} sh -s - server \
    --cluster-init \
    --node-ip ${NODE_IP} \
    --tls-san ${VIRTUAL_IP} \
    --disable traefik \
    --kubelet-arg="--cloud-provider=external" \
    --data-dir /basedisk/k3s-data \
    --write-kubeconfig-mode 644

else
  # Join other nodes
  curl -sfL https://get.k3s.io | K3S_TOKEN=${CLUSTER_TOKEN} sh -s - agent \
    --server https://${VIRTUAL_IP}:6443 \
    --node-ip ${NODE_IP} \
    --data-dir /basedisk/k3s-data  # Add --data-dir for agent nodes as well
fi

# Install Ceph on the first node
if [ "$(hostname)" == "k8s-node-1" ]; then
  echo "Installing Ceph for distributed storage"

  # Install Ceph CRDs and operator
  kubectl apply -f https://raw.githubusercontent.com/rook/rook/v1.9.12/deploy/examples/crds.yaml
  kubectl apply -f https://raw.githubusercontent.com/rook/rook/v1.9.12/deploy/examples/common.yaml
  kubectl apply -f https://raw.githubusercontent.com/rook/rook/v1.9.12/deploy/examples/operator.yaml

  # Deploy Ceph cluster
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

# Create new admin user
NEW_USER="tutor"
USER_PASSWORD="tutorpassword"
echo "Creating new admin user: $NEW_USER with password: $USER_PASSWORD"
useradd -m -s /bin/bash "$NEW_USER" || echo "User $NEW_USER already exists"

# Set password non-interactively
echo "$NEW_USER:$USER_PASSWORD" | chpasswd

# Add to sudo group
usermod -aG sudo "$NEW_USER"

# Configure passwordless sudo for the new user
echo "$NEW_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$NEW_USER
chmod 440 /etc/sudoers.d/$NEW_USER

# Create SSH directory for the new user
mkdir -p /home/$NEW_USER/.ssh
chmod 700 /home/$NEW_USER/.ssh
touch /home/$NEW_USER/.ssh/authorized_keys
chmod 600 /home/$NEW_USER/.ssh/authorized_keys
chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/.ssh
cp /root/.ssh/authorized_keys /home/$NEW_USER/.ssh/authorized_keys

# Secure SSH server - disable password authentication
echo "Configuring SSH for key-based authentication only"
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
if ! grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
fi

# Restart SSH service
echo "Restarting SSH service"
systemctl restart ssh

# Set up Tutor for the new user
echo "Setting up Tutor for user $NEW_USER"
sudo -u "$NEW_USER" bash << EOF
# Create virtual environment
python3 -m venv "/home/$NEW_USER/tutor-env"
"/home/$NEW_USER/tutor-env/bin/pip" install --upgrade pip
"/home/$NEW_USER/tutor-env/bin/pip" install "tutor[full]"

# Add tutor to PATH in user's .bashrc
echo 'export PATH="\$HOME/tutor-env/bin:\$PATH"' >> "/home/$NEW_USER/.bashrc"
EOF

echo "======== Deployment Completed Successfully ========"

# Display Tutor configuration and deployment commands to the user
echo "To configure HA Tutor, run the following commands as the $NEW_USER user:"
echo ""
echo "  su - tutor"
echo "  source /home/tutor/tutor-env/bin/activate"
echo "  tutor config save \\"
echo "    --set DOCKER_REGISTRY=ghcr.io/overhangio \\"
echo "    --set K8S_ANTI_AFFINITY=true \\"
echo "    --set K8S_POD_REPLICAS_LMS=3 \\"
echo "    --set K8S_POD_REPLICAS_CMS=2 \\"
echo "    --set ENABLE_WEB_PROXY=true"
echo ""
echo "To launch Open edX, run:"
echo "  tutor k8s launch"
echo ""
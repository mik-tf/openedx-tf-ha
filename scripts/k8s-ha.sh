#!/bin/bash
set -e

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
<h1> Open edX High Availability Deployment on ThreeFold Grid</h1>

<h2> Table of Contents</h2>

- [Introduction](#introduction)
- [Key Features](#key-features)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
  - [Preparation](#preparation)
  - [Deployment Steps](#deployment-steps)
- [Maintenance](#maintenance)
  - [Scaling Open edX](#scaling-open-edx)
  - [Backups](#backups)
  - [Upgrades](#upgrades)
- [Clean Up](#clean-up)
- [License](#license)

---

## Introduction

This project enables the deployment of a production-grade Open edX environment on the ThreeFold Grid. The setup includes:

- **High Availability (HA) Architecture**: A 3-node Kubernetes cluster with etcd, Ceph distributed storage, and anti-affinity rules for resilience.
- **ThreeFold Integration**: Utilizes WireGuard for encrypted overlay networking for seamless access.
- **Automated Deployment**: OpenTofu scripts for infrastructure provisioning and a Bash script for Kubernetes cluster setup.

This deployment provides a robust, production-ready Open edX environment on the ThreeFold Grid. By leveraging Kubernetes, WireGuard, and Ceph, it ensures high availability, scalability, and resilience, making it ideal for educational institutions and organizations.

## Key Features

- **True HA Architecture**:
  - 3-node etcd cluster for fault tolerance.
  - Ceph distributed storage for data redundancy.
  - Pod anti-affinity rules to ensure high availability.
- **ThreeFold Integration**:
  - WireGuard encrypted overlay network for secure communication.
  - Planetary network access for decentralized connectivity.
  - Grid storage provisioning for scalable storage.
- **Auto-Healing**:
  - Automatic pod rescheduling in case of node failures.
  - Storage replication for data durability.
  - Node failure detection and recovery.


## Prerequisites

Before proceeding, ensure you have the following:

1. **OpenTofu**: Install OpenTofu from [here](https://opentofu.org/docs/intro/install/).
2. **WireGuard**: Install WireGuard from [here](https://www.wireguard.com/install/).
3. **ThreeFold Account**:
   - A ThreeFold Grid account with sufficient TFT (ThreeFold Token) balance.
   - Your ThreeFold mnemonic seed phrase.
4. **SSH Key**: A public SSH key for accessing the deployed nodes.


## Getting Started

### Preparation

1. Clone this repository:
   ```bash
   git clone https://github.com/mik-tf/openedx-tf-ha
   cd openedx-tf-ha/deployment
   ```

2. Copy the example credentials file and update it with your details:
   ```bash
   cp credentials.auto.tfvars.example credentials.auto.tfvars
   ```
   Edit `credentials.auto.tfvars` to include your:
   - ThreeFold mnemonic.
   - SSH public key.
   - ThreeFold node IDs for the deployment.

### Deployment Steps

1. **Initialize OpenTofu**:
   ```bash
   tofu init
   ```

2. **Deploy Infrastructure**:
   ```bash
   tofu apply
   ```
   This will provision the nodes and set up the WireGuard network.

3. **Configure WireGuard**:
   - Copy the WireGuard configuration from the OpenTofu output.
   - Save it to `/etc/wireguard/tfgrid.conf` and start the interface:
    ```bash
    sudo mkdir -p /etc/wireguard
    sudo nano /etc/wireguard/tfgrid.conf
    wg-quick up tfgrid
    ```
    
4. **Install Kubernetes**:
   - Use the `k8s-ha.sh` script to set up the Kubernetes cluster on each node. For each node, set a unique hostname (e.g. node-1, node-2, node-3).
     ```bash
     scp ../scripts/k8s-ha.sh root@<node_ip>:/root/
     ssh root@<node_ip>
     hostnamectl set-hostname k8s-node-X
     bash k8s-ha.sh
     ```

5. **Verify the Cluster**:
   ```bash
   kubectl get nodes -o wide
   kubectl -n openedx get pods
   ```

## Maintenance

### Scaling Open edX
To scale the Open edX LMS or CMS services:
```bash
kubectl -n openedx scale deployment/lms --replicas=5
```

### Backups
Create a backup of the Open edX cluster using Velero:
```bash
velero backup create openedx-backup --include-namespaces openedx,rook-ceph
```

### Upgrades
To upgrade the Tutor deployment:
```bash
tutor k8s stop
tutor k8s start
```

## Clean Up

To destroy the deployment and clean up resources:
```bash
tofu destroy -auto-approve
wg-quick down tfgrid
```

## License

This project is licensed under the [Apache License 2.0](LICENSE).

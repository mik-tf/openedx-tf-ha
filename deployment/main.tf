terraform {
  required_providers {
    grid = {
      source  = "threefoldtech/grid"
    }
  }
}

variable "mnemonic" {
  type = string
}

variable "SSH_KEY" {
  type = string
}

variable "tfnodeid1" {
  type = string
}

variable "tfnodeid2" {
  type = string
}

variable "tfnodeid3" {
  type = string
}

variable "size" {
  type = string
}

variable "cpu" {
  type = string
}

variable "memory" {
  type = string
}

provider "grid" {
  mnemonic = var.mnemonic
  network = "main"
}

locals {
  name = "tfvm"
}

resource "grid_network" "net1" {
  name        = local.name
  nodes       = [var.tfnodeid1, var.tfnodeid2, var.tfnodeid3]
  ip_range    = "10.1.0.0/16"
  description = "newer network"
  add_wg_access = true
}

resource "grid_deployment" "d1" {
  disks {
    name = "disk1"
    size = var.size
  }
  name         = local.name
  node         = var.tfnodeid1
  network_name = grid_network.net1.name
  vms {
    name  = "vm1"
    flist = "https://hub.grid.tf/tf-official-vms/ubuntu-24.04-full.flist"
    cpu   = var.cpu
    mounts {
        name = "disk1"
        mount_point = "/disk1"
    }
    memory     = var.memory
    entrypoint = "/sbin/zinit init"
    env_vars = {
      SSH_KEY = var.SSH_KEY
    }
    publicip   = true
  }
}

resource "grid_deployment" "d2" {
  disks {
    name = "disk2"
    size = var.size
  }
  name         = local.name
  node         = var.tfnodeid2
  network_name = grid_network.net1.name

  vms {
    name       = "vm2"
    flist      = "https://hub.grid.tf/tf-official-vms/ubuntu-24.04-full.flist"
    cpu        = var.cpu
    mounts {
        name = "disk2"
        mount_point = "/disk2"
    }
    memory     = var.memory
    entrypoint = "/sbin/zinit init"
    env_vars = {
      SSH_KEY = var.SSH_KEY
    }
    publicip   = true
  }
}

resource "grid_deployment" "d3" {
  disks {
    name = "disk3"
    size = var.size
  }
  name         = local.name
  node         = var.tfnodeid3
  network_name = grid_network.net1.name

  vms {
    name       = "vm3"
    flist      = "https://hub.grid.tf/tf-official-vms/ubuntu-24.04-full.flist"
    cpu        = var.cpu
    mounts {
        name = "disk3"
        mount_point = "/disk3"
    }
    memory     = var.memory
    entrypoint = "/sbin/zinit init"
    env_vars = {
      SSH_KEY = var.SSH_KEY
    }
    publicip   = true
  }
}


output "wg_config" {
  value = grid_network.net1.access_wg_config
}
output "vm1_wg" {
  value = grid_deployment.d1.vms[0].ip
}
output "vm2_wg" {
  value = grid_deployment.d2.vms[0].ip
}
output "vm3_wg" {
  value = grid_deployment.d3.vms[0].ip
}

output "vm1_ipv4" {
  value = grid_deployment.d1.vms[0].computedip
}

output "vm2_ipv4" {
  value = grid_deployment.d2.vms[0].computedip
}

output "vm3_ipv4" {
  value = grid_deployment.d3.vms[0].computedip
}
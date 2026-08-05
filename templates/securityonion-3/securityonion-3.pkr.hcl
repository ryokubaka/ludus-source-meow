variable "description" {
  type    = string
  default = "Security Onion 3 Standalone-ready base. so-setup runs at range deploy."
}

variable "icon_path" {
  type    = string
  default = "icon.png"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:62FAB57E247C843D6A04F0796D8162C732B65D82FC3E4A59D087135B9FD32912"
}

variable "os" {
  type    = string
  default = "l26"
}

variable "iso_url" {
  type    = string
  default = "https://download.securityonion.net/file/securityonion/securityonion-3.1.0-20260528.iso"
}

variable "vm_cpu_cores" {
  type    = string
  default = "4"
}

variable "vm_disk_size" {
  type    = string
  default = "200G"
}

variable "vm_memory" {
  type    = string
  default = "8192"
}

variable "vm_name" {
  type    = string
  default = "securityonion-3-x64-template"
}

variable "ssh_password" {
  type    = string
  default = "onion"
}

variable "ssh_username" {
  type    = string
  default = "onion"
}

variable "proxmox_url" {
  type = string
}
variable "proxmox_host" {
  type = string
}
variable "proxmox_username" {
  type = string
}
variable "proxmox_password" {
  type      = string
  sensitive = true
}
variable "proxmox_storage_pool" {
  type = string
}
variable "proxmox_storage_format" {
  type = string
}
variable "proxmox_skip_tls_verify" {
  type = bool
}
variable "proxmox_pool" {
  type = string
}
variable "iso_storage_pool" {
  type = string
}
variable "ansible_home" {
  type = string
}
variable "ludus_nat_interface" {
  type = string
}

locals {
  template_description = "Security Onion 3.1.0 template built ${legacy_isotime("2006-01-02 03:04:05")} username:password => onion:onion (so-setup not run)"
}

source "proxmox-iso" "securityonion3" {
  boot_command = [
    "<tab><wait>",
    " ip=dhcp inst.text inst.cmdline",
    " ks=cdrom:/dev/sr1:/ks.cfg",
    " inst.ks=cdrom:/dev/sr1:/ks.cfg",
    "<enter>"
  ]
  boot_wait         = "12s"
  boot_key_interval = "50ms"
  communicator      = "none"

  cores           = "${var.vm_cpu_cores}"
  cpu_type        = "host"
  scsi_controller = "virtio-scsi-single"
  qemu_agent      = true
  disks {
    disk_size         = "${var.vm_disk_size}"
    format            = "${var.proxmox_storage_format}"
    storage_pool      = "${var.proxmox_storage_pool}"
    type              = "scsi"
    ssd               = true
    discard           = true
    io_thread         = true
  }
  pool                     = "${var.proxmox_pool}"
  insecure_skip_tls_verify = "${var.proxmox_skip_tls_verify}"
  boot_iso {
    type              = "ide"
    iso_url           = "${var.iso_url}"
    iso_checksum      = "${var.iso_checksum}"
    iso_storage_pool  = "${var.iso_storage_pool}"
    iso_download_pve  = true
    unmount           = true
    keep_cdrom_device = false
  }
  additional_iso_files {
    type             = "ide"
    index            = "1"
    iso_storage_pool = "${var.iso_storage_pool}"
    unmount          = true
    cd_files         = ["./http/ks.cfg"]
    cd_label         = "OEMDRV"
  }
  memory = "${var.vm_memory}"
  network_adapters {
    bridge      = "${var.ludus_nat_interface}"
    model       = "virtio"
    mac_address = "BC:24:11:50:03:01"
  }
  node                 = "${var.proxmox_host}"
  os                   = "${var.os}"
  password             = "${var.proxmox_password}"
  proxmox_url          = "${var.proxmox_url}"
  template_description = "${local.template_description}"
  username             = "${var.proxmox_username}"
  vm_name              = "${var.vm_name}"
  task_timeout         = "60m"
}

build {
  sources = ["source.proxmox-iso.securityonion3"]

  provisioner "shell-local" {
    execute_command = ["bash", "-c", "{{.Vars}} {{.Script}}"]
    env = {
      VM_NAME      = "${var.vm_name}"
      SSH_USER     = "${var.ssh_username}"
      SSH_PASS     = "${var.ssh_password}"
      PLAYBOOK     = "ansible/reset-ssh-host-keys.yml"
      ANSIBLE_HOME = "${var.ansible_home}"
      MAX_WAIT_SEC = "7200"
      EXPECT_MAC   = "BC:24:11:50:03:01"
    }
    script = "scripts/packer-provision-via-dhcp.sh"
  }
}

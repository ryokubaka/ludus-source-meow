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
  # SO ISO ships ks=cdrom with an interactive "type yes" disk wipe. Override it:
  # 1) OEMDRV CD (Anaconda auto-picks LABEL=OEMDRV)
  # 2) Explicit inst.ks=hd:LABEL=OEMDRV + ip=dhcp
  boot_command = [
    "<up><wait>",
    "<tab><wait>",
    " ip=dhcp inst.text inst.cmdline inst.ks=hd:LABEL=OEMDRV:/ks.cfg",
    "<enter>"
  ]
  boot_wait         = "20s"
  boot_key_interval = "100ms"
  http_directory    = "./http"

  communicator    = "ssh"
  cores           = "${var.vm_cpu_cores}"
  cpu_type        = "host"
  scsi_controller = "virtio-scsi-single"
  # Required for Packer to learn the DHCP IP via Proxmox. Agent package is
  # installed in kickstart; probes fail during Anaconda then succeed after reboot.
  qemu_agent = true
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
    bridge = "${var.ludus_nat_interface}"
    model  = "virtio"
  }
  node                   = "${var.proxmox_host}"
  os                     = "${var.os}"
  password               = "${var.proxmox_password}"
  proxmox_url            = "${var.proxmox_url}"
  template_description   = "${local.template_description}"
  username               = "${var.proxmox_username}"
  vm_name                = "${var.vm_name}"
  ssh_password           = "${var.ssh_password}"
  ssh_username           = "${var.ssh_username}"
  ssh_timeout            = "120m"
  ssh_handshake_attempts = 100
  task_timeout           = "60m"
}

build {
  sources = ["source.proxmox-iso.securityonion3"]

  provisioner "ansible" {
    playbook_file    = "ansible/reset-ssh-host-keys.yml"
    use_proxy        = false
    user             = "${var.ssh_username}"
    extra_arguments  = ["--extra-vars", "{ansible_python_interpreter: /usr/bin/python3, ansible_password: ${var.ssh_password}, ansible_sudo_pass: ${var.ssh_password}}"]
    ansible_env_vars = ["ANSIBLE_HOME=${var.ansible_home}", "ANSIBLE_LOCAL_TEMP=${var.ansible_home}/tmp", "ANSIBLE_PERSISTENT_CONTROL_PATH_DIR=${var.ansible_home}/pc", "ANSIBLE_SSH_CONTROL_PATH_DIR=${var.ansible_home}/cp"]
    skip_version_check = true
  }
}

variable "description" {
  type    = string
  default = "Security Onion 2.4 Standalone-ready base (Oracle Linux 9 ISO). so-setup runs at range deploy."
}

variable "icon_path" {
  type    = string
  default = "icon.png"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:185D8CF49CD3BFDD8876B8DDE48343DA90804B0C0EC3EADF0AD90D29C55E72B7"
}

variable "os" {
  type    = string
  default = "l26"
}

variable "iso_url" {
  type    = string
  default = "https://download.securityonion.net/file/securityonion/securityonion-2.4.211-20260407.iso"
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
  default = "securityonion-2.4-x64-template"
}

variable "ssh_password" {
  type    = string
  default = "onion"
}

variable "ssh_username" {
  type    = string
  default = "onion"
}

# Ludus injects these — must be declared, no defaults
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
  template_description = "Security Onion 2.4.211 template built ${legacy_isotime("2006-01-02 03:04:05")} username:password => onion:onion (so-setup not run)"
}

source "proxmox-iso" "securityonion24" {
  # Kickstart on second CD (/dev/sr1). SO ISO is sr0 and embeds ks=cdrom → stock
  # WARNING screen. StackOverflow/CentOS8: use explicit sr1, not LABEL/HTTP alone.
  # https://stackoverflow.com/questions/65099940
  #
  # Debug d940ab: Packer SSH via qemu-guest-agent never works on stock SO ks
  # (agent package missing). communicator=none + shell-local uses DHCP lease IP.
  boot_command = [
    "<tab><wait>",
    " ip=dhcp inst.text inst.cmdline",
    " ks=cdrom:/dev/sr1:/ks.cfg",
    " inst.ks=cdrom:/dev/sr1:/ks.cfg",
    "<enter>"
  ]
  boot_wait         = "12s"
  boot_key_interval = "50ms"

  # Do not block on guest-agent IP discovery (stock path has no agent).
  communicator = "none"

  cores           = "${var.vm_cpu_cores}"
  cpu_type        = "host"
  scsi_controller = "virtio-scsi-single"
  # Enable agent in Proxmox config; guest package comes from our ks (or ansible).
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
  # Second CD → guest /dev/sr1 (must appear in Packer log as Creating CD disk / OEMDRV)
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
  sources = ["source.proxmox-iso.securityonion24"]

  # Host-side provision: DHCP → SSH → ansible (no Packer guest-agent wait).
  provisioner "shell-local" {
    execute_command = ["bash", "-c", "{{.Vars}} {{.Script}}"]
    env = {
      VM_NAME      = "${var.vm_name}"
      SSH_USER     = "${var.ssh_username}"
      SSH_PASS     = "${var.ssh_password}"
      PLAYBOOK     = "ansible/reset-ssh-host-keys.yml"
      ANSIBLE_HOME = "${var.ansible_home}"
      MAX_WAIT_SEC = "7200"
    }
    script = "scripts/packer-provision-via-dhcp.sh"
  }
}

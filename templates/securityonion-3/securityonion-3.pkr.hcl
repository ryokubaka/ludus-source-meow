variable "description" {
  type    = string
  default = "Security Onion 3.2.0 Standalone-ready base (ISO securityonion-3.2.0-20260729). so-setup runs at range deploy."
}

variable "icon_path" {
  type    = string
  default = "icon.png"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:7465163C1D1ADFCDC3935530EAFB312E987C016941ADC11841B214553314D1FF"
}

variable "os" {
  type    = string
  default = "l26"
}

variable "iso_url" {
  type    = string
  default = "https://download.securityonion.net/file/securityonion/securityonion-3.2.0-20260729.iso"
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

# This block has to be in each file or packer won't be able to use the variables
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
####

locals {
  template_description = "Security Onion 3.2.0 template built ${legacy_isotime("2006-01-02 03:04:05")} username:password => onion:onion (so-setup not run)"
}

source "proxmox-iso" "securityonion3" {
  # Same as SO 2.4: cancel so-setup → DHCP + sshd.
  boot_command = [
    "<wait75s>",
    "yes<enter>",
    "<wait3s>",
    "onion<enter>",
    "<wait2s>",
    "onion<enter>",
    "<wait2s>",
    "onion<enter>",
    "<wait10m>",
    "<enter>",
    "<wait3m>",
    "onion<enter>",
    "<wait2s>",
    "onion<enter>",
    "<wait20s>",
    "<esc><wait2s>",
    "<esc><wait2s>",
    "<tab><enter><wait3s>",
    "echo onion | sudo -S pkill -9 -f so-setup || true<enter>",
    "<wait2s>",
    "echo onion | sudo -S sed -i '/so-setup/d;/SecurityOnion\\/setup/d' /home/onion/.bash_profile /home/onion/.bashrc 2>/dev/null || true<enter>",
    "<wait2s>",
    "echo onion | sudo -S bash -c 'systemctl enable --now NetworkManager sshd; nmcli networking on; for n in $(ls /sys/class/net | grep -v lo); do ip link set $n up; nmcli device connect $n || dhclient -v $n || true; done; firewall-cmd --permanent --add-service=ssh; firewall-cmd --reload; true'<enter>",
    "<wait45s>"
  ]
  boot_wait         = "15s"
  boot_key_interval = "100ms"
  communicator      = "none"
  boot              = "order=scsi0;ide0"

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
  task_timeout         = "180m"
}

build {
  sources = ["source.proxmox-iso.securityonion3"]

  provisioner "shell-local" {
    execute_command = ["bash", "-c", "{{.Vars}} {{.Script}}"]
    env = {
      VM_NAME              = "${var.vm_name}"
      SSH_USER             = "${var.ssh_username}"
      SSH_PASS             = "${var.ssh_password}"
      ANSIBLE_HOME         = "${var.ansible_home}"
      PLAYBOOKS            = "ansible/ludus-linux-prereqs.yml ansible/securityonion-prep.yml ansible/reset-machine-id.yml ansible/reset-ssh-host-keys.yml"
      SO_TEMPLATE_MARKER   = "securityonion-3-packer"
      MAX_WAIT_SEC         = "3600"
      EXPECT_MAC           = "BC:24:11:50:03:01"
    }
    script = "scripts/packer-provision-via-dhcp.sh"
  }
}
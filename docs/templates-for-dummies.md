# Ludus templates & Packer for dummies

A template is a **golden disk** you bake once. Ludus then **clones** that disk for every range VM and customizes the clone with Ansible.

```text
ISO  (installer image — throwaway)
  →  Packer recipe  (*.pkr.hcl: keystrokes + scripts)
    →  Proxmox template  (powered-off golden VM)
      →  ludus range deploy  (clone + Ansible; product setup lives here)
```

If you remember nothing else: **Packer bakes the potato. The range deploy seasons it.**

## Words people mix up

| Word | What it actually is |
|---|---|
| **ISO** | The installer image. Packer downloads it, boots it, then ejects it. |
| **Packer file** (`*.pkr.hcl`) | The recipe. Filename **must** contain `.pkr.` or Ludus ignores it. |
| **Ludus template** | The baked VM in Proxmox after `ludus templates build` succeeds. Shown in `ludus templates list`. |
| **Blueprint / range-config** | Which templates to clone and which Ansible roles to run. Not the bake step. |
| **Source** | A git repo of blueprints / templates / Ansible, after `ludus source add`. Packer dirs land under `/opt/ludus/packer/`. |

Ludus convention for a login is `localuser:password` unless the guest already has a well-known default (document the exception).

## What has to be on the golden disk

Ludus talks to clones with Ansible. The bake only needs the guest boring and reachable.

**Linux / macOS**

- **qemu-guest-agent** — Proxmox can ask “what is your IP?”
- **SSH** — Ansible can log in
- **python3** + **sudo** — Ansible can do anything useful
- **DHCP on boot** — first contact before a static IP is assigned
- A known local user with password sudo for all commands

**Windows**

- Qemu guest-agent, WinRM over HTTPS, PowerShell, DHCP, `localuser:password` as a local admin

That is the whole job of Packer. **Do not bake product setup, hostnames, or lab secrets into the template.** Those belong in Ansible roles at range deploy. If you do bake them, every clone shares one identity — and leftover first-boot logs will lie about “already configured.”

Some installer ISOs auto-start a first-boot wizard on the console. Cancel or disable it during the bake so DHCP and SSH/WinRM can come up.

## What a template folder looks like

```text
templates/my-linux-base/
├── my-linux-base.pkr.hcl        # recipe (required Ludus variables + boot + provisioners)
├── icon.png                     # optional catalog icon
├── scripts/                     # Packer or Ansible helpers
├── ansible/                     # playbooks run at bake time (prereqs, uniqueness)
│   ├── linux-prereqs.yml        # guest-agent, SSH, python3, sudo, DHCP
│   ├── reset-machine-id.yml     # clones must not share one machine-id
│   └── reset-ssh-host-keys.yml  # clones must not share host keys
├── http/                        # Linux preseed / kickstart (if the ISO cooperates)
└── Autounattend.xml             # Windows only
```

Ludus injects these variables at build time (storage pool, Proxmox API, NAT bridge, Ansible home). Copy the variable block from any working `.pkr.hcl` — do not invent names. Official list: [Ludus templates](https://docs.ludus.cloud/docs/using-ludus/templates).

The catalog name is the `vm_name` inside the Packer file (`my-linux-base-x64-template`).

## Two ways Packer reaches the guest

**Normal path** (most Debian / Ubuntu / Rocky / Windows templates):

1. Unattended install (preseed, kickstart, or Autounattend)
2. Guest-agent comes up
3. Packer SSHes or WinRMs in (`communicator = "ssh"` / `"winrm"`) and runs Ansible

**No-IP path** (ISO has no guest-agent during install — [packer-plugin-proxmox#91](https://github.com/hashicorp/packer-plugin-proxmox/issues/91)):

Packer cannot learn the VM IP from Proxmox, so it cannot use the normal communicator.

1. Packer types the stock installer (or a kickstart if the ISO honors one).
2. After first boot, kill or cancel any console wizard that steals the TTY.
3. Enable networking + SSH (or WinRM), grab a DHCP lease.
4. `communicator = "none"` — Packer does not try to log in.
5. A **shell-local** script on the Ludus host finds the guest (DHCP pool scan, lease file, or a known MAC) and runs the same Ansible playbooks.
6. The VM is converted to a template.

`qemu_agent = true` still matters on the no-IP path: it creates the virtio channel so guest-agent can start **after** you install the package.

## Build it

```bash
ludus source add https://example.com/your-ludus-source --templates
# or, from a local checkout:
# ludus source add -d ./your-ludus-source --id mysource --templates

ludus templates build -n my-linux-base-x64-template
ludus templates logs -f
ludus templates list
```

Expect ISO download + the installer + Ansible. If `ludus` storage is CIFS/NFS and other VMs are hammering disk, pause busy range VMs for the bake.

After `source add`, the recipe lives at `/opt/ludus/packer/<template-dir>/`.

Some guests map to a non-default Ansible inventory group. If deploys guess the wrong SSH user, add a `group_vars` pin on the Ludus host for that group.

## “The auto-build errored and destroyed the VM”

That is Packer doing its job: a failed provisioner tears down the in-progress VM so you do not keep a half-baked template.

### 1. Permission denied on a `.sh` script

Packer’s `shell-local` default is to exec the script as a program. Git on Windows stores those files as `0644` (not executable). On the Ludus host the script is not `+x`, Packer dies, VM gone.

Prefer `execute_command` that runs `bash {{.Script}}` so a lost execute bit cannot fail the bake. Also mark provision scripts `+x` **in git**:

```bash
git update-index --chmod=+x templates/my-linux-base/scripts/*.sh
```

If you are on an older clone or copied files without mode bits:

```bash
chmod +x /opt/ludus/packer/<template-dir>/scripts/*.sh
```

Then `ludus templates build` again.

### 2. Other common failures

| Symptom | Likely cause |
|---|---|
| No SSH/WinRM in the template DHCP pool | First-boot wizard still owns the TTY, or DHCP never came up. Watch the Proxmox console during the keystroke phase. |
| `sshpass required` | Packer host missing `sshpass` (password SSH from a shell-local script). |
| `ANSIBLE_HOME unset` | Ludus did not inject `var.ansible_home` — template file is missing the required variable block. |
| Storage lock / timeout mid-disk | Contended CIFS/NFS. Pause other VMs. |
| Clone boots, no IP | Guest-agent missing, or the installer left NetworkManager `autoconnect=false`. |
| Deploy thinks setup already finished | First-boot leftovers on the golden disk. Wipe them in a bake-time playbook; rebuild if an old bake is still in use. |

```bash
ludus templates logs -f
```

## Make your own (minimum recipe)

1. Copy a working template directory. Do not start from a blank Packer file.
2. Keep the required Ludus variable block verbatim.
3. Set `vm_name` to `something-x64-template`.
4. Leave the guest stupid: remote access + DHCP + guest-agent. Put product setup in an Ansible role at deploy time.
5. If Packer cannot see the guest IP, you need a communicator workaround (DHCP/lease scan) — do not pretend `communicator = "ssh"` will magically work.
6. Any script Packer runs as a program needs `+x` **in git**, or invoke it with `bash script.sh`.
7. Document the template next to the others in this source.
8. Build it on a real Ludus host before you merge. Unit tests do not replace a bake.

Contributor checklist: [CONTRIBUTING.md](../CONTRIBUTING.md) (Packer Templates). Official knobs (disk/CPU/network performance flags): [Ludus templates](https://docs.ludus.cloud/docs/using-ludus/templates).

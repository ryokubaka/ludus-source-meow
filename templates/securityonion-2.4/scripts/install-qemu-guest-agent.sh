#!/bin/bash
# Install qemu-guest-agent on stock Security Onion (ISO-local /nsm/repo or Oracle OL9 repos).
# Used by ludus-linux-prereqs.yml and test-provision-against-vm.sh.
#
# Env:
#   SO_REPO_PATHS  colon-separated dirs to search before defaults (for unit tests)
#   DRY_RUN=1      print planned actions only (no dnf/rpm changes)
set -uo pipefail

log() { echo "[qemu-ga] $*" >&2; }

so_repo_paths() {
  local IFS=':'
  if [ -n "${SO_REPO_PATHS:-}" ]; then
    echo "$SO_REPO_PATHS"
    return 0
  fi
  echo "/nsm/repo:/nsm/repo/Packages:/run/install/repo/Packages:/mnt/install/repo/Packages"
}

find_local_repo() {
  local dir
  local IFS=':'
  for dir in $(so_repo_paths); do
    [ -d "$dir" ] && { echo "$dir"; return 0; }
  done
  return 1
}

find_rpm() {
  local dir="$1" pkg="$2"
  find "$dir" -maxdepth 1 -name "${pkg}-*.rpm" 2>/dev/null | sort -V | tail -1
}

# Prints RPM paths that would be installed from a local SO repo (liburing + guest-agent).
plan_local_install() {
  local dir="$1"
  local ga liburing
  ga="$(find_rpm "$dir" qemu-guest-agent)"
  [ -n "$ga" ] || return 1
  liburing="$(find_rpm "$dir" liburing)"
  [ -n "$liburing" ] && echo "$liburing"
  echo "$ga"
}

install_from_local_repo() {
  local dir="$1"
  local -a rpms=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && rpms+=("$line")
  done < <(plan_local_install "$dir")
  [ "${#rpms[@]}" -gt 0 ] || return 1
  log "installing from ${dir}: ${rpms[*]}"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN: would dnf install ${rpms[*]}"
    return 0
  fi
  dnf -y install "${rpms[@]}"
}

bootstrap_oracle_repos() {
  local release_rpm=""
  local repo_dir
  repo_dir="$(find_local_repo || true)"
  if [ -n "${repo_dir:-}" ]; then
    release_rpm="$(find_rpm "$repo_dir" oraclelinux-release-el9)"
    [ -z "$release_rpm" ] && release_rpm="$(find "$repo_dir" -maxdepth 1 -name 'oraclelinux-release-*.rpm' 2>/dev/null | head -1 || true)"
  fi
  if [ -z "${release_rpm:-}" ]; then
    log "downloading oraclelinux-release-el9"
    if [ "${DRY_RUN:-0}" = "1" ]; then
      log "DRY_RUN: would download oraclelinux-release-el9.rpm"
      return 0
    fi
    if ! curl -sfL -o /tmp/oraclelinux-release-el9.rpm \
      "https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/getPackage/oraclelinux-release-el9-1.0-15.el9.x86_64.rpm"; then
      return 1
    fi
    release_rpm=/tmp/oraclelinux-release-el9.rpm
  fi
  log "installing ${release_rpm}"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN: would dnf install ${release_rpm} and enable ol9_* repos"
    return 0
  fi
  dnf -y install "$release_rpm"
  for rid in ol9_baseos ol9_appstream ol9_addons ol9_kvm_utils ol9_UEKR8; do
    dnf config-manager --enable "$rid" >/dev/null 2>&1 || true
  done
}

install_qemu_guest_agent() {
  local repo_dir

  if rpm -q qemu-guest-agent >/dev/null 2>&1; then
    log "already installed: $(rpm -q qemu-guest-agent)"
    return 0
  fi

  log "trying configured dnf repos"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN: would try dnf install qemu-guest-agent"
  elif ! dnf -y install qemu-guest-agent 2>/dev/null; then
    if repo_dir="$(find_local_repo || true)" && [ -n "${repo_dir:-}" ]; then
      log "trying SO local repo ${repo_dir}"
      install_from_local_repo "$repo_dir" || log "local repo install failed"
    fi
  fi

  if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN: would bootstrap Oracle repos if still missing"
    return 0
  fi

  if ! rpm -q qemu-guest-agent >/dev/null 2>&1; then
    log "bootstrapping Oracle Linux 9 yum repos"
    if bootstrap_oracle_repos; then
      log "installing qemu-guest-agent from ol9_appstream"
      dnf -y install qemu-guest-agent || true
    fi
  fi

  if ! rpm -q qemu-guest-agent >/dev/null 2>&1; then
    log "FAILED — qemu-guest-agent not installed"
    if repo_dir="$(find_local_repo || true)"; then
      log "local repo contents (liburing/qemu):"
      ls -1 "$repo_dir"/liburing*.rpm "$repo_dir"/qemu-guest-agent*.rpm 2>/dev/null | head -10 >&2 || true
    fi
    dnf repolist enabled 2>&1 | head -20 >&2 || true
    return 1
  fi

  log "installed: $(rpm -q qemu-guest-agent)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  install_qemu_guest_agent
fi

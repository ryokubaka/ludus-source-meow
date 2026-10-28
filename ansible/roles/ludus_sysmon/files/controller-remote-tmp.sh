#!/bin/bash
# First directory this process can create for delegate_to: localhost module files.
# The Ludus systemd unit sets ProtectHome=read-only, so the service user's home
# is not writable. A range user running outside that unit cannot write the
# service-owned /opt/ludus/ansible/tmp (mode 700).
set -u
home=$(getent passwd "$(id -u)" | cut -d: -f6)
for d in /opt/ludus/ansible/tmp "${home}/.goad/ansible-remote" /tmp/.ansible-ludus-so; do
  if mkdir -p "$d" 2>/dev/null && touch "$d/.w" 2>/dev/null; then
    rm -f "$d/.w"
    printf '%s\n' "$d"
    exit 0
  fi
done
echo "No writable controller temp directory" >&2
exit 1

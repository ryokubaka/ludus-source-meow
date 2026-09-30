#!/bin/bash
# Obsolete. Security Onion templates create localuser, and the lab blueprint
# joins the rhel Ansible group, which Ludus already ships. Do not copy files
# into /opt/ludus.
echo "install-ol-group-vars.sh is obsolete. Rebuild the Security Onion template; the SO VM uses ansible_groups: [rhel]." >&2
exit 1

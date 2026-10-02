#!/usr/bin/env bash
#
# pihole-sync - keep this standby Pi-hole identical to the primary, minus DHCP.
#
# Installed by the pihole_replica role and run by pihole-sync.timer. Each run:
#
#   1. exports a Teleporter archive on the primary and pulls it over SSH;
#   2. filters it (pihole-replica-filter): DHCP forced off, the primary's
#      /etc/hosts and query log dropped;
#   3. imports it and restarts FTL - only if the filtered config changed;
#   4. copies the primary's dhcp.leases in place (no restart), so a failover
#      starts from current leases rather than a day-old copy;
#   5. copies the mkcert CA and issued certs, so the standby can issue certs.
#
# If the primary cannot be reached, nothing is imported: a dead primary must
# never be synced over the standby that is about to replace it.
#
# After a failover (playbooks/pihole-failover.yml) this host serves DHCP and
# the flag file below stops the sync; failback removes it.

set -euo pipefail
# shellcheck source=/dev/null
source /etc/default/pihole-sync      # PRIMARY, SSH_USER

STATE=/var/lib/pihole-sync
FLAG="${STATE}/failover-active"
[[ -e "${FLAG}" ]] && { echo "failover active since $(cat "${FLAG}"); not syncing"; exit 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

primary() {
    runuser -u "${SSH_USER}" -- ssh -n -4 -o BatchMode=yes -o ConnectTimeout=15 \
        -o LogLevel=ERROR "${PRIMARY}" "$@"
}

primary 'd=$(mktemp -d) && cd "$d" && sudo pihole-FTL --teleporter >/dev/null && sudo cat pi-hole_*_teleporter_*.zip; rc=$?; sudo rm -rf "$d"; exit $rc' \
    > "${tmp}/primary.zip"
digest="$(/usr/local/sbin/pihole-replica-filter "${tmp}/primary.zip" "${tmp}/standby.zip")"

if [[ "${digest}" != "$(cat "${STATE}/last-digest" 2>/dev/null || true)" ]]; then
    pihole-FTL --teleporter "${tmp}/standby.zip"
    # The filter already guarantees this; check the live result anyway, before
    # FTL restarts with it.
    if [[ "$(pihole-FTL --config dhcp.active)" != false ]]; then
        pihole-FTL --config dhcp.active false
    fi
    systemctl restart pihole-FTL
    # The archive says which blocklists to use, not their contents: fetch them.
    pihole -g >/dev/null
    echo "${digest}" > "${STATE}/last-digest"
    echo "imported new configuration ${digest:0:12} and refreshed blocklists"
fi

primary 'sudo cat /etc/pihole/dhcp.leases' > "${tmp}/dhcp.leases"
install -m 644 -o pihole -g pihole "${tmp}/dhcp.leases" /etc/pihole/dhcp.leases

primary 'tar -C "$HOME" -cf - .local/share/mkcert server-certs issue-cert.sh' \
    | runuser -u "${SSH_USER}" -- tar -C "$(getent passwd "${SSH_USER}" | cut -d: -f6)" -xf -

date -Is > "${STATE}/last-success"

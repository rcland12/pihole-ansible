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
#   5. copies the extra paths in SYNC_PATHS (pihole_sync_paths) - e.g. a CA,
#      so the standby can issue certificates after a failover.
#
# If the primary cannot be reached, nothing is imported: a dead primary must
# never be synced over the standby that is about to replace it.
#
# After a failover (playbooks/pihole-failover.yml) this host serves DHCP and
# the flag file below stops the sync; failback removes it.

set -euo pipefail
SYNC_PATHS=()
# shellcheck source=/dev/null
source /etc/default/pihole-sync      # PRIMARY, SSH_USER, SYNC_PATHS

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

if (( ${#SYNC_PATHS[@]} )); then
    # Into a scratch copy first: a truncated stream must not leave half a CA.
    # A path the primary does not have (yet) is skipped, not an error.
    primary "sudo tar -C / --ignore-failed-read -cf - $(printf '%q ' "${SYNC_PATHS[@]}") 2>/dev/null" > "${tmp}/paths.tar"
    tar -tf "${tmp}/paths.tar" >/dev/null
    tar -C / -xpf "${tmp}/paths.tar"
fi

date -Is > "${STATE}/last-success"

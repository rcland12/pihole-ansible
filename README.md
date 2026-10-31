# rcland12.pihole

An Ansible collection for running **Pi-hole v6 with a warm standby**: when the
Pi-hole that serves your network's DNS *and DHCP* dies, a second one takes
over its address in about a minute, with the same reservations, local DNS
records, blocklists and leases - and no client, router or reservation has to
change.

It does not back anything up for you. It installs, replicates and fails over;
where a primary's configuration comes from when you rebuild it (a Teleporter
export, your own backup) is up to you - see [Rebuilding a primary](#rebuilding-a-primary).

## How it works

```
 clients ──DNS/DHCP──► primary (192.168.10.53)          standby (192.168.10.54)
                       Pi-hole, DHCP on      ──15 min──► Pi-hole, DHCP OFF
                                             Teleporter  unbound, ufw, extra paths
 primary dies:
 clients ──DNS/DHCP──► standby, now ALSO 192.168.10.53, DHCP on
```

- **Standby**: every 15 minutes the standby pulls a Teleporter archive from
  the primary over SSH, filters it - DHCP forced **off**, proven to be the only
  change; the primary's `/etc/hosts` and query log dropped - and imports it
  only when the configuration changed, re-downloading the blocklists (an
  archive lists blocklists, it does not contain them). Leases, and any extra
  paths you list in `pihole_sync_paths` (your CA, say), are copied every run.
  If the primary is unreachable, nothing is imported.
- **Failover**: the standby adds the primary's address *alongside* its own
  (NetworkManager profile + live interface, gratuitous ARP), sets aside the
  reservation that gives the primary's MAC that address, and turns DHCP on.
  It refuses while the primary still answers DNS.
- **Failback**: the standby saves its config from its time in charge, turns
  DHCP off, releases the address and resumes syncing. Then you power the
  primary on.

## Requirements

- Raspberry Pi OS / Debian **12 (bookworm)** or Ubuntu 24.04 on the targets -
  Pi-hole's installer supports Debian 11/12, not 13 yet.
- **NetworkManager** on the standby (the default on Raspberry Pi OS bookworm).
- The primary already runs Pi-hole v6 with DHCP enabled.
- An SSH login with passwordless sudo on both Pis (`ansible_user`).
- ansible-core 2.14+, and on the controller: `community.general`,
  `community.crypto`, `ansible.posix` (pulled in as dependencies).
- For the `tls` role: a CA certificate and its key on the host (an
  intermediate is best; [step-ca](https://smallstep.com/docs/step-ca/) and
  plain openssl CAs both work), given as `pihole_tls_ca_cert` /
  `pihole_tls_ca_key`. Pi-hole's own config points its web server at
  `/etc/pihole/tls/pihole.pem`; without that file the admin UI and API do not
  start at all (DNS still does).

## Install

```
ansible-galaxy collection install git+https://github.com/rcland12/pihole-ansible.git
```

or in a `requirements.yml`:

```yaml
collections:
  - name: https://github.com/rcland12/pihole-ansible.git
    type: git
    version: master
```

## Inventory

```yaml
all:
  vars:
    ansible_user: pi
    pihole_primary: pihole1          # inventory name of the primary (required)
    pihole_domain: home.arpa
    pihole_lan_cidr: 192.168.0.0/16
  children:
    pihole_primary:
      hosts:
        pihole1: { ansible_host: 192.168.10.53 }   # the address clients use for DNS
    pihole_standby:
      hosts:
        pihole2: { ansible_host: 192.168.10.54 }
```

`examples/inventory.yml` has the same thing to copy.

## Use

```
ansible-playbook rcland12.pihole.standby  -i inventory.yml   # set up / update the standby
ansible-playbook rcland12.pihole.failover -i inventory.yml   # primary is dead: take over
ansible-playbook rcland12.pihole.failback -i inventory.yml   # undo; THEN power the primary on
```

**Rehearse** a failover at any time, safely: the standby takes over a spare,
unused address instead, DHCP stays off, and the primary need not be down.

```
ansible-playbook rcland12.pihole.failover -i inventory.yml -e pihole_failover_test_ip=192.168.10.250
dig @192.168.10.250 pi.hole
ansible-playbook rcland12.pihole.failback -i inventory.yml -e pihole_failover_test_ip=192.168.10.250
```

Run failover **from the standby itself** if the primary was also your Ansible
controller.

## Roles

| Role | Does |
|---|---|
| `install` | installs Pi-hole v6 unattended from a Teleporter archive (`pihole_teleporter`): seeds `pihole.toml` first, so a new install never runs with defaults; imports the archive; downloads every blocklist; checks DHCP state, reservations, blocklists and that a local record resolves. DHCP off unless `pihole_keep_dhcp`; a host in group `test` always gets it off |
| `host` | unbound on 127.0.0.1#5335 (point Pi-hole's first upstream at it) and ufw: DNS/DHCP from anywhere, SSH/HTTP/HTTPS/NTP from `pihole_lan_cidr`. Rules go in before the firewall is enabled |
| `tls` | issues `/etc/pihole/tls/pihole.pem` (key, certificate and chain) from your CA for `pihole_tls_names`, reissuing when a name is missing, it expires within `pihole_tls_renew_days`, or it no longer chains to that CA; checks the admin UI answers with a certificate the CA vouches for |
| `replica` | the standby: SSH trust to the primary (host key pinned from the primary itself), install from the primary's live config, the sync timer, a web certificate valid for both hosts' names |
| `failover` | `tasks_from: failover` / `failback` |
| `network` | a fixed address via NetworkManager, reconnecting on the new address |

## Variables

| Variable | Default | |
|---|---|---|
| `pihole_primary` | - (required) | inventory name of the primary |
| `pihole_domain` | `home.arpa` | local domain of the hosts' names |
| `pihole_lan_cidr` | `192.168.0.0/16` | where SSH, the admin UI and NTP are allowed from |
| `pihole_ssh_user` | `ansible_user` | SSH login standby → primary |
| `pihole_sync_paths` | `[]` | extra absolute paths the standby copies from the primary every sync (read with sudo there); a missing one is skipped |
| `pihole_tls_ca_cert`, `pihole_tls_ca_key` | - (required by `tls`) | the CA that signs the web certificate |
| `pihole_tls_ca_password_file` | `""` | password file, if that key is encrypted |
| `pihole_tls_ca_root` | `pihole_tls_ca_cert` | the root clients trust (when the CA is an intermediate) |
| `pihole_tls_names`, `pihole_tls_days`, `pihole_tls_renew_days` | `[pi.hole]`, `365`, `30` | the web certificate |
| `pihole_standby_tls_names` | see `roles/replica/defaults` | the standby's web certificate: its names and the primary's |
| `pihole_sync_interval` | `15min` | standby sync period |
| `pihole_service_ip` | the primary's `ansible_host` | the address taken over |
| `pihole_failover_test_ip` | - | rehearsal address |
| `pihole_failover_force` | `false` | take over although the primary still answers |
| `pihole_unbound` | `true` | install unbound |
| `pihole_ufw_rules` | see `roles/host/defaults` | firewall rules |
| `pihole_net_address`, `pihole_net_gateway` | - (required by `network`) | e.g. `192.168.10.53/24`, `192.168.10.1` |

## Rebuilding a primary

Use `install` with your own archive, then `network` for the fixed address:

```yaml
- hosts: pihole1
  become: true
  roles:
    - rcland12.pihole.host
    - role: rcland12.pihole.install
      vars: { pihole_teleporter: /tmp/teleporter.zip, pihole_keep_dhcp: false }
```

Bring it up with DHCP **off**, fail the standby back, then give the new
primary its address and turn DHCP on (`pihole-FTL --config dhcp.active true`).
Never run two DHCP servers on one network, and never let two hosts hold the
service address.

## Safety rules the roles follow

- DHCP is never on in two places: the standby's copy is forced off and checked;
  failover refuses while the primary answers; failback turns it off before
  releasing the address.
- A dead primary is never synced over the standby.
- A standby whose Pi-hole does not answer DNS does not take the address.
- The firewall is enabled only after the SSH rule exists.
- Rehearsal mode never enables DHCP.

## License

MIT

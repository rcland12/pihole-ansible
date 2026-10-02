#!/usr/bin/env python3
"""pihole-replica-filter - make a Teleporter archive safe to import elsewhere.

    pihole-replica-filter IN.zip OUT.zip               # standby: DHCP forced off
    pihole-replica-filter IN.zip OUT.zip --keep-dhcp   # rebuilding the primary itself

Prints a digest of the configuration it kept, so the caller can skip the
import (and the FTL restart) when nothing changed.

A Teleporter archive is the primary's whole state, and three parts of it must
not land on the standby:

  * dhcp.active = true. Two DHCP servers on one LAN hand out conflicting
    leases. The standby is forced to false here, and the result is re-parsed
    and compared against the original so that key is provably the only change.
  * etc/hosts. The primary's copy names the primary ("127.0.1.1 <primary>"); importing it would
    rename the standby in its own hosts file.
  * etc/pihole/pihole-FTL.db. The query log: large, changes every second, and
    meaningless on another machine.

dhcp.leases is dropped too; the sync script copies it separately every run,
without a restart, so a failover starts from current leases.
"""
import hashlib
import re
import sys
import tomllib
import zipfile

TOML = "etc/pihole/pihole.toml"
DROP = {"etc/hosts", "etc/pihole/pihole-FTL.db", "etc/pihole/dhcp.leases"}


def disable_dhcp(text: str) -> str:
    # The first `active = ...` inside [dhcp] itself - not a [dhcp.*] subsection.
    m = re.search(r"(?m)^\[dhcp\]\n(?:(?!^\[).*\n)*?^(\s*)active = (true|false)", text)
    if not m:
        sys.exit("could not find dhcp.active in pihole.toml")
    start, end = m.span(2)
    return text[:start] + "false" + text[end:]


def strip_volatile(d):
    d = dict(d)
    d["dhcp"] = {k: v for k, v in d["dhcp"].items() if k != "active"}
    return d


def main(src: str, dst: str, keep_dhcp: bool = False) -> None:
    digest = hashlib.sha256()
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        names = zin.namelist()
        if TOML not in names:
            sys.exit(f"{src}: no {TOML}; not a Teleporter archive")
        for info in zin.infolist():
            if info.filename in DROP:
                continue
            data = zin.read(info)
            if info.filename == TOML:
                original = data.decode()
                replica = original if keep_dhcp else disable_dhcp(original)
                a, b = tomllib.loads(original), tomllib.loads(replica)
                if not keep_dhcp and (b["dhcp"]["active"] is not False or strip_volatile(a) != strip_volatile(b)):
                    sys.exit("refusing: disabling DHCP changed more than dhcp.active")
                if len(b["dhcp"].get("hosts", [])) == 0:
                    sys.exit("refusing: archive has no DHCP reservations; primary looks wrong")
                data = replica.encode()
                # "# Last updated on ..." changes on every save; leave it out of the digest.
                digest.update(re.sub(rb"(?m)^#.*\n", b"", data))
            else:
                digest.update(data)
            zout.writestr(info, data)
    print(digest.hexdigest())


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--keep-dhcp"]
    if len(args) != 2:
        sys.exit(__doc__)
    main(args[0], args[1], keep_dhcp="--keep-dhcp" in sys.argv[1:])

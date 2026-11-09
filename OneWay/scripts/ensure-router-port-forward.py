#!/usr/bin/env python3
"""Keep OneWay's local router port forwards alive.

The CGM4981COM gateway accepts UPnP port mappings but clamps "permanent"
leases to 86400 seconds. This script renews the mappings for TCP 80 and 443
to the Mac's active LAN address, so api.oneway.is stays reachable.
"""

from __future__ import annotations

import re
import socket
import subprocess
import sys
import urllib.error
import urllib.request


ROUTER_CONTROL_URL = "http://192.168.0.1:49152/upnp/control/WANIPConnection0"
SERVICE = "urn:schemas-upnp-org:service:WANIPConnection:1"
PORTS = (80, 443)
DESCRIPTION_PREFIX = "OneWay API"


def active_lan_ip() -> str:
    """Return the IPv4 address on the default route interface."""
    route = subprocess.check_output(["route", "-n", "get", "default"], text=True)
    match = re.search(r"interface:\s*(\S+)", route)
    if not match:
        raise RuntimeError("could not find default route interface")

    iface = match.group(1)
    ifconfig = subprocess.check_output(["ifconfig", iface], text=True)
    match = re.search(r"\binet\s+(\d+\.\d+\.\d+\.\d+)\b", ifconfig)
    if not match:
        raise RuntimeError(f"could not find IPv4 address for {iface}")

    return match.group(1)


def soap(action: str, inner: str) -> str:
    body = f"""<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:{action} xmlns:u="{SERVICE}">
{inner}
    </u:{action}>
  </s:Body>
</s:Envelope>""".encode()

    request = urllib.request.Request(
        ROUTER_CONTROL_URL,
        data=body,
        method="POST",
        headers={
            "Content-Type": 'text/xml; charset="utf-8"',
            "SOAPAction": f'"{SERVICE}#{action}"',
        },
    )
    with urllib.request.urlopen(request, timeout=8) as response:
        return response.read().decode("utf-8", "ignore")


def delete_mapping(port: int) -> None:
    try:
        soap(
            "DeletePortMapping",
            f"""
      <NewRemoteHost></NewRemoteHost>
      <NewExternalPort>{port}</NewExternalPort>
      <NewProtocol>TCP</NewProtocol>""",
        )
    except urllib.error.HTTPError as error:
        # 714 means no such entry. That is fine before the first install.
        text = error.read().decode("utf-8", "ignore")
        if "714" not in text and "NoSuchEntryInArray" not in text:
            raise


def add_mapping(port: int, local_ip: str) -> None:
    soap(
        "AddPortMapping",
        f"""
      <NewRemoteHost></NewRemoteHost>
      <NewExternalPort>{port}</NewExternalPort>
      <NewProtocol>TCP</NewProtocol>
      <NewInternalPort>{port}</NewInternalPort>
      <NewInternalClient>{local_ip}</NewInternalClient>
      <NewEnabled>1</NewEnabled>
      <NewPortMappingDescription>{DESCRIPTION_PREFIX} {port}</NewPortMappingDescription>
      <NewLeaseDuration>0</NewLeaseDuration>""",
    )


def get_mapping(port: int) -> str:
    return soap(
        "GetSpecificPortMappingEntry",
        f"""
      <NewRemoteHost></NewRemoteHost>
      <NewExternalPort>{port}</NewExternalPort>
      <NewProtocol>TCP</NewProtocol>""",
    )


def main() -> int:
    local_ip = active_lan_ip()
    socket.inet_aton(local_ip)

    for port in PORTS:
        delete_mapping(port)
        add_mapping(port, local_ip)
        entry = get_mapping(port)
        if f"<NewInternalClient>{local_ip}</NewInternalClient>" not in entry:
            raise RuntimeError(f"port {port} did not map to {local_ip}")
        if f"<NewInternalPort>{port}</NewInternalPort>" not in entry:
            raise RuntimeError(f"port {port} did not map to internal port {port}")
        print(f"mapped TCP {port} -> {local_ip}:{port}")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)

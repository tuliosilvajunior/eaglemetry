#!/usr/bin/env python3
"""Minimal BLE notify probe for the [BLE-DIAG] diagnostic car build.

SCAN -> CONNECT -> SUBSCRIBE(0xCB02) -> count notifications for --timeout s.

The diagnostic car build notifies every connected client from t=0 without
requiring challenge auth or a CCCD write, so this probe skips the auth flow
entirely (reads and writes never reach the GATT server app on this stack).

Exit code 0 only when at least --min-count notifications arrive.

Verdict matrix (combine with car-side `adb logcat | grep BLE-DIAG`):
  notifications arrive            -> notify path works end-to-end; one-way
                                     channel is viable, redesign around it.
  accepted=true, nothing arrives  -> framework accepts but drops on air.
  accepted=false or exceptions    -> bridge rejects notify; invert roles.

Requires: python3 -m pip install bleak
"""

import argparse
import asyncio
import struct
import sys
import time

from bleak import BleakClient, BleakScanner

SERVICE_UUID = "0000cb01-0000-1000-8000-00805f9b34fb"
CHAR_TELEMETRY = "0000cb02-0000-1000-8000-00805f9b34fb"


def stage(name, detail=""):
    print(f"[{time.strftime('%H:%M:%S')}] {name:<10} {detail}", flush=True)


def fail(name, detail):
    stage("FAIL", f"{name}: {detail}")
    sys.exit(2)


def decode_snapshot(data: bytes) -> dict:
    if len(data) < 12:
        raise ValueError(f"payload too short: {len(data)}")
    magic, version, mask, utc = struct.unpack_from(">BBHq", data, 0)
    if magic != 0xCB:
        raise ValueError(f"bad magic 0x{magic:02x}")
    if version != 1:
        raise ValueError(f"bad version {version}")
    return {"utc_millis": utc, "mask": mask, "bytes": len(data)}


async def find_car(scan_timeout: float, name_hint: str):
    stage("SCAN", f"looking for service {SERVICE_UUID} (timeout {scan_timeout}s)")
    found = await BleakScanner.discover(timeout=scan_timeout, return_adv=True)
    by_service = []
    by_name = []
    for device, adv in found.values():
        uuids = [u.lower() for u in (adv.service_uuids or [])]
        label = (adv.local_name or device.name or "").strip()
        if SERVICE_UUID in uuids:
            by_service.append((device, label, adv.rssi))
        elif name_hint and name_hint.lower() in label.lower():
            by_name.append((device, label, adv.rssi))
    stage("SCAN", f"{len(found)} devices seen, {len(by_service)} advertise the Capy service")
    for device, label, rssi in by_service:
        stage("SCAN", f"  service match: {device.address} name={label!r} rssi={rssi}")
    for device, label, rssi in by_name:
        stage("SCAN", f"  name match:    {device.address} name={label!r} rssi={rssi}")
    if by_service:
        return by_service[0][0]
    if by_name:
        return by_name[0][0]
    return None


async def run(args) -> None:
    if args.address:
        stage("SCAN", f"skipping scan, connecting straight to {args.address}")
        device = args.address
    else:
        device = await find_car(args.scan_timeout, args.name)
        if device is None:
            fail("SCAN", "no device advertised the Capy service or matched the name hint")

    received = []

    def on_notify(_handle, data: bytearray):
        try:
            snap = decode_snapshot(bytes(data))
        except Exception as exc:
            stage("NOTIFY", f"undecodable {len(data)} bytes: {exc}")
            return
        received.append(snap)
        stage("NOTIFY", f"#{len(received)} {snap}")

    stage("CONNECT", f"{device if isinstance(device, str) else device.address}")
    async with BleakClient(device, timeout=args.connect_timeout) as client:
        connected_at = time.monotonic()
        stage("CONNECT", f"connected={client.is_connected} mtu={client.mtu_size}")

        for svc in client.services:
            if svc.uuid.lower() == SERVICE_UUID:
                for ch in svc.characteristics:
                    stage("DISCOVER", f"char {ch.uuid} props={ch.properties}")

        stage("SUBSCRIBE", f"enabling notifications on {CHAR_TELEMETRY}")
        await client.start_notify(CHAR_TELEMETRY, on_notify)
        stage(
            "SUBSCRIBE",
            f"CCCD written {time.monotonic() - connected_at:.2f}s after connect",
        )

        stage("LISTEN", f"collecting for {args.timeout}s")
        await asyncio.sleep(args.timeout)
        await client.stop_notify(CHAR_TELEMETRY)

    if len(received) < args.min_count:
        fail("NOTIFY", f"got {len(received)} notifications, wanted {args.min_count} in {args.timeout}s")
    rate = len(received) / args.timeout
    stage("PASS", f"{len(received)} notifications decoded ({rate:.1f}/s)")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scan-timeout", type=float, default=8.0)
    parser.add_argument("--connect-timeout", type=float, default=15.0)
    parser.add_argument("--timeout", type=float, default=20.0, help="listen window in seconds")
    parser.add_argument("--min-count", type=int, default=1, help="notifications needed to exit 0")
    parser.add_argument("--address", default=None, help="connect straight to this peripheral id, skip scanning")
    parser.add_argument("--name", default="ECARX", help="fallback local-name hint")
    args = parser.parse_args()
    try:
        asyncio.run(run(args))
    except SystemExit:
        raise
    except Exception as exc:
        fail("EXCEPTION", f"{type(exc).__name__}: {exc}")


if __name__ == "__main__":
    main()

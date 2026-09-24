# 7. One-Way Encrypted BLE Live Stream

## Context and Decision

The companion app needs live vehicle telemetry while the phone is near the car, without the Wi-Fi sync session. BLE is the only always-available radio, but the head unit vendor Bluetooth stack accepts connections and serves GATT discovery while never delivering ATT requests to the app (measured on IHU629G, issue #101). The car therefore cannot read a CCCD write, cannot answer a challenge, and cannot receive any phone-initiated command.

We decided to make the Live Stream a one-way car-to-phone push with the protection inside the payload:

1. **Topology**: the car advertises service `0xCB01` and notifies characteristic `0xCB02`. There is no auth characteristic and the phone never writes to the car.
2. **Fan-out**: the car emits one frame variant per paired companion secret. A client keeps only the frames that decrypt under its own key.
3. **Payload**: AES-256-GCM under the Wi-Fi pairing shared secret. Frame layout is version byte, uint64 big-endian counter, then ciphertext with a 128-bit tag. The nonce is four zero bytes followed by the counter.
4. **Replay**: the counter increases strictly. A client rejects any frame whose counter does not advance.
5. **Gating**: the radio opens only when the Beta switch is on and a pairing exists. The pairing seam stays the single owner of the shared secret.

## Consequences

- The Live Stream carries no Session, Interval, or Sample. It is a transient snapshot push and is never a source for the Telemetry Store or for Dual-Channel Sync.
- Pairing remains a Wi-Fi operation. BLE reuses the shared secret it produced and adds no pairing path of its own.
- Access control cannot depend on GATT permissions or bonding, because the vendor stack never reports them. Confidentiality comes only from the payload cipher.
- Unpairing a phone must rebuild the cipher set, because a stale key would keep decrypting the fan-out.
- Any future car-to-phone command requires a different transport. The BLE seam is one-way by hardware, not by preference.

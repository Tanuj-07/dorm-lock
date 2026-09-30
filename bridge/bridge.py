#!/usr/bin/env python3
# mac -> esp32 bridge. long polls the worker, sends cmds to the esp32 over BLE,
# then confirms back to the worker so the phone gets the real result.
#
#   python3 bridge.py              normal
#   python3 bridge.py --fake-ble   no esp32, just pretends it worked. for testing the worker side
#
# config is in config.json next to this file (gitignored). see config.example.json
# needs: pip install bleak   (not needed for --fake-ble)

import asyncio
import hashlib
import hmac
import json
import logging
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
CFG = json.loads((HERE / "config.json").read_text())
BASE = CFG["base"].rstrip("/")
SECRET = CFG["secret"]
BLE_NAME = CFG.get("ble_name", "dorm-lock")
BLE_KEY = bytes.fromhex(CFG["ble_key"])
POLL_WAIT_MS = int(CFG.get("poll_wait_ms", 25000))
FAKE = "--fake-ble" in sys.argv

# has to match the esp32 firmware
NONCE_CH = "7a1c0002-5e2b-4d8f-9c3a-1b6e2f4d8a90"
CMD_CH = "7a1c0003-5e2b-4d8f-9c3a-1b6e2f4d8a90"
STATUS_CH = "7a1c0004-5e2b-4d8f-9c3a-1b6e2f4d8a90"

ACK_TIMEOUT_S = 6  # servo travel is ~0.8s so this is plenty

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", stream=sys.stdout)
log = logging.getLogger("bridge")


def http(method, path, body=None, timeout=40):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path,
        data=data,
        method=method,
        # custom UA bc cloudflare sometimes 403s the default python one
        headers={"X-Lock-Secret": SECRET, "Content-Type": "application/json", "User-Agent": "dorm-lock-bridge"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, None
    except Exception as e:  # timeouts, dns, wifi blips
        log.warning("http %s %s failed: %s", method, path, e)
        return 0, None


class Lock:
    def __init__(self):
        self.client = None
        self.acks = asyncio.Queue()

    def connected(self):
        return FAKE or (self.client is not None and self.client.is_connected)

    async def connect(self):
        if FAKE:
            return
        from bleak import BleakClient, BleakScanner

        while True:
            log.info("scanning for %s ...", BLE_NAME)
            try:
                dev = await BleakScanner.find_device_by_name(BLE_NAME, timeout=10)
            except Exception as e:  # bluetooth off, not authorized yet, or not ready at boot
                log.warning("ble scan failed: %s", e)
                await asyncio.sleep(5)
                continue
            if dev is None:
                await asyncio.sleep(3)
                continue
            client = BleakClient(dev, disconnected_callback=lambda _c: log.warning("ble disconnected"))
            try:
                await client.connect(timeout=15)
                await client.start_notify(STATUS_CH, self._on_status)
                self.client = client
                log.info("ble connected (%s)", dev.address)
                return
            except Exception as e:
                log.warning("ble connect failed: %s", e)
                try:
                    await client.disconnect()
                except Exception:
                    pass
                await asyncio.sleep(3)

    def _on_status(self, _ch, data):
        self.acks.put_nowait(bytes(data).decode(errors="replace"))

    async def send(self, cmd_id, target):
        """returns (ok, state, detail)"""
        if FAKE:
            await asyncio.sleep(0.3)
            return True, target, None

        while not self.acks.empty():  # toss anything stale
            self.acks.get_nowait()

        # sign "U|id" with the nonce the esp32 is holding right now.
        # it burns the nonce after every cmd so a sniffed one cant be replayed
        nonce = bytes(await self.client.read_gatt_char(NONCE_CH))
        msg = ("U" if target == "unlocked" else "L") + "|" + str(cmd_id)
        sig = hmac.new(BLE_KEY, nonce + msg.encode(), hashlib.sha256).hexdigest()
        await self.client.write_gatt_char(CMD_CH, (msg + "|" + sig).encode(), response=True)

        deadline = time.monotonic() + ACK_TIMEOUT_S
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return False, None, "no ack from esp32"
            try:
                ack = await asyncio.wait_for(self.acks.get(), left)
            except asyncio.TimeoutError:
                return False, None, "no ack from esp32"
            parts = ack.split("|")  # ok|id|state  or  err|id|reason
            if len(parts) >= 3 and parts[1] == str(cmd_id):
                if parts[0] == "ok":
                    return True, parts[2], None
                return False, None, "esp32: " + parts[2]


async def main():
    lock = Lock()
    log.info("bridge starting%s -> %s", " (FAKE BLE)" if FAKE else "", BASE)

    # start after whatever the worker already confirmed so we dont replay old cmds
    while True:
        status, st = await asyncio.to_thread(http, "GET", "/state", None, 20)
        if status == 200:
            break
        log.warning("/state returned %s, retrying", status)
        await asyncio.sleep(5)
    last_id = st["lastConfirmedId"]
    log.info("worker says door=%s lastConfirmedId=%s", st["state"], last_id)

    while True:
        # only take cmds while the esp32 is actually reachable. if its not, the
        # cmd stays at the worker and the phone gets an honest timeout
        if not lock.connected():
            lock.client = None
            await lock.connect()
            continue

        status, body = await asyncio.to_thread(http, "GET", f"/poll?after={last_id}&wait={POLL_WAIT_MS}")
        if status == 204:
            continue
        if status != 200:
            log.warning("poll failed (%s), backing off", status)
            await asyncio.sleep(3)
            continue

        cid, target = body["commandId"], body["target"]
        log.info("cmd #%s -> %s", cid, target)
        try:
            ok, state, detail = await lock.send(cid, target)
        except Exception as e:
            ok, state, detail = False, None, f"ble error: {e}"

        payload = {"commandId": cid, "ok": ok}
        if state:
            payload["state"] = state
        if detail:
            payload["detail"] = detail[:200]

        for attempt in range(5):  # repeats are fine on the worker side
            s, r = await asyncio.to_thread(http, "POST", "/confirm", payload, 15)
            if s == 200:
                log.info("confirmed #%s ok=%s -> %s", cid, ok, (r or {}).get("status"))
                break
            log.warning("confirm attempt %d failed (%s)", attempt + 1, s)
            await asyncio.sleep(attempt + 1)

        last_id = cid


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

"""Reuse the existing parser suite's synthetic, semantically full-size fixture."""

import sys
from pathlib import Path


def fleet_bytes() -> bytes:
    root = Path(__file__).resolve().parents[2]
    sys.path.insert(0, str(root / "firmware/pico"))
    sys.path.insert(0, str(root / "firmware/pico/tests"))
    from test_fleet_config import device, encoded, fleet

    devices = {f"device-{index}": device(f"monitor-{index}") for index in range(16)}
    value = fleet(devices)
    content = encoded(value)
    for entry in devices.values():
        for key in ("config_read_credential", "gist_write_credential"):
            increase = min(2048 - len(entry[key]), 65536 - len(content))
            entry[key] += "x" * increase
            content = encoded(value)
            if len(content) == 65536:
                return content
    raise RuntimeError("synthetic fleet did not reach the required byte envelope")

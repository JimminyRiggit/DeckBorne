#!/usr/bin/env python3
"""Report the Vulkan GPUs shadPS4 can see, and which one it will choose.

This is a REPORTER, not a chooser. shadPS4 v0.16.0 already picks the best device itself
when Vulkan.gpu_id is -1, using a better rule than anything we could apply from outside
(it reads each device's real Vulkan properties). See DECKBORNE_TARGET / VULKAN_GPU_ID_*
in config/deckborne.env for why DeckBorne does not override it by default.

    --human   one block for the run log (default)
    --json    machine-readable, for the UI
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys

VK_API_1_3 = (1 << 22) | (3 << 12)

_GPU_HEAD = re.compile(r"^GPU(\d+):")
_FIELD = re.compile(r"^\s*(\w+)\s*=\s*(.+?)\s*$")


def _run(cmd: list[str], timeout: int = 20) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def _api_tuple(s: str) -> tuple[int, ...]:
    try:
        return tuple(int(p) for p in s.split("."))
    except ValueError:
        return (0,)


def _api_packed(s: str) -> int:
    p = _api_tuple(s)
    major = p[0] if len(p) > 0 else 0
    minor = p[1] if len(p) > 1 else 0
    return (major << 22) | (minor << 12)


def from_vulkaninfo() -> list[dict]:
    """Devices in vkEnumeratePhysicalDevices order — the order gpu_id indexes into."""
    if not shutil.which("vulkaninfo"):
        return []
    out = _run(["vulkaninfo", "--summary"])
    if not out:
        return []
    devices: list[dict] = []
    cur: dict | None = None
    for line in out.splitlines():
        head = _GPU_HEAD.match(line.strip())
        if head:
            cur = {"index": int(head.group(1)), "name": "", "type": "", "api": ""}
            devices.append(cur)
            continue
        if cur is None:
            continue
        f = _FIELD.match(line)
        if not f:
            continue
        key, val = f.group(1), f.group(2)
        if key == "deviceName":
            cur["name"] = val
        elif key == "deviceType":
            cur["type"] = val.replace("PHYSICAL_DEVICE_TYPE_", "")
        elif key == "apiVersion":
            cur["api"] = val.split()[0]
    return [d for d in devices if d["name"]]


def from_lspci() -> list[dict]:
    """Rough fallback when vulkaninfo is absent. NOT Vulkan order — reported as such."""
    out = _run(["lspci"])
    names = [ln.split(": ", 1)[1] for ln in out.splitlines()
             if re.search(r"(VGA compatible controller|3D controller|Display controller)", ln)
             and ": " in ln]
    return [{"index": -1, "name": n, "type": "", "api": ""} for n in names]


def auto_choice(devices: list[dict]) -> tuple[int, str]:
    """Replicate shadPS4's gpu_id<0 sort far enough to name the winner, or say why not.

    Its rule (vk_instance.cpp, v0.16.0), in order: supports Vulkan 1.3, is DISCRETE_GPU,
    then largest device-local memory heap. `vulkaninfo --summary` does not report heap
    sizes, so a tie at the top is reported as undecidable rather than guessed at.
    """
    if not devices or devices[0]["index"] < 0:
        return -1, "cannot tell without vulkaninfo"
    if len(devices) == 1:
        return devices[0]["index"], "only one device"

    ranked = sorted(
        devices,
        key=lambda d: (0 if _api_packed(d["api"]) >= VK_API_1_3 else 1,
                       0 if d["type"] == "DISCRETE_GPU" else 1),
    )
    best = ranked[0]
    key = (0 if _api_packed(best["api"]) >= VK_API_1_3 else 1,
           0 if best["type"] == "DISCRETE_GPU" else 1)
    tied = [d for d in ranked
            if (0 if _api_packed(d["api"]) >= VK_API_1_3 else 1,
                0 if d["type"] == "DISCRETE_GPU" else 1) == key]
    if len(tied) > 1:
        return -1, f"{len(tied)} equally-ranked devices — shadPS4 breaks the tie on VRAM size"
    return best["index"], "highest-ranked by Vulkan 1.3 support, then discrete"


def report() -> dict:
    devices = from_vulkaninfo()
    source = "vulkaninfo"
    if not devices:
        devices = from_lspci()
        source = "lspci" if devices else "none"
    idx, why = auto_choice(devices)
    return {"source": source, "devices": devices, "auto_index": idx, "auto_reason": why}


def human(rep: dict) -> str:
    lines = []
    if rep["source"] == "none":
        lines.append("GPUs: could not enumerate (no vulkaninfo, no lspci).")
        return "\n".join(lines)
    if rep["source"] == "lspci":
        lines.append("GPUs (from lspci — NOT Vulkan device order, indices unknown):")
        for d in rep["devices"]:
            lines.append(f"    {d['name']}")
        lines.append("  Install vulkan-tools for an accurate report.")
        return "\n".join(lines)

    lines.append(f"GPUs visible to Vulkan ({len(rep['devices'])}):")
    for d in rep["devices"]:
        mark = " <- shadPS4 will use this" if d["index"] == rep["auto_index"] else ""
        bits = " ".join(x for x in (d["type"], f"Vulkan {d['api']}" if d["api"] else "") if x)
        lines.append(f"    [{d['index']}] {d['name']}  ({bits}){mark}")
    if rep["auto_index"] < 0:
        lines.append(f"  Auto-select: {rep['auto_reason']}.")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    rep = report()
    if "--json" in argv:
        json.dump(rep, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print(human(rep))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

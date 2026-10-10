#!/usr/bin/env python3
"""Keep Spotify's Bonjour declarations when adding the mod's service types."""

import plistlib
import sys


with open(sys.argv[1], "rb") as source, open(sys.argv[2], "rb") as additions:
    original = plistlib.load(source)
    overlay = plistlib.load(additions)

services = original.get("NSBonjourServices", [])
if not isinstance(services, list):
    raise ValueError("Spotify's NSBonjourServices is not an array")
overlay["NSBonjourServices"] = list(dict.fromkeys(services + overlay["NSBonjourServices"]))

orientations = overlay.get("UISupportedInterfaceOrientations", [])
if not isinstance(orientations, list):
    raise ValueError("The overlay's UISupportedInterfaceOrientations is not an array")
for key in ("UISupportedInterfaceOrientations~iphone", "UISupportedInterfaceOrientations~ipad"):
    existing = original.get(key)
    if existing is None:
        continue
    if not isinstance(existing, list):
        raise ValueError(f"Spotify's {key} is not an array")
    overlay[key] = list(dict.fromkeys(existing + orientations))

if not original.get("NSLocalNetworkUsageDescription"):
    overlay["NSLocalNetworkUsageDescription"] = "Find nearby speakers and devices for Spotify Connect and Cast."

with open(sys.argv[3], "wb") as output:
    plistlib.dump(overlay, output)

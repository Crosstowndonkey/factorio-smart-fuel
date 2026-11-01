#!/usr/bin/env python3
"""Publishes Smart Fuel on the Factorio mod portal, or uploads a new release if it's already there.

Reads the API key from ~/.config/factorio/modportal-api-key (never pass it on the command line).
The key needs the usages "ModPortal: Publish Mods", "ModPortal: Upload Mods" and "ModPortal: Edit Mods"
(factorio.com/profile > API keys).

Usage: tools/publish.py [--first]   (--first = brand-new mod: publish, then set details and gallery)
Runs tools/package.sh first, so the zip is always fresh.
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = "smart-fuel"
KEY_FILE = os.path.expanduser("~/.config/factorio/modportal-api-key")
API = "https://mods.factorio.com/api/v2/mods"
SOURCE = "https://github.com/Crosstowndonkey/factorio-smart-fuel"


def key():
    with open(KEY_FILE) as f:
        return f.read().strip()


def curl(url, fields, auth=True):
    """POST multipart form fields with curl (values starting with @ are files). Returns parsed JSON."""
    args = ["curl", "-sS", "-X", "POST", url]
    if auth:
        # the key goes to curl through stdin, never onto the command line
        args += ["-H", "@-"]
    for name, value in fields:
        args += ["-F", f"{name}={value}"]
    header = f"Authorization: Bearer {key()}\n" if auth else ""
    out = subprocess.run(args, input=header, capture_output=True, text=True, check=True).stdout
    try:
        result = json.loads(out)
    except json.JSONDecodeError:
        sys.exit(f"Unexpected answer from {url}: {out[:500]}")
    if result.get("error"):
        sys.exit(f"{url}: {result['error']} - {result.get('message')}")
    return result


def main():
    first = "--first" in sys.argv
    zip_path = subprocess.run([os.path.join(ROOT, "tools", "package.sh")], capture_output=True, text=True,
                              check=True).stdout.strip()
    print("Package:", zip_path)

    if first:
        upload_url = curl(f"{API}/init_publish", [("mod", MOD)])["upload_url"]
        result = curl(upload_url, [("file", "@" + zip_path), ("description", "<" + os.path.join(ROOT, "docs", "portal-description.md")),
                                   ("category", "utilities"), ("license", "default_mit"), ("source_url", SOURCE)], auth=False)
        print("Published:", result.get("url"))
        details = curl(f"{API}/edit_details", [("mod", MOD), ("tags", "logistic-network"), ("tags", "trains"),
                                               ("homepage", SOURCE)])
        print("Details:", details.get("url"))
        image_url = curl(f"{API}/images/add", [("mod", MOD)])["upload_url"]
        image = curl(image_url, [("image", "@" + os.path.join(ROOT, "docs", "screenshot.png"))], auth=False)
        print("Image:", image.get("url"))
        curl(f"{API}/images/edit", [("mod", MOD), ("images", image["id"])])
        print("Gallery set.")
    else:
        upload_url = curl(f"{API}/releases/init_upload", [("mod", MOD)])["upload_url"]
        result = curl(upload_url, [("file", "@" + zip_path)], auth=False)
        print("Release uploaded:", result)
    print(f"https://mods.factorio.com/mod/{MOD}")


if __name__ == "__main__":
    main()

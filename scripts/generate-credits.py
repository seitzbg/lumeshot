#!/usr/bin/env python3
"""Refresh bundled acknowledgments after `swift package resolve`. No network required."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
names = {
    "bigint": "BigInt", "citadel": "Citadel", "swift-asn1": "Swift ASN.1",
    "swift-atomics": "Swift Atomics", "swift-collections": "Swift Collections",
    "swift-crypto": "Swift Crypto", "swift-log": "Swift Logging",
    "swift-nio": "SwiftNIO", "swift-nio-ssh": "SwiftNIO SSH (Wellz26 fork)",
    "swift-system": "Swift System",
}
checkouts = {p.name.lower(): p for p in (root / ".build/checkouts").iterdir()}
credits = []
for pin in json.loads((root / "Package.resolved").read_text())["pins"]:
    identity = pin["identity"]
    checkout = checkouts[identity]
    licenses = sorted(p for p in checkout.glob("LICENSE*") if p.is_file())
    if not licenses:
        raise RuntimeError(f"Missing license for {identity}")
    license_text = "\n\n".join(p.read_text() for p in licenses)
    notices = sorted(p for p in checkout.glob("NOTICE*") if p.is_file())
    text = license_text + "\n\n" + "\n\n".join(p.read_text() for p in notices)
    # Preserve licenses carried in vendored source headers as well as root notices.
    if identity == "citadel":
        for source in sorted((checkout / "Sources/CCitadelBcrypt").glob("*.[ch]")):
            for comment in re.findall(r"/\*.*?\*/", source.read_text(), re.DOTALL):
                if "Copyright" in comment and ("Redistribution" in comment or "Permission to use" in comment):
                    text += f"\n\n{source.name}\n{comment}"
    if identity == "swift-nio":
        for source in [checkout / "Sources/CNIOSHA1/c_nio_sha1.c"]:
            for comment in re.findall(r"/\*.*?\*/", source.read_text(), re.DOTALL):
                if "Copyright" in comment and "Redistribution" in comment:
                    text += f"\n\n{source.name}\n{comment}"
    license_name = "MIT" if identity in ("bigint", "citadel") else "Apache 2.0"
    if "Runtime Library Exception" in license_text:
        license_name += " with Swift exception"
    credits.append(dict(id=identity, name=names.get(identity, identity),
                        version=pin["state"]["version"],
                        url=pin["location"].removesuffix(".git"),
                        license=license_name, notice=text.strip()))

credits.append(dict(id="libcurl", name="libcurl", version="Provided by macOS",
                    url="https://curl.se/libcurl/", license="curl license",
                    notice=(root / "scripts/licenses/curl.txt").read_text().strip()))
credits.append(dict(id="sqlite", name="SQLite", version="Provided by macOS",
                    url="https://www.sqlite.org/", license="Public domain",
                    notice="SQLite is dedicated to the public domain by its authors.\n\n"
                           "Lumeshot uses SQLite for capture history.\n\n"
                           "https://www.sqlite.org/copyright.html"))
credits.append(dict(id="boringssl", name="BoringSSL", version="Included with Swift Crypto",
                    url="https://boringssl.googlesource.com/boringssl/",
                    license="Apache 2.0 and support-code notices",
                    notice=(root / "scripts/licenses/boringssl.txt").read_text().strip()))
output = root / "Sources/LumeshotApp/Resources/OpenSourceCredits.json"
output.write_text(json.dumps(sorted(credits, key=lambda c: c["name"].lower()),
                            indent=2, ensure_ascii=False) + "\n")
print(f"Wrote {len(credits)} credits to {output.relative_to(root)}")

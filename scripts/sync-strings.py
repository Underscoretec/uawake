"""Merge strings extracted by the Swift compiler (.stringsdata) into a String Catalog.

Usage: sync-strings.py <DerivedData> <Localizable.xcstrings>
Reads the Debug build. Adds new keys and their comments, keeps existing entries and
translations, removes keys no longer in the source unless they have translations
(those are marked stale for a translator to review).
"""
import glob
import json
import subprocess
import sys

derived, catalog_path = sys.argv[1], sys.argv[2]
extracted = {}
for path in glob.glob(f"{derived}/Build/Intermediates.noindex/uawake.build/Debug/uawake.build/Objects-normal/*/*.stringsdata"):
    data = json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, check=True).stdout)
    for entries in data.get("tables", {}).values():
        for entry in entries:
            extracted[entry["key"]] = entry.get("comment")

with open(catalog_path) as f:
    catalog = json.load(f)
strings = catalog.setdefault("strings", {})
for key, comment in extracted.items():
    entry = strings.setdefault(key, {})
    entry.pop("extractionState", None)
    if comment:
        entry["comment"] = comment
for key in [k for k in strings if k not in extracted]:
    if strings[key].get("localizations"):
        strings[key]["extractionState"] = "stale"
    else:
        del strings[key]
catalog["strings"] = dict(sorted(strings.items()))
with open(catalog_path, "w") as f:
    json.dump(catalog, f, indent=2, ensure_ascii=False)
    f.write("\n")
stale = sum(1 for e in strings.values() if e.get("extractionState") == "stale")
print(f"{len(extracted)} strings extracted, {len(strings)} in catalog, {stale} stale")

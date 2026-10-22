#!/usr/bin/env python3
"""
Builds ../Install_sp_WhoIsActiveLogging.sql from Install_template.sql by embedding
Adam Machanic's sp_WhoIsActive (root = SQL 2022+, 2019/ = SQL 2012-2019).

Usage:
    python build_installer.py                      # clones https://github.com/amachanic/sp_whoisactive
    python build_installer.py --wia-path C:\\src\\sp_whoisactive   # use a local clone

Re-run whenever sp_WhoIsActive releases a new version, then commit the output.
"""
import argparse
import datetime
import pathlib
import re
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
TEMPLATE = HERE / "Install_template.sql"
OUTPUT = HERE.parent / "Install_sp_WhoIsActiveLogging.sql"
WIA_REPO = "https://github.com/amachanic/sp_whoisactive.git"


def extract_body(path: pathlib.Path) -> tuple[str, str]:
    """Return (procedure text without the SET/stub batches and trailing GO, version string)."""
    text = path.read_text(encoding="utf-8-sig").replace("\r\n", "\n")
    batches = re.split(r"(?im)^\s*GO\s*$", text)
    # expected: [SET options], [IF NOT EXISTS ... stub], [header comment + ALTER PROC], [empty]
    bodies = [b for b in batches if re.search(r"(?i)\bALTER\s+PROC(EDURE)?\s+dbo\.sp_WhoIsActive\b", b)]
    if len(bodies) != 1:
        sys.exit(f"{path}: expected exactly one ALTER PROC batch, found {len(bodies)}")
    if any(b.strip() for b in batches[batches.index(bodies[0]) + 1:]):
        sys.exit(f"{path}: unexpected content after the ALTER PROC batch")
    body = bodies[0].strip("\n")
    m = re.search(r"Who Is Active\? (v[\d.]+)", body)
    if not m:
        sys.exit(f"{path}: version string not found")
    if "@get_memory_info" not in body:
        sys.exit(f"{path}: @get_memory_info parameter missing - too old for the logging procs")
    return body, m.group(1)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wia-path", help="local clone of amachanic/sp_whoisactive")
    args = ap.parse_args()

    tmp = None
    if args.wia_path:
        src = pathlib.Path(args.wia_path)
    else:
        tmp = tempfile.TemporaryDirectory()
        src = pathlib.Path(tmp.name) / "sp_whoisactive"
        subprocess.run(["git", "clone", "--depth", "1", "-q", WIA_REPO, str(src)], check=True)

    commit = subprocess.run(["git", "-C", str(src), "log", "-1", "--format=%h %cs"],
                            capture_output=True, text=True).stdout.strip() or "unknown"

    body_2022, ver_2022 = extract_body(src / "sp_WhoIsActive.sql")
    body_2019, ver_2019 = extract_body(src / "2019" / "sp_WhoIsActive.sql")

    out = TEMPLATE.read_text(encoding="utf-8").replace("\r\n", "\n")
    for token, value in {
        "{{WIA_2022_BODY}}": body_2022.replace("'", "''"),
        "{{WIA_2019_BODY}}": body_2019.replace("'", "''"),
        "{{WIA_2022_VERSION}}": ver_2022,
        "{{WIA_2019_VERSION}}": ver_2019,
        "{{WIA_COMMIT}}": f"amachanic/sp_whoisactive@{commit}",
        "{{BUILD_DATE}}": datetime.date.today().isoformat(),
    }.items():
        if token not in out:
            sys.exit(f"template token {token} not found")
        out = out.replace(token, value)

    if "{{" in out:
        sys.exit("unreplaced template token left in output")

    # CRLF for SSMS / Windows users
    OUTPUT.write_bytes(out.replace("\n", "\r\n").encode("utf-8"))
    print(f"wrote {OUTPUT} ({OUTPUT.stat().st_size:,} bytes): 2022+ {ver_2022}, 2019 {ver_2019}, {commit}")

    if tmp:
        tmp.cleanup()


if __name__ == "__main__":
    main()

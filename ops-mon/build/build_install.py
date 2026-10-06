#!/usr/bin/env python3
"""Concatenate src/sql/*.sql (in name order) into install/MON_Install.sql.
Run after editing any source file:  python build/build_install.py"""
import pathlib
root = pathlib.Path(__file__).resolve().parent.parent
parts = sorted((root / "src" / "sql").glob("*.sql"))
out = root / "install" / "MON_Install.sql"
out.write_text("".join(p.read_text(encoding="utf-8") for p in parts), encoding="utf-8")
print(f"{out} built from {len(parts)} files")

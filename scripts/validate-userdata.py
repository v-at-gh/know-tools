#!/usr/bin/env python3
"""validate-userdata.py -- read-only inventory of know-server runtime data.

Usage:
    python scripts/validate-userdata.py <project-root>
    python scripts/validate-userdata.py ~/data/src/local/know/private/know-server

Reads state/*.db in strict read-only mode via sqlite3 URI. No writes, no
checkpoints, no side effects. Emits human-readable inventory + exit code:

    0 = clean, no warnings
    1 = clean, warnings present
    2 = integrity errors found
    3 = script error (bad args, unreadable path)

Cross-platform: identical behavior on macOS, Windows, Linux. Pure stdlib.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_VERSION = "1.0"
DB_NAMES = ("app", "content", "users", "tasks", "server")
OUTPUT_SUBDIRS = ("datasets", "knowledge", "syllabus")


def human_bytes(b: int) -> str:
    if b < 1024:
        return f"{b}B"
    if b < 1048576:
        return f"{b / 1024:.1f}K"
    if b < 1073741824:
        return f"{b / 1048576:.1f}M"
    return f"{b / 1073741824:.1f}G"


def open_db_readonly(path: Path) -> sqlite3.Connection | None:
    """Open a SQLite DB in strict read-only mode. None on failure.

    Uses file: URI with mode=ro so the file is never opened for writing.
    Prevents WAL checkpointing and journal creation as side effects.
    """
    try:
        uri = path.resolve().as_uri() + "?mode=ro"
        return sqlite3.connect(uri, uri=True, timeout=5.0)
    except (sqlite3.Error, ValueError, OSError):
        return None


def safe_query(conn: sqlite3.Connection, sql: str):
    """Run a query; return list of rows, or None on any sqlite error."""
    try:
        return conn.execute(sql).fetchall()
    except sqlite3.Error:
        return None


def classify_table(name: str) -> str:
    """Human hint for table category (purely cosmetic)."""
    if name.startswith("sqlite_"):
        return " (sqlite internal)"
    if name.endswith("_fts"):
        return " (FTS index)"
    if "_fts_" in name:
        return " (FTS shadow)"
    if "_embedding_index" in name:
        return " (vec map)"
    if "_embeddings_" in name or name.endswith("_embeddings"):
        return " (vec)"
    return ""


class Validator:
    def __init__(self, root: Path):
        self.root = root
        self.warn = 0
        self.err = 0

    def out(self, s: str = "") -> None:
        print(s)

    def section(self, title: str) -> None:
        self.out()
        self.out(f"## {title}")
        self.out()

    def kv(self, k: str, v: str) -> None:
        self.out(f"  {k + ':':<10} {v}")

    def warn_msg(self, msg: str) -> None:
        self.kv("WARN", msg)
        self.warn += 1

    def err_msg(self, msg: str) -> None:
        self.kv("ERROR", msg)
        self.err += 1

    def run(self) -> int:
        self.header()
        self.check_databases()
        self.check_logs()
        self.check_output()
        self.check_qaps()
        self.check_filesystem()
        self.summary()
        if self.err > 0:
            return 2
        if self.warn > 0:
            return 1
        return 0

    def header(self) -> None:
        self.out("=" * 64)
        self.out("know-server user data inventory")
        self.out(f"root:    {self.root}")
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.out(f"when:    {now}")
        self.out(f"host:    {socket.gethostname()}")
        self.out(f"python:  {sys.version.split()[0]}")
        self.out(f"script:  validate-userdata v{SCRIPT_VERSION}")
        self.out("=" * 64)

    def check_databases(self) -> None:
        self.section("DATABASES")
        for name in DB_NAMES:
            db_path = self.root / "state" / f"{name}.db"
            self.out(f"--- {name}.db ---")

            if not db_path.is_file():
                self.kv("status", "MISSING")
                self.warn += 1
                self.out()
                continue

            st = db_path.stat()
            self.kv("size", f"{human_bytes(st.st_size)} ({st.st_size} bytes)")
            self.kv("mtime", datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M"))

            wal = db_path.with_name(db_path.name + "-wal")
            if wal.is_file():
                wsz = wal.stat().st_size
                self.kv("WAL", f"present, {human_bytes(wsz)}")
                if wsz > 10 * 1048576:
                    self.warn_msg("WAL > 10MB; checkpoint may be needed")
            else:
                self.kv("WAL", "absent")

            conn = open_db_readonly(db_path)
            if conn is None:
                self.err_msg("cannot open in read-only mode")
                self.out()
                continue

            try:
                j = safe_query(conn, "PRAGMA journal_mode;")
                self.kv("journal", j[0][0] if j else "?")

                ic = safe_query(conn, "PRAGMA quick_check(1);")
                if ic and ic[0][0] == "ok":
                    self.kv("integrity", "ok")
                else:
                    detail = ic[0][0] if ic else "query failed"
                    self.err_msg(f"integrity: {detail}")

                tables = safe_query(
                    conn,
                    "SELECT name FROM sqlite_master "
                    "WHERE type='table' AND name NOT LIKE 'sqlite_%' "
                    "ORDER BY name;",
                )
                if not tables:
                    self.kv("tables", "NONE (empty DB?)")
                    self.warn += 1
                else:
                    self.out("  tables:")
                    for (t,) in tables:
                        if not t:
                            continue
                        cnt = safe_query(conn, f'SELECT COUNT(*) FROM "{t}";')
                        count_str = str(cnt[0][0]) if cnt else "?"
                        hint = classify_table(t)
                        self.out(f"    {t}: {count_str}{hint}")
            finally:
                conn.close()
            self.out()

    def check_logs(self) -> None:
        self.section("LOGS (state/logs/)")
        logs_dir = self.root / "state" / "logs"
        if not logs_dir.is_dir():
            self.kv("status", f"MISSING: {logs_dir}")
            self.warn += 1
            return

        files = sorted(logs_dir.glob("*.jsonl"))
        if not files:
            self.kv("status", "no *.jsonl files")
            self.warn += 1
            return

        self.out(f"  {'file':<30} {'size':<10} last-modified")
        total = 0
        oldest = None
        newest = None
        for f in files:
            st = f.stat()
            total += st.st_size
            mt = datetime.fromtimestamp(st.st_mtime)
            if oldest is None or mt < oldest:
                oldest = mt
            if newest is None or mt > newest:
                newest = mt
            self.out(f"  {f.name:<30} {human_bytes(st.st_size):<10} {mt.strftime('%Y-%m-%d %H:%M')}")
        self.out()
        self.kv("files", str(len(files)))
        self.kv("total", human_bytes(total))
        self.kv("oldest", oldest.strftime("%Y-%m-%d %H:%M") if oldest else "n/a")
        self.kv("newest", newest.strftime("%Y-%m-%d %H:%M") if newest else "n/a")
        if newest:
            age_h = (datetime.now() - newest).total_seconds() / 3600
            if age_h > 24:
                self.warn_msg("no log modified in last 24h; services may be down")

    def check_output(self) -> None:
        self.section("OUTPUT (datasets + knowledge)")
        output = self.root / "output"
        if not output.is_dir():
            self.kv("status", f"MISSING: {output}")
            self.warn += 1
            return
        for sub in OUTPUT_SUBDIRS:
            p = output / sub
            if not p.is_dir():
                self.kv("status", f"{sub}/ MISSING")
                self.warn += 1
                continue
            files = [x for x in p.rglob("*") if x.is_file()]
            total = sum(f.stat().st_size for f in files)
            langs = sum(1 for x in p.iterdir() if x.is_dir())
            self.out(f"  {sub + '/':<12} {len(files):>6} files, {human_bytes(total)}")
            if langs > 0:
                self.out(f"    languages: {langs}")

    def check_qaps(self) -> None:
        self.section("QAPS (state/qaps/)")
        qaps = self.root / "state" / "qaps"
        manifest = self.root / "state" / "manifest.json"
        if not qaps.is_dir():
            self.kv("status", f"MISSING: {qaps}")
            self.warn += 1
            return
        qfiles = sorted(qaps.glob("*.qap"))
        total = sum(f.stat().st_size for f in qfiles)
        self.kv("qap files", f"{len(qfiles)}, total {human_bytes(total)}")

        if manifest.is_file():
            st = manifest.stat()
            try:
                data = json.loads(manifest.read_text(encoding="utf-8"))
                packs = len(data.get("packs", []))
            except Exception:
                packs = "?"
            self.kv(
                "manifest",
                f"{human_bytes(st.st_size)}, {packs} packs, modified "
                f"{datetime.fromtimestamp(st.st_mtime).strftime('%Y-%m-%d %H:%M')}",
            )
        else:
            self.kv("manifest", "MISSING; run update_manifest.py")
            self.warn += 1

    def check_filesystem(self) -> None:
        self.section("FILESYSTEM")
        try:
            usage = shutil.disk_usage(str(self.root))
        except OSError as e:
            self.err_msg(f"cannot stat disk: {e}")
            return
        used_pct = (usage.used / usage.total * 100) if usage.total else 0.0
        self.out(
            f"  total: {human_bytes(usage.total)}, "
            f"used: {human_bytes(usage.used)}, "
            f"free: {human_bytes(usage.free)} ({used_pct:.1f}% used)"
        )
        if used_pct > 90:
            self.warn_msg(f"disk usage at {used_pct:.0f}%")

    def summary(self) -> None:
        self.out()
        self.out("=" * 64)
        self.out("SUMMARY")
        self.out(f"  warnings: {self.warn}")
        self.out(f"  errors:   {self.err}")
        self.out("=" * 64)


def main() -> None:
    ap = argparse.ArgumentParser(
        prog="validate-userdata",
        description="Read-only inventory of know-server runtime data.",
    )
    ap.add_argument(
        "root",
        type=Path,
        help="Project root (e.g. ~/data/src/github.com/v-at-gh/know-server)",
    )
    args = ap.parse_args()

    if not args.root.is_dir():
        print(f"ERROR: not a directory: {args.root}", file=sys.stderr)
        sys.exit(3)

    v = Validator(args.root.resolve())
    sys.exit(v.run())


if __name__ == "__main__":
    main()
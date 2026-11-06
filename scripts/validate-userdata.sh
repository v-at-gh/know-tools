#!/usr/bin/env bash
# validate-userdata.sh — read-only inventory of know-server runtime data
#
# Usage:
#   ./validate-userdata.sh <project-root>
#   ./validate-userdata.sh ~/data/src/local/know/private/know-server
#   ./validate-userdata.sh /mnt/c/Users/User/data/src/qap/know-server
#
# Exit codes:
#   0 = clean, no warnings
#   1 = clean, warnings present
#   2 = clean, errors present
#   3 = script error (bad args, unreadable path, sqlite3 missing)

set -u
set -o pipefail

SCRIPT_VERSION="1.0"
WARN=0
ERR=0

if [ "$#" -ne 1 ]; then
	echo "Usage: $0 <project-root>" >&2
	echo "  e.g. $0 ~/data/src/github.com/v-at-gh/know-server" >&2
	exit 3
fi

ROOT="$1"
if [ ! -d "$ROOT" ]; then
	echo "ERROR: not a directory: $ROOT" >&2
	exit 3
fi
ROOT=$(cd "$ROOT" && pwd)

if ! command -v sqlite3 >/dev/null 2>&1; then
	echo "ERROR: sqlite3 not found in PATH" >&2
	exit 3
fi

# portable stat: macOS uses -f%z, Linux uses -c%s
fsize() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null; }
fmtime() { stat -f%Sm -t '%Y-%m-%d %H:%M' "$1" 2>/dev/null || stat -c%y "$1" 2>/dev/null | cut -d. -f1; }
human() {
	local b=$1
	if [ "$b" -lt 1024 ]; then
		echo "${b}B"
	elif [ "$b" -lt 1048576 ]; then
		awk -v b=$b 'BEGIN{printf "%.1fK", b/1024}'
	elif [ "$b" -lt 1073741824 ]; then
		awk -v b=$b 'BEGIN{printf "%.1fM", b/1048576}'
	else
		awk -v b=$b 'BEGIN{printf "%.1fG", b/1073741824}'
	fi
}

echo "================================================================"
echo "know-server user data inventory"
echo "root:    $ROOT"
echo "when:    $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "host:    $(uname -n)"
echo "script:  validate-userdata v$SCRIPT_VERSION"
echo "================================================================"

# ---------- DATABASES ----------
echo
echo "## DATABASES"
echo
for name in app content users tasks server; do
	db="$ROOT/state/${name}.db"
	echo "--- ${name}.db ---"
	if [ ! -f "$db" ]; then
		echo "  status:    MISSING"
		echo
		WARN=$((WARN + 1))
		continue
	fi

	sz=$(fsize "$db")
	echo "  size:      $(human "$sz") ($sz bytes)"
	echo "  mtime:     $(fmtime "$db")"

	wal="${db}-wal"
	if [ -f "$wal" ]; then
		wsz=$(fsize "$wal")
		echo "  WAL:       present, $(human "$wsz")"
		[ "$wsz" -gt 10485760 ] && {
			echo "  WARN:      WAL > 10MB — checkpoint may be needed"
			WARN=$((WARN + 1))
		}
	else
		echo "  WAL:       absent"
	fi

	echo "  journal:   $(sqlite3 "$db" "PRAGMA journal_mode;" 2>/dev/null || echo '?')"

	integrity=$(sqlite3 "$db" "PRAGMA quick_check(1);" 2>/dev/null | head -1)
	if [ "$integrity" = "ok" ]; then
		echo "  integrity: ok"
	else
		echo "  integrity: PROBLEM — ${integrity:-query failed}"
		ERR=$((ERR + 1))
	fi

	tables=$(sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;" 2>/dev/null)
	if [ -n "$tables" ]; then
		echo "  tables:"
		while IFS= read -r t; do
			[ -z "$t" ] && continue
			rc=$(sqlite3 "$db" "SELECT COUNT(*) FROM \"$t\";" 2>/dev/null)
			case "$t" in
			*_fts_* | *_embeddings_* | *_embedding_index) echo "    $t: ${rc:-?} (internal)" ;;
			*) echo "    $t: ${rc:-?}" ;;
			esac
		done <<<"$tables"
	else
		echo "  tables:    NONE (empty DB?)"
		WARN=$((WARN + 1))
	fi
	echo
done

# ---------- LOGS ----------
echo "## LOGS (state/logs/)"
echo
LOGS_DIR="$ROOT/state/logs"
if [ -d "$LOGS_DIR" ]; then
	total=0
	count=0
	oldest=""
	newest=""
	echo "  file                           size       last-modified"
	while IFS= read -r f; do
		sz=$(fsize "$f")
		mt=$(fmtime "$f")
		rel="${f#$LOGS_DIR/}"
		printf "  %-30s %-10s %s\n" "$rel" "$(human "$sz")" "$mt"
		total=$((total + sz))
		count=$((count + 1))
		[ -z "$oldest" ] || [[ "$mt" < "$oldest" ]] && oldest="$mt"
		[ -z "$newest" ] || [[ "$mt" > "$newest" ]] && newest="$mt"
	done < <(find "$LOGS_DIR" -maxdepth 1 -type f -name '*.jsonl' 2>/dev/null | sort)

	echo
	echo "  files:   $count"
	echo "  total:   $(human "$total")"
	echo "  oldest:  ${oldest:-n/a}"
	echo "  newest:  ${newest:-n/a}"
	[ -n "$(find "$LOGS_DIR" -maxdepth 1 -type f -name '*.jsonl' -mtime -1 2>/dev/null)" ] ||
		{
			echo "  WARN:    no log modified in last 24h — services may be down"
			WARN=$((WARN + 1))
		}
else
	echo "  MISSING: $LOGS_DIR"
	WARN=$((WARN + 1))
fi
echo

# ---------- OUTPUT ----------
echo "## OUTPUT (datasets + knowledge)"
echo
OUTPUT="$ROOT/output"
if [ -d "$OUTPUT" ]; then
	for sub in datasets knowledge syllabus; do
		if [ -d "$OUTPUT/$sub" ]; then
			cnt=$(find "$OUTPUT/$sub" -type f 2>/dev/null | wc -l | tr -d ' ')
			kb=$(du -sk "$OUTPUT/$sub" 2>/dev/null | awk '{print $1}')
			printf "  %-10s %6s files, %s\n" "$sub/" "$cnt" "$(human $((kb * 1024)))"
			langs=$(find "$OUTPUT/$sub" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
			[ "$langs" -gt 0 ] && echo "    languages: $langs"
		else
			echo "  ${sub}/: MISSING"
			WARN=$((WARN + 1))
		fi
	done
else
	echo "  MISSING: $OUTPUT"
	WARN=$((WARN + 1))
fi
echo

# ---------- QAPS ----------
echo "## QAPS (state/qaps/)"
echo
QAPS="$ROOT/state/qaps"
MANIFEST="$ROOT/state/manifest.json"
if [ -d "$QAPS" ]; then
	qcount=$(find "$QAPS" -maxdepth 1 -type f -name '*.qap' 2>/dev/null | wc -l | tr -d ' ')
	kb=$(du -sk "$QAPS" 2>/dev/null | awk '{print $1}')
	echo "  qap files: $qcount, total $(human $((kb * 1024)))"
	if [ -f "$MANIFEST" ]; then
		msz=$(fsize "$MANIFEST")
		mmt=$(fmtime "$MANIFEST")
		packs=$(python3 -c "import json,sys; d=json.load(open('$MANIFEST')); print(len(d.get('packs',[])))" 2>/dev/null || echo "?")
		echo "  manifest:  $(human "$msz"), $packs packs, modified $mmt"
	else
		echo "  manifest:  MISSING — run update_manifest.py"
		WARN=$((WARN + 1))
	fi
else
	echo "  MISSING: $QAPS"
	WARN=$((WARN + 1))
fi
echo

# ---------- FILESYSTEM ----------
echo "## FILESYSTEM"
echo
df -h "$ROOT" | tail -1 | awk '{printf "  total: %s, used: %s, free: %s (%s used)\n", $2, $3, $4, $5}'
used_pct=$(df -h "$ROOT" | tail -1 | awk '{print $5}' | tr -d '%')
[ "$used_pct" -gt 90 ] && {
	echo "  WARN: disk usage at ${used_pct}%"
	WARN=$((WARN + 1))
}
echo

echo "================================================================"
echo "SUMMARY"
echo "  warnings: $WARN"
echo "  errors:   $ERR"
echo "================================================================"

[ "$ERR" -gt 0 ] && exit 2
[ "$WARN" -gt 0 ] && exit 1
exit 0

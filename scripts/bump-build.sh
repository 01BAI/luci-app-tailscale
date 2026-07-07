#!/usr/bin/env bash
# 递增 BUILD 号：YYMMDD + 当日序号（2 位），如 26070701 → 26070702
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_FILE="$ROOT_DIR/BUILD"
DATE_PREFIX="$(date -u +%y%m%d)"

if [ -f "$BUILD_FILE" ]; then
	OLD="$(tr -d '[:space:]' < "$BUILD_FILE")"
	OLD_DATE="${OLD:0:6}"
	if [ "$OLD_DATE" = "$DATE_PREFIX" ] && [ "${#OLD}" -ge 8 ]; then
		SEQ=$((10#${OLD:6:2} + 1))
	else
		SEQ=1
	fi
else
	SEQ=1
fi

if [ "$SEQ" -gt 99 ]; then
	echo "当日 BUILD 序号已达 99，请明天再发布" >&2
	exit 1
fi

printf '%s%02d\n' "$DATE_PREFIX" "$SEQ" > "$BUILD_FILE"
echo "BUILD=$(tr -d '[:space:]' < "$BUILD_FILE")"

#!/usr/bin/env bash
# Run a SQL file (or stdin) against the local MySQL using the creds in .env.
# Usage: tools/mysql.sh file.sql [extra mysql args]
cd "$(dirname "$0")/.."
export MYSQL_PWD="$(grep -E '^MYSQL_PASSWORD=' .env | cut -d= -f2- | tr -d '\r')"
U="$(grep -E '^MYSQL_USER=' .env | cut -d= -f2- | tr -d '\r')"
M="/c/Program Files/MySQL/MySQL Server 8.4/bin/mysql.exe"
f="$1"; shift || true
if [ -n "$f" ] && [ "$f" != "-" ]; then "$M" -u "$U" --default-character-set=utf8mb4 --local-infile=1 "$@" < "$f"
else "$M" -u "$U" --default-character-set=utf8mb4 --local-infile=1 "$@"; fi

#!/bin/sh
# Whole-tree direct check-then-create gate. Reviewed observational probes require
# a nearby marker and an exact entry in check-then-create-allowlist.txt.
set -eu

allowlist=host/chez/check-then-create-allowlist.txt
scan_out=$(mktemp)
allowed_seen=$(mktemp)
allowed_expected=$(mktemp)
probe_file=$(mktemp)
probe_dir=$(mktemp)
trap 'rm -f "$scan_out" "$allowed_seen" "$allowed_expected" "$probe_file" "$probe_dir"' EXIT HUP INT TERM

scan() {
  perl -0777 -ne '
    while (/((?:\((?:if|when|unless)[\s\S]{0,180}?\(file-exists\?[^)]*\)|\(and\s+\(not\s+\(file-exists\?[^)]*\)\))[\s\S]{0,280}?\((?:mkdir|open-output-file|open-file-output-port)\b)/g) {
      $before = substr($_, ($-[0] > 600 ? $-[0] - 600 : 0), ($-[0] > 600 ? 600 : $-[0]));
      $line = 1 + (substr($_, 0, $-[0]) =~ tr/\n//);
      $id = "";
      while ($before =~ /check-then-create-allow:\s+([a-z0-9-]+)/g) { $id = $1; }
      ($hit = $1) =~ s/\n/ /g;
      print(($id ne "" ? "ALLOW\t$id" : "HIT\t-") . "\t$ARGV:$line\t$hit\n");
    }
  ' "$@"
}

set -- $(rg --files host/chez -g '*.ss')
scan "$@" > "$scan_out"
if awk -F '\t' '$1 == "HIT" { print; found=1 } END { exit !found }' "$scan_out"; then
  echo "check-then-create gate: unreviewed pre-create existence check found" >&2
  exit 1
fi

awk -F '\t' '$1 == "ALLOW" { print $2 }' "$scan_out" | sort -u > "$allowed_seen"
sed -n '/^[^#]/s/|.*//p' "$allowlist" | sort -u > "$allowed_expected"
if ! diff -u "$allowed_expected" "$allowed_seen"; then
  echo "check-then-create gate: allowlist is stale or a marker is unreviewed" >&2
  exit 1
fi

printf '%s\n' '(if (file-exists? p) (loop) (open-output-file p '\''truncate))' > "$probe_file"
printf '%s\n' '(and (not (file-exists? p)) (mkdir p))' > "$probe_dir"
if [ "$(scan "$probe_file" "$probe_dir" | awk -F '\t' '$1 == "HIT" { n++ } END { print n+0 }')" -ne 2 ]; then
  echo "check-then-create gate: self-test failed" >&2
  exit 1
fi

echo "CHECK-THEN-CREATE-CHECK OK ($(wc -l < "$allowed_seen" | tr -d ' ') reviewed probes)"

#!/usr/bin/env bash
# Reject files that are not plain ASCII/UTF-8 (e.g. UTF-16 produced by a
# PowerShell redirect). Helm, kubectl and the Go template engine all read UTF-8.
set -u

status=0

for f in "$@"; do
  [ -f "$f" ] || continue

  # Explicit UTF-16 BOM check (FF FE / FE FF leading bytes)
  bom=$(head -c 2 "$f" | od -An -tx1 | tr -d ' \n')
  if [ "$bom" = "fffe" ] || [ "$bom" = "feff" ]; then
    echo "ERROR: $f has a UTF-16 BOM (not UTF-8)."
    echo "  Fix: iconv -f UTF-16LE -t UTF-8 '$f' > fixed && mv fixed '$f'"
    status=1
    continue
  fi

  enc=$(file --brief --mime-encoding "$f")
  case "$enc" in
    us-ascii | utf-8) ;;
    *)
      echo "ERROR: $f is $enc, expected us-ascii/utf-8."
      echo "  Fix: iconv -f UTF-16LE -t UTF-8 '$f' > fixed && mv fixed '$f'"
      status=1
      ;;
  esac
done

exit $status

# shellcheck shell=bash
#
# Sourced helper for the helm pre-commit hooks. Not executable, no shebang.
#
# pre-commit hands hooks a list of *files*; helm operates on chart
# *directories*. Every helm hook therefore maps its filenames up to the nearest
# enclosing Chart.yaml and dedupes, which keeps the hooks generic as charts are
# added or renamed.
#
# Targets bash 3.2 with a BSD userland: no mapfile, no declare -A, no sort -V,
# no grep -P, no GNU sed -i.

# chart_dirs_for FILE... — print the chart directory owning each file, one per
# line, sorted and deduplicated. Files that live outside any chart are ignored,
# as is a chart directory that no longer exists (a deletion never satisfies -f).
chart_dirs_for() {
  local f d
  for f in "$@"; do
    d=$(dirname "$f")
    while [ "$d" != "." ] && [ "$d" != "/" ]; do
      if [ -f "$d/Chart.yaml" ]; then
        echo "$d"
        break
      fi
      d=$(dirname "$d")
    done
  done | sort -u
}

# require_bin NAME HINT — fail with an actionable message rather than a bare
# "command not found" from somewhere deep in a pipeline.
require_bin() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  echo "ERROR: '$1' is not on PATH but is required by this hook." >&2
  echo "  $2" >&2
  return 1
}

# chart_version FILE — print the chart's own version. Reads only the column-0
# `version:` key, so versions nested under `dependencies:` are ignored. Accepts
# "-" to read from stdin.
chart_version() {
  awk '
    /^version:/ {
      line = $0
      sub(/^version:[ \t]*/, "", line)
      sub(/[ \t]*#.*$/, "", line)
      gsub(/[ \t]/, "", line)
      print line
      exit
    }
  ' "$1" | tr -d "\"'"
}

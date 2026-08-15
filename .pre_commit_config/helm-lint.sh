#!/usr/bin/env bash
#
# helm lint --strict for every chart touched by the staged files, once bare and
# once per ci/*.yaml values file.
#
# `helm lint` also validates values.schema.json, so a values file that violates
# the schema fails here — there is no separate schema hook.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=./lib-chart-dirs.sh
. "$here/lib-chart-dirs.sh"

require_bin helm "Install it: brew install helm" || exit 1

status=0

# Heredoc rather than a pipe: under bash 3.2 the right-hand side of a pipe runs
# in a subshell, so assignments to `status` would be discarded.
while IFS= read -r chart; do
  [ -n "$chart" ] || continue

  if grep -q '^dependencies:' "$chart/Chart.yaml" && [ ! -f "$chart/Chart.lock" ]; then
    echo "ERROR: $chart declares dependencies: but has no Chart.lock."
    echo "  Fix: helm dependency update $chart"
    status=1
  fi

  echo "==> helm lint --strict $chart"
  if ! helm lint --strict "$chart"; then
    status=1
  fi

  for vals in "$chart"/ci/*.yaml; do
    [ -f "$vals" ] || continue
    echo "==> helm lint --strict $chart -f $vals"
    if ! helm lint --strict "$chart" -f "$vals"; then
      status=1
    fi
  done
done <<EOF
$(chart_dirs_for "$@")
EOF

exit $status

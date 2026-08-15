#!/usr/bin/env bash
#
# Render every chart touched by the staged files and validate the *rendered*
# manifests with kubeconform — bare, then once per ci/*.yaml values file.
#
# Chart templates are Go templates, so pointing kubeconform at the files on disk
# is meaningless; only `helm template` output is real YAML.
#
# Two passes, deliberately at different strictness:
#
#   bare chart   full strict, WITHOUT -ignore-missing-schemas. A chart's own
#                templates must render only upstream Kubernetes APIs, so every
#                resource has a schema and every resource must validate.
#
#   ci/*.yaml    strict, WITH -ignore-missing-schemas. These files exercise the
#                extraManifests passthrough, which is where CRDs like
#                ExternalSecret and PeerAuthentication come from; no schema for
#                those ships with kubeconform.
#
# The split matters: -ignore-missing-schemas does not merely skip CRDs, it skips
# any apiVersion kubeconform cannot resolve — including a typo'd one. Applied
# everywhere it would let `apiVersion: v1beta9` on a core Service pass silently.
# The bare pass is what catches that. -verbose keeps every skipped resource
# visible in the lenient pass so nothing hides behind the flag there either.
#
# Escape hatches:
#   KUBECONFORM_SCHEMA_LOCATION   append a CRD schema catalogue, e.g. the
#     datree CRDs-catalog, to validate passthrough resources properly. Opt-in
#     because it makes every run require network access:
#       export KUBECONFORM_SCHEMA_LOCATION='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
#   KUBECONFORM_IGNORE_MISSING_SCHEMAS=1   relax the bare pass too, for a chart
#     whose *default* values legitimately render a CRD.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=./lib-chart-dirs.sh
. "$here/lib-chart-dirs.sh"

require_bin helm "Install it: brew install helm" || exit 1
require_bin kubeconform "Install it: brew install kubeconform" || exit 1

BASE_ARGS="-strict -summary -verbose -schema-location default"
if [ -n "${KUBECONFORM_SCHEMA_LOCATION:-}" ]; then
  BASE_ARGS="$BASE_ARGS -schema-location $KUBECONFORM_SCHEMA_LOCATION"
fi

STRICT_ARGS="$BASE_ARGS"
if [ -n "${KUBECONFORM_IGNORE_MISSING_SCHEMAS:-}" ]; then
  STRICT_ARGS="$BASE_ARGS -ignore-missing-schemas"
fi
LENIENT_ARGS="$BASE_ARGS -ignore-missing-schemas"

status=0

# Fixed release name so the hook validates the same rendering on every run.
render_and_check() {
  local kc_args=$1 chart=$2
  shift 2
  # shellcheck disable=SC2086 # kc_args is a deliberate word list
  helm template ci "$chart" "$@" | kubeconform $kc_args
}

# Heredoc rather than a pipe: see helm-lint.sh.
while IFS= read -r chart; do
  [ -n "$chart" ] || continue

  echo "==> kubeconform $chart (default values, no missing schemas allowed)"
  if ! render_and_check "$STRICT_ARGS" "$chart"; then
    status=1
  fi

  for vals in "$chart"/ci/*.yaml; do
    [ -f "$vals" ] || continue
    echo "==> kubeconform $chart -f $vals"
    if ! render_and_check "$LENIENT_ARGS" "$chart" -f "$vals"; then
      status=1
    fi
  done
done <<EOF
$(chart_dirs_for "$@")
EOF

exit $status

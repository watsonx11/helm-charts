#!/usr/bin/env bash
#
# Require Chart.yaml's `version:` to move forward whenever a chart's content
# changes. A chart published without a version bump is indistinguishable from
# the one already in the index, and clients cache accordingly.
#
# Candidate charts come from pre-commit's own filename list, which already
# honours the hook's files:/exclude: patterns. But that list is not on its own
# evidence of a change: `pre-commit run --all-files` passes every chart file
# whether or not anything differs, so a fresh clone on a clean tree would fail.
# Each candidate is therefore confirmed against the base ref with `git diff`
# before its version is checked.
#
# README.md, .helmignore and ci/ are excluded from both the hook's files: list
# and the diff, so regenerating documentation or adjusting a test values file
# does not demand a bump.
#
# Escape hatch: SKIP=chart-version-bump git commit ...
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=./lib-chart-dirs.sh
. "$here/lib-chart-dirs.sh"

# Skip mid-merge, mid-rebase, mid-cherry-pick and mid-revert: resolving someone
# else's conflict should not require inventing a version bump.
git_dir=$(git rev-parse --git-dir)
for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
  if [ -e "$git_dir/$marker" ]; then
    echo "chart-version-bump: skipped ($marker present)."
    exit 0
  fi
done

# Base to compare against. PRE_COMMIT_FROM_REF is set by `pre-commit run
# --from-ref/--to-ref` and by the push stage; otherwise compare against HEAD,
# falling back to the empty tree in a repository with no commits yet.
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
if [ -n "${PRE_COMMIT_FROM_REF:-}" ]; then
  base=$PRE_COMMIT_FROM_REF
elif git rev-parse --verify --quiet "HEAD^{commit}" >/dev/null; then
  base=HEAD
else
  base=$EMPTY_TREE
fi

# semver_cmp NEW OLD — echoes gt, eq, lt, or bad.
#
# Build metadata is ignored (SemVer 10). A release outranks any prerelease of
# the same core version (SemVer 11.3); two prereleases are compared as plain
# strings, which is close enough for a "did it move forward" check.
semver_cmp() {
  local new=$1 old=$2
  local new_pre="" old_pre=""

  new=${new%%+*}
  old=${old%%+*}
  case "$new" in *-*)
    new_pre=${new#*-}
    new=${new%%-*}
    ;;
  esac
  case "$old" in *-*)
    old_pre=${old#*-}
    old=${old%%-*}
    ;;
  esac

  local n1 n2 n3 o1 o2 o3
  local IFS=.
  # shellcheck disable=SC2086 # deliberate split on IFS='.'
  set -- $new
  n1=${1:-} n2=${2:-} n3=${3:-}
  # shellcheck disable=SC2086
  set -- $old
  o1=${1:-} o2=${2:-} o3=${3:-}
  IFS=$' \t\n'

  local part
  for part in "$n1" "$n2" "$n3" "$o1" "$o2" "$o3"; do
    case "$part" in
      '' | *[!0-9]*)
        echo bad
        return 0
        ;;
    esac
  done

  local i
  for i in 1 2 3; do
    local a b
    eval "a=\$n$i"
    eval "b=\$o$i"
    if [ "$a" -gt "$b" ]; then
      echo gt
      return 0
    fi
    if [ "$a" -lt "$b" ]; then
      echo lt
      return 0
    fi
  done

  # Same core version; the prerelease suffix decides.
  if [ "$new_pre" = "$old_pre" ]; then
    echo eq
  elif [ -z "$new_pre" ]; then
    echo gt # release beats prerelease
  elif [ -z "$old_pre" ]; then
    echo lt # prerelease loses to release
  elif [ "$new_pre" \> "$old_pre" ]; then
    echo gt
  else
    echo lt
  fi
}

# chart_content_changed CHART — true when the chart differs from $base in any
# file that is not documentation or a CI values file. Covers tracked changes
# (staged and unstaged, since pre-commit stashes the latter during a commit) and
# newly added files that git does not track yet.
chart_content_changed() {
  local chart=$1
  if ! git diff --quiet "$base" -- "$chart" \
    ":(exclude)$chart/README.md" \
    ":(exclude)$chart/README.md.gotmpl" \
    ":(exclude)$chart/.helmignore" \
    ":(exclude)$chart/ci"; then
    return 0
  fi
  [ -n "$(git ls-files --others --exclude-standard -- "$chart" \
    ":(exclude)$chart/README.md" \
    ":(exclude)$chart/README.md.gotmpl" \
    ":(exclude)$chart/.helmignore" \
    ":(exclude)$chart/ci")" ]
}

status=0

# Heredoc rather than a pipe: under bash 3.2 the right-hand side of a pipe runs
# in a subshell, so assignments to `status` would be discarded.
while IFS= read -r chart; do
  [ -n "$chart" ] || continue

  if ! chart_content_changed "$chart"; then
    continue
  fi

  old_raw=$(git show "$base:$chart/Chart.yaml" 2>/dev/null || true)
  if [ -z "$old_raw" ]; then
    echo "chart-version-bump: $chart is new at $base; no bump required."
    continue
  fi

  # Read the worktree, not the index: pre-commit stashes unstaged changes for a
  # commit-stage run, so the worktree already equals what is being committed,
  # and reading the index would misreport under `run --all-files` on a dirty
  # tree.
  new_version=$(chart_version "$chart/Chart.yaml")
  old_version=$(printf '%s\n' "$old_raw" | chart_version -)

  if [ -z "$new_version" ]; then
    echo "ERROR: $chart/Chart.yaml has no top-level 'version:' key."
    status=1
    continue
  fi

  case "$(semver_cmp "$new_version" "$old_version")" in
    gt)
      echo "chart-version-bump: $chart $old_version -> $new_version. OK."
      ;;
    bad)
      echo "ERROR: $chart version is not parseable SemVer"
      echo "  old: '$old_version'  new: '$new_version'"
      status=1
      ;;
    *)
      echo "ERROR: $chart changed but its version did not move forward."
      echo "  $base: $old_version"
      echo "  worktree: $new_version"
      echo "  Fix: bump 'version:' in $chart/Chart.yaml"
      echo "  Override: SKIP=chart-version-bump git commit ..."
      status=1
      ;;
  esac
done <<EOF
$(chart_dirs_for "$@")
EOF

exit $status

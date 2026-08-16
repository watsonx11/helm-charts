# Helm Charts

Helm charts for the following applications.

| Chart                                        | Application                                                | Description                                                |
| -------------------------------------------- | ---------------------------------------------------------- | ---------------------------------------------------------- |
| [`charts/stig-manager`](charts/stig-manager) | [STIG Manager](https://github.com/nuwcdivnpt/stig-manager) | Application only — bring your own MySQL and OIDC provider. |

## Adding the repository

The charts are published to GitHub Pages. Add the repository once, then refresh
it whenever you want to pick up newly released versions:

```shell
helm repo add watsonx11 https://watsonx11.github.io/helm-charts
helm repo update watsonx11
```

`watsonx11` is just a local alias — name it whatever you like, and use that name
everywhere below. `helm repo update` (short form `helm repo up`) with no
argument refreshes every repository you have added; naming one keeps it quick.

See what is available:

```shell
helm search repo watsonx11              # latest version of each chart
helm search repo watsonx11 --versions   # every published version
```

Then install, pinning the chart version so a later release cannot change what
you deploy:

```shell
helm install stig-manager watsonx11/stig-manager --version 0.2.0 \
  --namespace stig-manager --create-namespace \
  --values my-values.yaml
```

Each chart's own README documents its values; see
[`charts/stig-manager`](charts/stig-manager) for that chart's requirements
before installing, since it needs an external MySQL and OIDC provider to become
ready.

`helm repo update` only refreshes the local index — it does not touch anything
running. To move an existing release onto a newer chart, update and then
upgrade:

```shell
helm repo update watsonx11
helm upgrade stig-manager watsonx11/stig-manager --version 0.3.0 --reuse-values
```

### Flux

Point a `HelmRepository` at the same URL:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: watsonx11
  namespace: flux-system
spec:
  interval: 60m0s
  url: https://watsonx11.github.io/helm-charts
```

### Installing from a clone

No repository needed — useful when developing a chart or pinning to an
unreleased commit:

```shell
helm install stig-manager ./charts/stig-manager --values my-values.yaml
```

## Conventions

These apply to every chart in this repository.

- **One chart per application, application only.** Databases, caches and other
  stateful dependencies are referenced by configuration, never bundled as
  subcharts. A dependency's lifecycle should not be tied to the application's
  release.
- **Platform-agnostic.** Charts render only upstream Kubernetes APIs. No service
  mesh, Gateway API, external-dns or secret-manager objects. Platform-specific
  manifests are layered on through each chart's `extraManifests` passthrough or
  through your own overlay.
- **Secrets both ways.** Every chart can template a Secret from values *or*
  consume an `existingSecret` with configurable key names, so Secrets produced
  by External Secrets, SOPS or a Vault/OpenBao injector are usable unchanged.
  `existingSecret` always wins.
- **Optional features ship disabled.** Ingress, NetworkPolicy and
  `extraManifests` are present but off by default.
- **Everything is a value.** Any knob the application exposes is reachable from
  `values.yaml`, with the upstream default recorded in a comment. Unset keys are
  omitted from the rendered config rather than pinned to an empty string.
- **`values.schema.json` on every chart**, so typos fail at `helm install`
  rather than at pod startup.
- **`ci/` values files on every chart**: `default-values.yaml` for the minimal
  install and `full-values.yaml` turning on every optional feature, so
  `helm template` exercises every branch.
- **`charts/*/README.md` is generated.** Edit `README.md.gotmpl`; the values
  tables come from the `# --` annotations in `values.yaml`. See below for the
  two rules that make that work.

## Documentation conventions

`charts/*/README.md` is written by helm-docs and is never edited directly.
Three things follow from that.

**Escape literal Go templates in `README.md.gotmpl`.** helm-docs runs the
template through `text/template`, so a bare `{{ include "x" . }}` in a code
block gets *executed* — and `include` is a Helm function, not a text/template
one, so it fails to parse. Go templates have no raw block; wrap each literal in
a backquoted string action:

```gotmpl
name: '{{ `{{ include "mychart.fullname" . }}` }}'
```

**Separate `values.yaml` banner comments with `=`, not `-`.** helm-docs treats
any comment line beginning with `# --` as a value description, and a rule of
dashes matches that:

```yaml
# ==============================================================================
# Section banner
# ==============================================================================
```

A `# ---------` rule silently becomes the description of whatever key follows,
producing a garbage table row for the whole parent object.

**Group values with `# @section -- <name>`.** helm-docs emits one `###` table
per section, so the generated reference mirrors the file's own structure:

```yaml
# -- Hostname or IP of the MySQL server.
# @section -- Database
host: mysql
```

A `|` inside a `# --` description breaks the generated table row, after which
markdownlint's MD013 fires with a confusing message. Escape it as `\|`.

## Local checks

Everything is driven by pre-commit. One prerequisite, because these two must
match the tooling your cluster is validated against and so are not pinned as
pre-commit repos:

```shell
brew install helm kubeconform
```

Then:

```shell
pre-commit install && pre-commit install-hooks
pre-commit run --all-files
```

The first `install-hooks` bootstraps Go and Node toolchains into
`~/.cache/pre-commit`; it takes a couple of minutes once and needs network.

What the chart-specific hooks do:

| Hook | Checks |
| ---- | ------ |
| `helm-docs-built` | regenerates `charts/*/README.md` from `README.md.gotmpl` and `values.yaml` |
| `chart-version-bump` | `Chart.yaml`'s `version:` moved forward whenever chart content changed |
| `helm-lint` | `helm lint --strict` on each chart, bare and with every `ci/*.yaml` — this is also what validates `values.schema.json` |
| `helm-kubeconform` | `helm template \| kubeconform` on the *rendered* manifests, bare and with every `ci/*.yaml` |
| `yamllint` | scoped to `Chart.yaml`, `values.yaml` and `ci/*`; the rule that matters is `key-duplicates`, which nothing else here catches |

Two escape hatches:

```shell
# Whole-worktree secret scan, not just staged changes.
pre-commit run --hook-stage manual gitleaks-full

# Commit chart changes without a version bump (rare; prefer bumping).
SKIP=chart-version-bump git commit ...
```

Set `KUBECONFORM_SCHEMA_LOCATION` to a CRD catalogue to validate the resources
that `extraManifests` passes through. It is opt-in because it makes every run
need network access:

```shell
export KUBECONFORM_SCHEMA_LOCATION='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

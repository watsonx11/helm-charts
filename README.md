# Helm Charts

Helm charts for the following applications.

| Chart | Application | Description |
|---|---|---|
| [`charts/stig-manager`](charts/stig-manager) | [STIG Manager](https://github.com/nuwcdivnpt/stig-manager) | API and web client for assessing systems against DISA STIGs. Application only — bring your own MySQL and OIDC provider. |

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
  consume an `existingSecret` with configurable key names, so Secrets produced by
  External Secrets, SOPS or a Vault/OpenBao injector are usable unchanged.
  `existingSecret` always wins.
- **Optional features ship disabled.** Ingress, NetworkPolicy and `extraManifests`
  are present but off by default.
- **Everything is a value.** Any knob the application exposes is reachable from
  `values.yaml`, with the upstream default recorded in a comment. Unset keys are
  omitted from the rendered config rather than pinned to an empty string.
- **`values.schema.json` on every chart**, so typos fail at `helm install` rather
  than at pod startup.
- **`ci/` values files on every chart**: `default-values.yaml` for the minimal
  install and `full-values.yaml` turning on every optional feature, so
  `helm template` exercises every branch.

## Local checks

```console
helm lint charts/<chart>
helm template t charts/<chart> | kubectl apply --dry-run=client -f -
helm template t charts/<chart> -f charts/<chart>/ci/full-values.yaml
```

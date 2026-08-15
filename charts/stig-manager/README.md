# stig-manager

A Helm chart for [STIG Manager](https://github.com/NUWCDIVNPT/stig-manager) — an
API and web client for managing the assessment of information systems against
DISA Security Technical Implementation Guides (STIGs).

![Version: 0.2.0](https://img.shields.io/badge/Version-0.2.0-informational?style=flat-square)
![AppVersion: 1.6.15](https://img.shields.io/badge/AppVersion-1.6.15-informational?style=flat-square)

**Homepage:** <https://github.com/NUWCDIVNPT/stig-manager>

## Scope

This chart deploys **the STIG Manager application only**. Deliberately out of
scope:

- **No database.** STIG Manager requires MySQL 8. Point `database.*` at one you
  already run — an operator-managed cluster, a cloud instance, a StatefulSet in
  a neighbouring namespace. Bundling a database would make the chart's lifecycle
  the database's lifecycle, which is the wrong trade for a production
  dependency.
- **No service mesh, Gateway API, external-dns, or secret-manager objects.** The
  chart renders a plain `networking.k8s.io/v1` Ingress and nothing else.
  Anything platform-specific goes through [`extraManifests`](#extramanifests) or
  your own overlay.

What the chart does own: the Deployment, Service, ServiceAccount,
the `STIGMAN_*`
ConfigMap, an optional Secret, optional Ingress and NetworkPolicy, and
first-class handling of custom CA certificates.

## Requirements

Kubernetes: `>=1.25.0-0`

| Requirement   | Notes                                                              |
| ------------- | ------------------------------------------------------------------ |
| MySQL         | 8.x, reachable from the pod, with a schema and a user that owns it |
| OIDC provider | Keycloak, Okta, Entra ID, … issuing JWTs the API can validate      |

## Install

```sh
helm install stig-manager ./charts/stig-manager \
  --namespace stig-manager --create-namespace \
  --set database.host=mysql.data.svc.cluster.local \
  --set database.user=stigman \
  --set database.schema=stigman \
  --set database.password=... \
  --set oidc.provider=https://keycloak.example.com/realms/stigman
```

Then verify:

```sh
helm test stig-manager -n stig-manager
```

## Connecting to an external MySQL

Create the schema and a user with full rights on it:

```sql
CREATE DATABASE stigman;
CREATE USER 'stigman'@'%' IDENTIFIED BY '...';
GRANT ALL PRIVILEGES ON stigman.* TO 'stigman'@'%';
```

STIG Manager migrates its own schema on startup, so an empty database is the
expected starting point.

Supply the password one of two ways.

**Chart-managed Secret** — fine for `helm install` driven by a values file you
already keep encrypted:

```yaml
database:
  host: mysql.data.svc.cluster.local
  schema: stigman
  user: stigman
  password: correct-horse-battery-staple
```

**Existing Secret** — the right choice with External Secrets, SOPS, or a
Vault/OpenBao injector. `database.existingSecret` always wins: when it is set
the chart renders no Secret of its own and never reads `database.password`.
Key names are values too, so a Secret produced by someone else is consumable
unchanged:

```yaml
database:
  host: mysql.data.svc.cluster.local
  existingSecret: stigman-db-credentials
  secretKeys:
    password: mysql_password        # whatever key that Secret actually uses
```

### TLS to the database

Mount the PEM material from a Secret you manage; the file names are keys within
it.

```yaml
database:
  tls:
    enabled: true
    existingSecret: stigman-db-tls
    caFile: ca.pem                  # STIGMAN_DB_TLS_CA_FILE — enables TLS
    certFile: client-cert.pem       # optional, for mTLS
    keyFile: client-key.pem         # optional, for mTLS
```

Upstream exposes no environment variable for a database key passphrase. If your
key is encrypted, wire the variable yourself through `extraEnvVars`; the chart
keeps a `database.secretKeys.dbTlsKeyPassphrase` slot so one Secret can still
carry it.

## Custom CA certificates

The API completes TLS to the OIDC provider (and optionally to MySQL) itself. If
either presents a certificate from a private CA, that chain has to be inside the
container — otherwise the API never becomes available and
`/api/op/configuration` reports the OIDC provider as unreachable.

Both `NODE_EXTRA_CA_CERTS` and `STIGMAN_OIDC_CA_CERTS` take exactly **one** file
path, so every certificate supplied here is concatenated into a single bundle.

**Inline PEMs** — the chart creates the ConfigMap:

```yaml
trustedCAs:
  enabled: true
  certs:
    01-corporate-root: |
      -----BEGIN CERTIFICATE-----
      ...
      -----END CERTIFICATE-----
    02-corporate-intermediate: |
      -----BEGIN CERTIFICATE-----
      ...
      -----END CERTIFICATE-----
```

Keys are concatenated in sorted order, so number them if chain order matters to
your tooling.

**Existing ConfigMap or Secret** — e.g. a trust-manager `Bundle` or a
cert-manager-issued CA:

```yaml
trustedCAs:
  enabled: true
  existingConfigMap: corporate-ca-bundle
  bundleKey: ca-bundle.pem          # the key inside that ConfigMap
```

Either way the bundle lands at
`{{ trustedCAs.mountPath }}/{{ trustedCAs.bundleKey }}`
(`/etc/stigman/ca/ca-bundle.pem` by default) and both variables point at it.
Each can be suppressed independently with
`trustedCAs.setNodeExtraCaCerts: false` / `trustedCAs.setOidcCaCerts: false`.

## Ingress

STIG Manager serves the whole application from one origin, so a single `/`
Prefix rule is normally right. The routes it exposes are:

| Path        | Serves                                          |
| ----------- | ----------------------------------------------- |
| `/`         | reference web client                            |
| `/api`      | the API                                         |
| `/docs`     | project documentation                           |
| `/api-docs` | SwaggerUI (only when `swagger.enabled`)         |
| `/socket/`  | log-stream WebSocket (`experimental.logStream`) |

Split them only if your platform routes sub-paths separately:

```yaml
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: stigman.example.com
      paths:
        - {path: /,         pathType: Prefix}
        - {path: /api,      pathType: Prefix}
        - {path: /docs,     pathType: Prefix}
        - {path: /api-docs, pathType: Prefix}
        - {path: /socket,   pathType: Prefix}
  tls:
    - secretName: stigman-tls
      hosts: [stigman.example.com]
```

`/socket/` requires an ingress controller that upgrades WebSocket connections;
with ingress-nginx that is the default. Also set `swagger.server` and
`swagger.redirect` to the externally visible URLs, otherwise SwaggerUI's OAuth2
flow redirects to the wrong host.

## Probes

The OpenAPI specification declares no global `security`, which makes these two
endpoints unauthenticated and therefore usable as probe targets:

- **`/api/op/state`** — answers even while the API is still waiting on its
  dependencies, so it is the liveness target. Probing anything else would
  restart a pod that is merely waiting for MySQL.
- **`/api/op/configuration`** — reflects database and OIDC reachability, so it
  is the readiness and startup target.

Any probe can be replaced wholesale:

```yaml
livenessProbe:
  custom:
    exec:
      command: [/bin/sh, -c, "..."]
```

## extraManifests

Anything the chart deliberately does not model goes here. Each entry is rendered
through `tpl`, so chart helpers and `.Release` are available:

```yaml
extraManifests:
  - apiVersion: security.istio.io/v1beta1
    kind: PeerAuthentication
    metadata:
      name: '{{ include "stig-manager.fullname" . }}'
      namespace: '{{ .Release.Namespace }}'
    spec:
      selector:
        matchLabels:
          app.kubernetes.io/name: stig-manager
      mtls:
        mode: STRICT
  - apiVersion: gateway.networking.k8s.io/v1
    kind: HTTPRoute
    metadata:
      name: '{{ include "stig-manager.fullname" . }}'
    spec:
      parentRefs:
        - name: public-gateway
          namespace: istio-system
      hostnames: [stigman.example.com]
      rules:
        - backendRefs:
            - name: '{{ include "stig-manager.fullname" . }}'
              port: 80
```

## Security context

Defaults run the pod as uid/gid 1000 (`USER node` in the upstream image) with
`runAsNonRoot`, `readOnlyRootFilesystem`, all capabilities dropped and the
`RuntimeDefault` seccomp profile.

`readOnlyRootFilesystem: true` depends on `tmpVolume.enabled` — Node writes its
compile cache under `/tmp`. Disabling the emptyDir without also relaxing the
read-only root filesystem will crash-loop the container.

## Labels and annotations

Four values, at three scopes:

| Value | Lands on |
| --- | --- |
| `commonLabels` / `commonAnnotations` | every object the chart renders |
| `deploymentAnnotations` | the Deployment object only |
| `podLabels` / `podAnnotations` | the pod template only |

`podLabels` never feeds `spec.selector.matchLabels` — the selector is only
`app.kubernetes.io/name` plus `app.kubernetes.io/instance`. Deployment selectors
are immutable after creation, so keeping them separate means you can add or
change pod labels on an existing release without the upgrade failing.

Annotation values must be strings. In a values file write `"true"`, not `true`;
on the command line use `--set-string`.

### The namespace is not one of them

This chart renders no Namespace object, so nothing here labels the namespace —
`commonLabels` reaches every object the chart *renders*, and the namespace is
not one. `helm install --create-namespace` produces a bare namespace carrying
only `kubernetes.io/metadata.name`.

That is deliberate. Namespace labels are cluster-policy concerns — Pod Security
Admission, service-mesh enrolment, network-policy tiers — they usually outlive
any one release, and a namespace commonly hosts several. Owning the Namespace in
the chart would also mean `helm uninstall` deletes it
*and everything inside it*, including a database that happens to share it.

Label it wherever you create it. Declaratively, alongside the release:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: stig-manager
  labels:
    istio.io/dataplane-mode: ambient
    pod-security.kubernetes.io/enforce: restricted
```

Or imperatively, against a namespace that already exists:

```sh
kubectl label namespace stig-manager istio.io/dataplane-mode=ambient
```

The chart's defaults already satisfy the `restricted` Pod Security Standard —
non-root uid 1000, no privilege escalation, all capabilities dropped, and the
`RuntimeDefault` seccomp profile — so enforcing it on the namespace needs no
values changes.

### Stakater Reloader

Reloader watches Deployments, so its annotations go in `deploymentAnnotations`:

```yaml
deploymentAnnotations:
  reloader.stakater.com/auto: "true"
```

Putting them in `commonAnnotations` also works — Reloader still sees them on the
Deployment — but they get stamped on the Service, ConfigMaps, Ingress and test
pod too, where nothing reads them.

**You may not need it.** The chart stamps `checksum/config`, `checksum/secret`
and `checksum/ca` on the pod template, so any change to config the chart *owns*
already rolls the pods on `helm upgrade`.

Reloader earns its keep for objects the chart references but does not render,
which no checksum can cover — above all a `database.existingSecret` whose
password External Secrets rotates out of band, with no `helm upgrade` to trigger
a roll:

| Referenced, not rendered |
| --- |
| `database.existingSecret` |
| `extraEnvVarsCM` / `extraEnvVarsSecret` |
| `trustedCAs.existingConfigMap` / `existingSecret` |
| `database.tls.existingSecret`, `tls.existingSecret` |

`reloader.stakater.com/auto: "true"` covers everything mounted or referenced as
env. To scope it to the rotating Secret alone:

```yaml
deploymentAnnotations:
  secret.reloader.stakater.com/reload: "stigman-db-credentials"
```

Reloader is not a chart dependency — it has to be installed in the cluster
already. Without it the annotation is inert, not an error.

## Application configuration

Every key below maps to a `STIGMAN_*` environment variable. **Keys left `null`
are omitted from the ConfigMap entirely**, so the application's own default
applies — see the inline comments in `values.yaml` for what each default is.

| Key                                                                                              | Environment variable                                                                                              |
| ------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| `classification`                                                                                 | `STIGMAN_CLASSIFICATION`                                                                                          |
| `api.port` / `api.address` / `api.maxJsonBody` / `api.maxUpload`                                 | `STIGMAN_API_PORT` / `_ADDRESS` / `_MAX_JSON_BODY` / `_MAX_UPLOAD`                                                |
| `database.host` / `port` / `schema` / `user` / `maxConnections`                                  | `STIGMAN_DB_HOST` / `_PORT` / `_SCHEMA` / `_USER` / `_MAX_CONNECTIONS`                                            |
| `database.password` or `database.existingSecret`                                                 | `STIGMAN_DB_PASSWORD` (via `secretKeyRef`)                                                                        |
| `database.tls.caFile` / `certFile` / `keyFile`                                                   | `STIGMAN_DB_TLS_CA_FILE` / `_CERT_FILE` / `_KEY_FILE`                                                             |
| `oidc.provider` / `clientProvider` / `audience` / `jwksCacheMaxAge`                              | `STIGMAN_OIDC_PROVIDER` / `STIGMAN_CLIENT_OIDC_PROVIDER` / `STIGMAN_JWT_AUD_VALUE` / `STIGMAN_JWKS_CACHE_MAX_AGE` |
| `oidc.claims.username` / `name` / `email` / `privileges` / `scope` / `serviceName` / `assertion` | `STIGMAN_JWT_*_CLAIM`                                                                                             |
| `client.id` / `disabled` / `directory` / `apiBase` / `scopePrefix` / `extraScopes`               | `STIGMAN_CLIENT_ID` / `_DISABLED` / `_DIRECTORY` / `_API_BASE` / `_SCOPE_PREFIX` / `_EXTRA_SCOPES`                |
| `client.reauthAction` / `responseMode` / `userTimeout` / `adminTimeout`                          | `STIGMAN_CLIENT_REAUTH_ACTION` / `_RESPONSE_MODE` / `_USER_TIMEOUT` / `_ADMIN_TIMEOUT`                            |
| `client.stateEvents` / `strictPkce` / `consoleMode` / `displayAppManagers`                       | `STIGMAN_CLIENT_STATE_EVENTS` / `_STRICT_PKCE` / `_CONSOLE_MODE` / `_DISPLAY_APPMANAGERS`                         |
| `client.welcome.title` / `message` / `link` / `image`                                            | `STIGMAN_CLIENT_WELCOME_*`                                                                                        |
| `swagger.enabled` / `server` / `redirect` / `oidcProvider`                                       | `STIGMAN_SWAGGER_*`                                                                                               |
| `docs.disabled` / `docs.directory`                                                               | `STIGMAN_DOCS_DISABLED` / `_DIRECTORY`                                                                            |
| `logging.level` / `logging.mode`                                                                 | `STIGMAN_LOG_LEVEL` / `STIGMAN_LOG_MODE`                                                                          |
| `dependencyRetries`                                                                              | `STIGMAN_DEPENDENCY_RETRIES`                                                                                      |
| `experimental.appData` / `experimental.logStream`                                                | `STIGMAN_EXPERIMENTAL_APPDATA` / `_LOGSTREAM`                                                                     |
| `dev.allowInsecureTokens` / `responseValidation` / `logOptStats`                                 | `STIGMAN_DEV_*`                                                                                                   |
| `tls.certFile` / `keyFile` / `keyPassphrase`                                                     | `STIGMAN_API_TLS_CERT_FILE` / `_KEY_FILE` / `_KEY_PASSPHRASE`                                                     |
| `trustedCAs.*`                                                                                   | `NODE_EXTRA_CA_CERTS`, `STIGMAN_OIDC_CA_CERTS`                                                                    |
| `extraConfig`                                                                                    | raw `STIGMAN_*` passthrough, merged last                                                                          |

`extraConfig` exists so a variable upstream adds tomorrow does not require
a chart change:

```yaml
extraConfig:
  STIGMAN_SOME_NEW_VAR: "value"
```

### Environment precedence

Later wins:

1. `envFrom` the chart's ConfigMap
2. `envFrom` each `extraEnvVarsCM`
3. `envFrom` each `extraEnvVarsSecret`
4. inline `env` — `STIGMAN_DB_PASSWORD`, CA paths, TLS file paths
5. `extraEnvVars`

## Upgrading

The API migrates its own MySQL schema on startup. **Back the database up before
a major appVersion bump** — migrations are not reversible by downgrading the
image.

## Development

```shell
pre-commit run --all-files
```

`ci/default-values.yaml` is the minimal install; `ci/full-values.yaml` turns on
every optional feature so that `helm template` exercises every branch. Both are
linted and rendered by the `helm-lint` and `helm-kubeconform` hooks.

## Source Code

- <https://github.com/NUWCDIVNPT/stig-manager>
- <https://github.com/NUWCDIVNPT/stig-manager/pkgs/container/stig-manager>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| watsonx11 | | <https://github.com/watsonx11> |

## Values

### Naming, image and workload

| Key                                         | Type   | Default                                                                      | Description                                                                                                       |
| ------------------------------------------- | ------ | ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| nameOverride                                | string | `""`                                                                         | Override the chart name used in resource names and labels.                                                        |
| fullnameOverride                            | string | `""`                                                                         | Override the fully qualified release name.                                                                        |
| image.registry                              | string | `""`                                                                         | Image registry. Leave empty to use the repository as written (Docker Hub).                                        |
| image.repository                            | string | `"nuwcdivnpt/stig-manager"`                                                  | Image repository.                                                                                                 |
| image.tag                                   | string | `""`                                                                         | Image tag. Defaults to the chart's appVersion.                                                                    |
| image.digest                                | string | `""`                                                                         | Pull by digest instead of tag (e.g. `sha256:abc...`). Wins over `tag`.                                            |
| image.pullPolicy                            | string | `"IfNotPresent"`                                                             | Image pull policy.                                                                                                |
| imagePullSecrets                            | list   | `[]`                                                                         | Image pull secrets applied to the pod.                                                                            |
| replicaCount                                | int    | `1`                                                                          | Number of API replicas. The API is stateless; all state lives in MySQL.                                           |
| strategy                                    | object | `{"rollingUpdate":{"maxSurge":1,"maxUnavailable":0},"type":"RollingUpdate"}` | Deployment update strategy.                                                                                       |
| revisionHistoryLimit                        | int    | `3`                                                                          | How many old ReplicaSets to retain.                                                                               |
| serviceAccount.create                       | bool   | `true`                                                                       | Create a ServiceAccount for the pod.                                                                              |
| serviceAccount.name                         | string | `""`                                                                         | Name of the ServiceAccount. Generated from the release name when empty.                                           |
| serviceAccount.annotations                  | object | `{}`                                                                         | Extra annotations for the ServiceAccount.                                                                         |
| serviceAccount.labels                       | object | `{}`                                                                         | Extra labels for the ServiceAccount.                                                                              |
| serviceAccount.automountServiceAccountToken | bool   | `false`                                                                      | Mount a token into pods that use this ServiceAccount by default.                                                  |
| serviceAccount.imagePullSecrets             | list   | `[]`                                                                         | Image pull secrets attached to the ServiceAccount.                                                                |
| automountServiceAccountToken                | bool   | `false`                                                                      | Mount the ServiceAccount token in the API pod. The application never calls the Kubernetes API, so this stays off. |

### Application

| Key             | Type   | Default | Description                                                                                                                         |
| --------------- | ------ | --------| ----------------------------------------------------------------------------------------------------------------------------------- |
| classification  | string | `"U"`   | STIGMAN_CLASSIFICATION. Classification banner rendered by the web client. One of: NONE, U, CUI, C, S, TS, SCI. Upstream default: U. |
| api.port        | int    | `54000` | STIGMAN_API_PORT. TCP port the API listens on. Also the container port.                                                             |
| api.address     | string | `nil`   | STIGMAN_API_ADDRESS. Listen address. Upstream default: 0.0.0.0.                                                                     |
| api.maxJsonBody | string | `nil`   | STIGMAN_API_MAX_JSON_BODY. Max application/json request body, in bytes. Upstream default: 5242880.                                  |
| api.maxUpload   | string | `nil`   | STIGMAN_API_MAX_UPLOAD. Max multipart/form-data upload, in bytes. Upstream default: 1073741824.                                     |

### Database

| Key                                      | Type   | Default                                                                                                                  | Description                                                                                                                                                                              |
| ---------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| database.host                            | string | `"mysql"`                                                                                                                | STIGMAN_DB_HOST. Hostname or IP of the MySQL server.                                                                                                                                     |
| database.port                            | int    | `3306`                                                                                                                   | STIGMAN_DB_PORT. MySQL TCP port.                                                                                                                                                         |
| database.schema                          | string | `"stigman"`                                                                                                              | STIGMAN_DB_SCHEMA. Schema holding the STIG Manager objects.                                                                                                                              |
| database.user                            | string | `"stigman"`                                                                                                              | STIGMAN_DB_USER. MySQL user.                                                                                                                                                             |
| database.password                        | string | `""`                                                                                                                     | Password for `database.user`. Ignored when `existingSecret` is set.                                                                                                                      |
| database.existingSecret                  | string | `""`                                                                                                                     | Name of an existing Secret carrying the database credentials. Wins over `database.password`; when set, no Secret is created by this chart.                                               |
| database.secretKeys                      | object | `{"apiTlsKeyPassphrase":"api-tls-key-passphrase","dbTlsKeyPassphrase":"db-tls-key-passphrase","password":"db-password"}` | Keys within the Secret (chart-managed or existing).                                                                                                                                      |
| database.secretKeys.password             | string | `"db-password"`                                                                                                          | Key holding the database password (STIGMAN_DB_PASSWORD).                                                                                                                                 |
| database.secretKeys.dbTlsKeyPassphrase   | string | `"db-tls-key-passphrase"`                                                                                                | Key holding the database TLS private key passphrase, if your tooling stores one. Not consumed by the application today; kept so a single Secret can carry it for use via `extraEnvVars`. |
| database.secretKeys.apiTlsKeyPassphrase  | string | `"api-tls-key-passphrase"`                                                                                               | Key holding the API server TLS private key passphrase (STIGMAN_API_TLS_KEY_PASSPHRASE).                                                                                                  |
| database.maxConnections                  | string | `nil`                                                                                                                    | STIGMAN_DB_MAX_CONNECTIONS. Connection pool –size. Upstream default: 25.                                                                                                                 |
| database.tls.enabled                     | bool   | `false`                                                                                                                  | Enable TLS to MySQL. Requires `existingSecret`.                                                                                                                                          |
| database.tls.mountPath                   | string | `"/etc/stigman/db-tls"`                                                                                                  | Where the material is mounted in the container.                                                                                                                                          |
| database.tls.existingSecret              | string | `""`                                                                                                                     | Secret holding the database TLS material.                                                                                                                                                |
| database.tls.caFile                      | string | `"ca.pem"`                                                                                                               | STIGMAN_DB_TLS_CA_FILE. Key in the Secret holding the CA certificate. Setting this is what enables TLS connections to the database.                                                      |
| database.tls.certFile                    | string | `""`                                                                                                                     | STIGMAN_DB_TLS_CERT_FILE. Client certificate, for mTLS. Optional.                                                                                                                        |
| database.tls.keyFile                     | string | `""`                                                                                                                     | STIGMAN_DB_TLS_KEY_FILE. Client private key, for mTLS. Optional.                                                                                                                         |
| database.tls.keyPassphrase               | string | `""`                                                                                                                     | Passphrase for the client private key. Stored under `database.secretKeys.dbTlsKeyPassphrase` in the chart-managed Secret.                                                                |

### OIDC

| Key | Type | Default | Description |
| ----- | ------ | --------- | ------------- |
| oidc.provider | string | `""` | STIGMAN_OIDC_PROVIDER. Base URL of the OIDC issuer. `/.well-known/openid-configuration` is appended when fetching metadata. e.g. `https://keycloak.example.com/realms/stigman` |
| oidc.clientProvider | string | `nil` | STIGMAN_CLIENT_OIDC_PROVIDER. Web-client override of the issuer URL, for split-horizon DNS where the browser and the API reach the IdP differently. |
| oidc.audience | string | `nil` | STIGMAN_JWT_AUD_VALUE. Required `aud` claim value. Unset disables the check. |
| oidc.jwksCacheMaxAge | string | `nil` | STIGMAN_JWKS_CACHE_MAX_AGE. Minutes before the JWKS cache is stale. Upstream default: 10. |
| oidc.claims.username | string | `nil` | STIGMAN_JWT_USERNAME_CLAIM. Upstream default: preferred_username. |
| oidc.claims.name | string | `nil` | STIGMAN_JWT_NAME_CLAIM. Upstream default: name. |
| oidc.claims.email | string | `nil` | STIGMAN_JWT_EMAIL_CLAIM. Upstream default: email. |
| oidc.claims.privileges | string | `nil` | STIGMAN_JWT_PRIVILEGES_CLAIM. Upstream default: realm_access.roles. |
| oidc.claims.scope | string | `nil` | STIGMAN_JWT_SCOPE_CLAIM. Upstream default: scope. |
| oidc.claims.serviceName | string | `nil` | STIGMAN_JWT_SERVICENAME_CLAIM. Upstream default: clientId. |
| oidc.claims.assertion | string | `nil` | STIGMAN_JWT_ASSERTION_CLAIM. Upstream default: jti. |

### Web client

| Key | Type | Default | Description |
| ----- | ------ | --------- | ------------- |
| client.id | string | `"stig-manager"` | STIGMAN_CLIENT_ID. OIDC clientId the web client authenticates with. Upstream default: stig-manager. |
| client.disabled | string | `nil` | STIGMAN_CLIENT_DISABLED. `true` stops the API serving the web client. |
| client.directory | string | `nil` | STIGMAN_CLIENT_DIRECTORY. Location of the client files inside the image. |
| client.apiBase | string | `nil` | STIGMAN_CLIENT_API_BASE. Base URL for client → API requests, relative to window.location. Upstream default: api. |
| client.scopePrefix | string | `nil` | STIGMAN_CLIENT_SCOPE_PREFIX. Prefix added to each requested scope. Needed by providers such as Entra ID (`api://<app-id>/`). |
| client.extraScopes | string | `nil` | STIGMAN_CLIENT_EXTRA_SCOPES. Space-separated extra OAuth2 scopes, e.g. `offline_access` for Okta. |
| client.reauthAction | string | `nil` | STIGMAN_CLIENT_REAUTH_ACTION. How to re-prompt on token expiry: popup, iframe, tab or reload. Upstream default: popup. |
| client.responseMode | string | `nil` | STIGMAN_CLIENT_RESPONSE_MODE. Deprecated upstream. query or fragment. |
| client.userTimeout | string | `nil` | STIGMAN_CLIENT_USER_TIMEOUT. Idle minutes before a regular user must re-authenticate. 0 disables idle detection. Upstream default: 60. |
| client.adminTimeout | string | `nil` | STIGMAN_CLIENT_ADMIN_TIMEOUT. Same, for admin users. Upstream default: 10. |
| client.stateEvents | string | `nil` | STIGMAN_CLIENT_STATE_EVENTS. Whether the client consumes server-sent events about API state. Disable only to work around proxy buffering. |
| client.strictPkce | string | `nil` | STIGMAN_CLIENT_STRICT_PKCE. Whether the client requires the provider to advertise PKCE/S256 per RFC 8414. |
| client.consoleMode | string | `nil` | STIGMAN_CLIENT_CONSOLE_MODE. Browser console verbosity. Upstream default: production. |
| client.displayAppManagers | string | `nil` | STIGMAN_CLIENT_DISPLAY_APPMANAGERS. Show application managers on the home page. |
| client.welcome.title | string | `nil` | STIGMAN_CLIENT_WELCOME_TITLE. Title of the Home tab welcome widget. |
| client.welcome.message | string | `nil` | STIGMAN_CLIENT_WELCOME_MESSAGE. Body text of the welcome widget. |
| client.welcome.link | string | `nil` | STIGMAN_CLIENT_WELCOME_LINK. Link rendered after the welcome message. |
| client.welcome.image | string | `nil` | STIGMAN_CLIENT_WELCOME_IMAGE. URL of an externally hosted image. The application does not serve this image itself. |

### SwaggerUI

| Key | Type | Default | Description |
| ----- | ------ | --------- | ------------- |
| swagger.enabled | string | `nil` | STIGMAN_SWAGGER_ENABLED. Serve the SwaggerUI SPA at /api-docs. Upstream default: false. |
| swagger.server | string | `nil` | STIGMAN_SWAGGER_SERVER. API base URL as SwaggerUI should call it, e.g. `https://stigman.example.com/api`. |
| swagger.redirect | string | `nil` | STIGMAN_SWAGGER_REDIRECT. OAuth2 redirect URL SwaggerUI sends to the IdP, e.g. `https://stigman.example.com/api-docs/oauth2-redirect.html`. |
| swagger.oidcProvider | string | `nil` | STIGMAN_SWAGGER_OIDC_PROVIDER. SwaggerUI override of the issuer URL. |

### Documentation

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| docs.disabled | string | `nil` | STIGMAN_DOCS_DISABLED. `true` stops the API serving the documentation. |
| docs.directory | string | `nil` | STIGMAN_DOCS_DIRECTORY. Location of the docs inside the image. |

### Logging, startup and extra configuration

| Key | Type | Default | Description |
| ----- | ------ | --------- | ------------- |
| logging.level | string | `nil` | STIGMAN_LOG_LEVEL. 1 (error) to 4 (debug). Upstream default: 3. |
| logging.mode | string | `nil` | STIGMAN_LOG_MODE. `combined` for one entry per request/response pair, `separate` for two. Upstream default: combined. |
| dependencyRetries | string | `nil` | STIGMAN_DEPENDENCY_RETRIES. Startup retries against MySQL and the OIDC provider before giving up. Upstream default: 24. |
| experimental.appData | string | `nil` | STIGMAN_EXPERIMENTAL_APPDATA. Enable the AppData import/export endpoints. |
| experimental.logStream | string | `nil` | STIGMAN_EXPERIMENTAL_LOGSTREAM. WebSocket log stream at /socket/. Upstream default: true. |
| dev.allowInsecureTokens | string | `nil` | STIGMAN_DEV_ALLOW_INSECURE_TOKENS. Accept known-insecure JWT signing keys. Development and testing only. |
| dev.responseValidation | string | `nil` | STIGMAN_DEV_RESPONSE_VALIDATION. `none` or `logOnly`. |
| dev.logOptStats | string | `nil` | STIGMAN_DEV_LOG_OPT_STATS. Track operation statistics for /op/appinfo. |
| extraConfig | object | `{}` | Raw STIGMAN_* passthrough, merged into the ConfigMap last and therefore able to override anything above. Use for variables this chart does not model yet. Keys must be the literal environment variable names. |

### Trusted CA certificates

| Key | Type | Default | Description |
| ----- | ------ | --------- | ------------- |
| trustedCAs.enabled | bool | `false` | Mount a CA bundle and point the application at it. |
| trustedCAs.certs | object | `{}` | Map of name → PEM. Concatenated in key order into one bundle file. |
| trustedCAs.existingConfigMap | string | `""` | Use an existing ConfigMap instead of `certs`. Mutually exclusive with `existingSecret`. |
| trustedCAs.existingSecret | string | `""` | Use an existing Secret instead of `certs`. Mutually exclusive with `existingConfigMap`. |
| trustedCAs.bundleKey | string | `"ca-bundle.pem"` | Key within the ConfigMap/Secret, and the file name once mounted. |
| trustedCAs.mountPath | string | `"/etc/stigman/ca"` | Directory the bundle is mounted into. |
| trustedCAs.setNodeExtraCaCerts | bool | `true` | Set NODE_EXTRA_CA_CERTS to the bundle (trust for all Node TLS clients). |
| trustedCAs.setOidcCaCerts | bool | `true` | Set STIGMAN_OIDC_CA_CERTS to the bundle (trust for OIDC calls only). |

### API TLS

| Key | Type | Default | Description |
| ----- | ------ | --------- | ------------- |
| tls.enabled | bool | `false` | Serve HTTPS directly from the API container. Requires `existingSecret`. |
| tls.existingSecret | string | `""` | Secret holding the server certificate and key. |
| tls.mountPath | string | `"/etc/stigman/tls"` | Where that Secret is mounted. |
| tls.certFile | string | `"tls.crt"` | STIGMAN_API_TLS_CERT_FILE. Key in the Secret holding the certificate. |
| tls.keyFile | string | `"tls.key"` | STIGMAN_API_TLS_KEY_FILE. Key in the Secret holding the private key. |
| tls.keyPassphrase | string | `""` | STIGMAN_API_TLS_KEY_PASSPHRASE, if the key is encrypted. |

### Service

| Key | Type | Default | Description |
| ----- | ------ | --------- | ------------- |
| service.type | string | `"ClusterIP"` | Service type. |
| service.port | int | `80` | Service port. |
| service.targetPort | string | `""` | Target port. Defaults to the container's named `http` port. |
| service.nodePort | string | `nil` | Node port, when `type` is NodePort. |
| service.clusterIP | string | `""` | Explicit clusterIP, or `None` for a headless Service. |
| service.loadBalancerIP | string | `""` | LoadBalancer IP request. |
| service.loadBalancerClass | string | `""` | LoadBalancer implementation class. |
| service.loadBalancerSourceRanges | list | `[]` | Source ranges permitted to reach a LoadBalancer Service. |
| service.externalTrafficPolicy | string | `""` | externalTrafficPolicy for NodePort/LoadBalancer Services. |
| service.sessionAffinity | string | `""` | Session affinity: None or ClientIP. |
| service.sessionAffinityConfig | object | `{}` | Session affinity tuning. |
| service.ipFamilyPolicy | string | `""` | IP family policy. |
| service.ipFamilies | list | `[]` | IP families. |
| service.annotations | object | `{}` | Extra Service annotations. |
| service.labels | object | `{}` | Extra Service labels. |
| service.extraPorts | list | `[]` | Additional Service ports, e.g. for a sidecar. |

### Ingress

| Key | Type | Default | Description |
| ----- | ------ | --------- | ------------- |
| ingress.enabled | bool | `false` | Create an Ingress. |
| ingress.className | string | `""` | ingressClassName. |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.labels | object | `{}` | Ingress labels. |
| ingress.hosts | list | `[{"host":"stig-manager.local","paths":[{"path":"/","pathType":"Prefix"}]}]` | Hosts and their paths. `host` is rendered through `tpl`. |
| ingress.tls | list | `[]` | TLS blocks. |
| ingress.extraRules | list | `[]` | Verbatim extra rules, appended to `rules`. Rendered through `tpl`. |
| ingress.extraTls | list | `[]` | Verbatim extra TLS blocks. Rendered through `tpl`. |

### NetworkPolicy

| Key | Type | Default | Description |
| ----- | ------ | --------- | ------------- |
| networkPolicy.enabled | bool | `false` | Create a NetworkPolicy for the API pod. |
| networkPolicy.allowAllIngress | bool | `false` | Accept ingress from anywhere on the API port. When false, only `allowedIngress` peers are accepted. |
| networkPolicy.allowedIngress | list | `[]` | Peers permitted to reach the API port: podSelector, namespaceSelector and/or ipBlock entries, exactly as the NetworkPolicy API expects them. |
| networkPolicy.extraIngressPorts | list | `[]` | Additional ports accepted alongside the API port. |
| networkPolicy.extraIngress | list | `[]` | Verbatim extra ingress rules. |
| networkPolicy.allowAllEgress | bool | `false` | Permit all egress instead of enumerating destinations. Simplest option when the OIDC provider lives outside the cluster. |
| networkPolicy.egress.dns | bool | `true` | Permit DNS to kube-dns. |
| networkPolicy.egress.database.enabled | bool | `true` | Permit egress to the database. |
| networkPolicy.egress.database.to | list | `[]` | Destination peers. Defaults to 0.0.0.0/0 on the database port. |
| networkPolicy.egress.database.port | string | `nil` | Destination port. Defaults to `database.port`. |
| networkPolicy.egress.extra | list | `[]` | Verbatim extra egress rules — the OIDC provider usually goes here. |

### Pod, container and scheduling

| Key | Type | Default | Description |
| ----- | ------ | --------- | ------------- |
| commonLabels | object | `{}` | Labels added to every object this chart renders. |
| commonAnnotations | object | `{}` | Annotations added to every object this chart renders. |
| deploymentAnnotations | object | `{}` | Annotations on the Deployment object itself (not the pod template). This is where controllers that watch Deployments read their configuration — Stakater Reloader, Argo CD sync options, Keel, and so on:    deploymentAnnotations:     reloader.stakater.com/auto: "true"  The chart already stamps checksum/config, checksum/secret and checksum/ca on the pod template, so config it owns rolls pods without Reloader. Reloader earns its keep for objects the chart references but does not render: `database.existingSecret`, `extraEnvVarsCM`, `extraEnvVarsSecret`, and `trustedCAs.existingConfigMap`/`existingSecret`. See the chart README. |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| priorityClassName | string | `""` | PriorityClass for the pod. |
| terminationGracePeriodSeconds | int | `30` | Grace period on pod termination. |
| nodeSelector | object | `{}` | Node selector. |
| tolerations | list | `[]` | Tolerations. |
| affinity | object | `{}` | Affinity rules. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. |
| dnsPolicy | string | `""` | Pod DNS policy. |
| dnsConfig | object | `{}` | Pod DNS config. |
| hostAliases | list | `[]` | Extra /etc/hosts entries. |
| command | list | `[]` | Override the image's entrypoint. The image runs `node index.js` from /home/node. |
| args | list | `[]` | Override the arguments. |
| lifecycle | object | `{}` | Container lifecycle hooks. |
| initContainers | list | `[]` | Init containers. Rendered through `tpl`. |
| sidecars | list | `[]` | Sidecar containers. Rendered through `tpl`. |
| extraContainerPorts | list | `[]` | Extra container ports on the API container. |
| resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"512Mi"}}` | Resource requests and limits. The API is a single Node process; give it enough memory for the STIG library it loads at startup. |
| podSecurityContext | object | `{"fsGroup":1000,"runAsGroup":1000,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod-level security context. |
| containerSecurityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true}` | Container-level security context. `readOnlyRootFilesystem: true` requires `tmpVolume.enabled` — Node writes its compile cache under /tmp. |
| tmpVolume.enabled | bool | `true` | Mount an emptyDir at /tmp. Node writes its compile cache there, so `containerSecurityContext.readOnlyRootFilesystem` depends on this. |
| tmpVolume.medium | string | `""` | emptyDir medium. Set to `Memory` for a tmpfs. |
| tmpVolume.sizeLimit | string | `"256Mi"` | Size limit for the emptyDir. |
| extraVolumes | list | `[]` | Extra volumes on the pod. Rendered through `tpl`. |
| extraVolumeMounts | list | `[]` | Extra volume mounts on the API container. Rendered through `tpl`. |
| extraEnvVarsCM | list | `[]` | Names of existing ConfigMaps to load wholesale as environment. |
| extraEnvVarsSecret | list | `[]` | Names of existing Secrets to load wholesale as environment. |
| extraEnvVars | list | `[]` | Extra environment variables in raw `env:` form. Applied last, so these win over everything else. Rendered through `tpl`. |

### Probes

| Key | Type | Default | Description |
| ----- | ------ | --------- | ------------- |
| startupProbe | object | `{"custom":{},"enabled":true,"failureThreshold":30,"initialDelaySeconds":0,"path":"/api/op/configuration","periodSeconds":10,"successThreshold":1,"timeoutSeconds":5}` | Startup probe. Targets /api/op/configuration, which reflects database and OIDC reachability. Set `custom` to replace the generated block entirely. |
| readinessProbe | object | `{"custom":{},"enabled":true,"failureThreshold":3,"initialDelaySeconds":10,"path":"/api/op/configuration","periodSeconds":10,"successThreshold":1,"timeoutSeconds":5}` | Readiness probe. Same target as the startup probe, so a pod that loses its database or IdP leaves the Service endpoints. |
| livenessProbe | object | `{"custom":{},"enabled":true,"failureThreshold":3,"initialDelaySeconds":15,"path":"/api/op/state","periodSeconds":20,"successThreshold":1,"timeoutSeconds":5}` | Liveness probe. Targets /api/op/state, which answers even while the API is still waiting on its dependencies — probing anything else would restart a pod that is merely waiting for MySQL. |

### Tests

| Key | Type | Default | Description |
| ----- | ------ | --------- | ------------- |
| tests.enabled | bool | `true` | Render the `helm test` pod. |
| tests.image | object | `{"pullPolicy":"IfNotPresent","repository":"curlimages/curl","tag":"8.11.1"}` | Image the test pod runs. Needs nothing but curl. |
| tests.timeout | int | `10` | curl timeout, in seconds. |
| tests.podSecurityContext | object | `{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod-level security context for the test pod. |
| tests.containerSecurityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container-level security context for the test pod. |
| tests.resources | object | `{}` | Resource requests and limits for the test pod. |

### Escape hatches

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| extraManifests | list | `[]` | Arbitrary manifests rendered alongside the chart's own. Each entry is passed through `tpl`, so Helm templating works inside. Use this for anything the chart deliberately does not model: Istio PeerAuthentication, Gateway API HTTPRoute, ExternalSecret, ServiceMonitor, and so on. |

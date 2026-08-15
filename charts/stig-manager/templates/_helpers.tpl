{{/*
Expand the name of the chart.
*/}}
{{- define "stig-manager.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this
(by the DNS naming spec).
*/}}
{{- define "stig-manager.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "stig-manager.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "stig-manager.labels" -}}
helm.sh/chart: {{ include "stig-manager.chart" . }}
{{ include "stig-manager.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: stig-manager
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "stig-manager.selectorLabels" -}}
app.kubernetes.io/name: {{ include "stig-manager.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Common annotations
*/}}
{{- define "stig-manager.annotations" -}}
{{- with .Values.commonAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Name of the ServiceAccount to use.
*/}}
{{- define "stig-manager.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "stig-manager.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the ConfigMap holding the STIGMAN_* environment.
*/}}
{{- define "stig-manager.configMapName" -}}
{{- printf "%s-env" (include "stig-manager.fullname" .) }}
{{- end }}

{{/*
Name of the Secret holding the database password and TLS key passphrases.
An externally managed Secret (database.existingSecret) always wins.
*/}}
{{- define "stig-manager.secretName" -}}
{{- .Values.database.existingSecret | default (printf "%s" (include "stig-manager.fullname" .)) }}
{{- end }}

{{/*
True when the chart should render its own Secret: no existingSecret was supplied
and at least one secret value was.
*/}}
{{- define "stig-manager.createSecret" -}}
{{- if .Values.database.existingSecret -}}
{{- else if or .Values.database.password .Values.database.tls.keyPassphrase .Values.tls.keyPassphrase -}}
true
{{- end -}}
{{- end }}

{{/*
Name of the ConfigMap holding the trusted CA bundle (empty when the bundle comes
from a Secret instead).
*/}}
{{- define "stig-manager.caConfigMapName" -}}
{{- if .Values.trustedCAs.existingConfigMap -}}
{{- .Values.trustedCAs.existingConfigMap -}}
{{- else if not .Values.trustedCAs.existingSecret -}}
{{- printf "%s-ca" (include "stig-manager.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
True when the chart should render its own CA ConfigMap.
*/}}
{{- define "stig-manager.createCAConfigMap" -}}
{{- if and .Values.trustedCAs.enabled .Values.trustedCAs.certs (not .Values.trustedCAs.existingConfigMap) (not .Values.trustedCAs.existingSecret) -}}
true
{{- end -}}
{{- end }}

{{/*
True when a CA bundle volume should be mounted at all.
*/}}
{{- define "stig-manager.caEnabled" -}}
{{- if and .Values.trustedCAs.enabled (or .Values.trustedCAs.certs .Values.trustedCAs.existingConfigMap .Values.trustedCAs.existingSecret) -}}
true
{{- end -}}
{{- end }}

{{/*
Absolute path of the mounted CA bundle. Both NODE_EXTRA_CA_CERTS and
STIGMAN_OIDC_CA_CERTS accept exactly one file, hence the single bundle.
*/}}
{{- define "stig-manager.caBundlePath" -}}
{{- printf "%s/%s" (trimSuffix "/" .Values.trustedCAs.mountPath) .Values.trustedCAs.bundleKey }}
{{- end }}

{{/*
The container image reference.
*/}}
{{- define "stig-manager.image" -}}
{{- $registry := .Values.image.registry -}}
{{- $repository := .Values.image.repository -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if .Values.image.digest -}}
{{- if $registry -}}
{{- printf "%s/%s@%s" $registry $repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s@%s" $repository .Values.image.digest -}}
{{- end -}}
{{- else -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry $repository $tag -}}
{{- else -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
The port the API container listens on. api.port is authoritative; it is also
published to the container as STIGMAN_API_PORT via the ConfigMap.
*/}}
{{- define "stig-manager.containerPort" -}}
{{- .Values.api.port | default 54000 }}
{{- end }}

{{/*
Inline environment variables for the API container, in precedence order.
Rendered after envFrom, so these win over the ConfigMap/Secret refs. Anything in
.Values.extraEnvVars is appended by the Deployment after this block and wins
outright.
*/}}
{{- define "stig-manager.env" -}}
{{- if or .Values.database.password .Values.database.existingSecret }}
- name: STIGMAN_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "stig-manager.secretName" . }}
      key: {{ .Values.database.secretKeys.password }}
{{- end }}
{{- if include "stig-manager.caEnabled" . }}
{{- if .Values.trustedCAs.setNodeExtraCaCerts }}
- name: NODE_EXTRA_CA_CERTS
  value: {{ include "stig-manager.caBundlePath" . | quote }}
{{- end }}
{{- if .Values.trustedCAs.setOidcCaCerts }}
- name: STIGMAN_OIDC_CA_CERTS
  value: {{ include "stig-manager.caBundlePath" . | quote }}
{{- end }}
{{- end }}
{{- if .Values.database.tls.enabled }}
{{- $dbTlsPath := trimSuffix "/" .Values.database.tls.mountPath }}
{{- with .Values.database.tls.caFile }}
- name: STIGMAN_DB_TLS_CA_FILE
  value: {{ printf "%s/%s" $dbTlsPath . | quote }}
{{- end }}
{{- with .Values.database.tls.certFile }}
- name: STIGMAN_DB_TLS_CERT_FILE
  value: {{ printf "%s/%s" $dbTlsPath . | quote }}
{{- end }}
{{- with .Values.database.tls.keyFile }}
- name: STIGMAN_DB_TLS_KEY_FILE
  value: {{ printf "%s/%s" $dbTlsPath . | quote }}
{{- end }}
{{- end }}
{{- if .Values.tls.enabled }}
{{- $tlsPath := trimSuffix "/" .Values.tls.mountPath }}
- name: STIGMAN_API_TLS_CERT_FILE
  value: {{ printf "%s/%s" $tlsPath .Values.tls.certFile | quote }}
- name: STIGMAN_API_TLS_KEY_FILE
  value: {{ printf "%s/%s" $tlsPath .Values.tls.keyFile | quote }}
{{- if or .Values.tls.keyPassphrase .Values.database.existingSecret }}
{{- if .Values.database.secretKeys.apiTlsKeyPassphrase }}
{{- /* STIGMAN_API_TLS_KEY_PASSPHRASE is optional: the referenced key need not exist. */}}
- name: STIGMAN_API_TLS_KEY_PASSPHRASE
  valueFrom:
    secretKeyRef:
      name: {{ include "stig-manager.secretName" . }}
      key: {{ .Values.database.secretKeys.apiTlsKeyPassphrase }}
      optional: true
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Scheme used by probes and the helm test: HTTPS once the API terminates TLS itself.
*/}}
{{- define "stig-manager.probeScheme" -}}
{{- if .Values.tls.enabled }}HTTPS{{ else }}HTTP{{ end }}
{{- end }}

{{/*
Validate mutually exclusive / required inputs early with a readable message.
*/}}
{{- define "stig-manager.validateValues" -}}
{{- if and .Values.trustedCAs.existingConfigMap .Values.trustedCAs.existingSecret -}}
{{- fail "trustedCAs.existingConfigMap and trustedCAs.existingSecret are mutually exclusive" -}}
{{- end -}}
{{- if and .Values.tls.enabled (not .Values.tls.existingSecret) -}}
{{- fail "tls.enabled requires tls.existingSecret holding the API server certificate and key" -}}
{{- end -}}
{{- if and .Values.database.tls.enabled (not .Values.database.tls.existingSecret) -}}
{{- fail "database.tls.enabled requires database.tls.existingSecret holding the database TLS material" -}}
{{- end -}}
{{- end }}

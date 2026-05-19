{{/*
Common labels
*/}}
{{- define "maichess.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: maichess
{{- end }}

{{/*
Selector labels for a component
*/}}
{{- define "maichess.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .releaseName }}
{{- end }}

{{/*
Build a full image reference: ghcr.io/maichess/maichess-<name>:<tag>
Usage: {{ include "maichess.image" (dict "name" "user-service" "tag" .Values.services.userService.tag "global" .Values.global) }}
*/}}
{{- define "maichess.image" -}}
{{ .global.imageRegistry }}/maichess-{{ .name }}:{{ .tag | default "main" }}
{{- end }}

{{/*
Common OTEL environment variables — include in every app service
*/}}
{{- define "maichess.otelEnv" -}}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://otel-collector:4317"
{{- end }}

{{/*
Environment value from secret
Usage: {{ include "maichess.secretRef" (dict "secret" "maichess-app-secrets" "key" "jwt-secret") }}
*/}}
{{- define "maichess.secretRef" -}}
valueFrom:
  secretKeyRef:
    name: {{ .secret }}
    key: {{ .key }}
{{- end }}

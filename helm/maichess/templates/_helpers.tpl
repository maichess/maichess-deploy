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
Common Kafka environment variables — include in every app service so producers
and consumers can reach the broker. Events are raw Protobuf bytes (Kafka task 09
removed the Schema Registry). Harmless for services that do not use Kafka.
*/}}
{{- define "maichess.kafkaEnv" -}}
- name: KAFKA_BOOTSTRAP
  value: {{ .Values.kafka.bootstrap | default "kafka:9092" | quote }}
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

{{/*
Node affinity: pin to the primary node (maichess/role=primary)
*/}}
{{- define "maichess.affinityPrimary" -}}
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
      - matchExpressions:
          - key: maichess/role
            operator: In
            values:
              - primary
{{- end }}

{{/*
Toleration + soft affinity for burst-eligible services.
Prefers the primary node but tolerates scheduling on the burst node.
*/}}
{{- define "maichess.affinityBurstEligible" -}}
nodeAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 80
      preference:
        matchExpressions:
          - key: maichess/role
            operator: In
            values:
              - primary
{{- end }}

{{- define "maichess.tolerationBurst" -}}
key: maichess/role
operator: Equal
value: burst
effect: NoSchedule
{{- end }}

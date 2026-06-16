{{/*
Generic Deployment template for maichess application services.

Usage:
  {{ include "maichess.app.deployment" (dict
    "name" "user-service"
    "image" "ghcr.io/maichess/maichess-user-service:main"
    "ports" (list (dict "containerPort" 8080 "name" "http"))
    "env" .Values.services.userService.env
    "extraEnv" (list)
    "volumes" (list)
    "volumeMounts" (list)
    "securityContext" (dict)
    "Release" .Release
    "Chart" .Chart
    "Values" .Values
  ) }}
*/}}
{{- define "maichess.app.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .name }}
  labels:
    {{- include "maichess.labels" . | nindent 4 }}
    app.kubernetes.io/component: {{ .name }}
    maichess.io/container-update: "true"
spec:
  replicas: {{ .replicas | default 1 }}
  # Zero-surge rolling update. The k8s default (maxSurge 25% / maxUnavailable 25%)
  # rounds maxUnavailable DOWN to 0 at replicas=1, so a new pod must schedule before
  # the old one is allowed to terminate. On a resource-constrained single node the
  # new pod stays Pending (no spare CPU/RAM), the old pod never terminates, and
  # `kubectl rollout status` blocks until its timeout — the "old pods won't shut
  # down / deploy hangs" failure. maxSurge:0 + maxUnavailable:1 frees the old pod's
  # resources FIRST, then schedules the new one. Accepts brief downtime per service
  # (fine here, not yet live); override per-service via the macro if needed.
  strategy:
    type: {{ .strategyType | default "RollingUpdate" }}
    {{- if ne (.strategyType | default "RollingUpdate") "Recreate" }}
    rollingUpdate:
      maxSurge: {{ .maxSurge | default 0 }}
      maxUnavailable: {{ .maxUnavailable | default 1 }}
    {{- end }}
  selector:
    matchLabels:
      app.kubernetes.io/component: {{ .name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/component: {{ .name }}
        maichess.io/container-update: "true"
    spec:
      {{- if .serviceAccountName }}
      serviceAccountName: {{ .serviceAccountName }}
      {{- end }}
      imagePullSecrets:
        - name: ghcr-pull-secret
      containers:
        - name: {{ .name }}
          image: {{ .image }}
          imagePullPolicy: {{ .Values.global.imagePullPolicy }}
          {{- if .ports }}
          ports:
            {{- toYaml .ports | nindent 12 }}
          {{- end }}
          env:
            {{- include "maichess.otelEnv" . | nindent 12 }}
            {{- if .Values.kafka.enabled }}
            {{- include "maichess.kafkaEnv" . | nindent 12 }}
            {{- end }}
            {{- if .env }}
            {{- toYaml .env | nindent 12 }}
            {{- end }}
            {{- if .extraEnv }}
            {{- toYaml .extraEnv | nindent 12 }}
            {{- end }}
          {{- if .probePort }}
          readinessProbe:
            tcpSocket:
              port: {{ .probePort }}
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            tcpSocket:
              port: {{ .probePort }}
            initialDelaySeconds: 15
            periodSeconds: 20
            failureThreshold: 3
          {{- end }}
          {{- if .resources }}
          resources:
            {{- toYaml .resources | nindent 12 }}
          {{- end }}
          {{- if .volumeMounts }}
          volumeMounts:
            {{- toYaml .volumeMounts | nindent 12 }}
          {{- end }}
      {{- if .volumes }}
      volumes:
        {{- toYaml .volumes | nindent 8 }}
      {{- end }}
      {{- if .securityContext }}
      securityContext:
        {{- toYaml .securityContext | nindent 8 }}
      {{- end }}
      {{- if .affinity }}
      affinity:
        {{- toYaml .affinity | nindent 8 }}
      {{- end }}
      {{- if .tolerations }}
      tolerations:
        {{- toYaml .tolerations | nindent 8 }}
      {{- end }}
{{- end -}}

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
spec:
  replicas: {{ .replicas | default 1 }}
  selector:
    matchLabels:
      app.kubernetes.io/component: {{ .name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/component: {{ .name }}
    spec:
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
            {{- if .env }}
            {{- toYaml .env | nindent 12 }}
            {{- end }}
            {{- if .extraEnv }}
            {{- toYaml .extraEnv | nindent 12 }}
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
{{- end -}}

{{/*
Generic Service template for maichess application services.

Usage:
  {{ include "maichess.app.service" (dict
    "name" "user-service"
    "ports" (list (dict "port" 8080 "targetPort" 8080 "name" "http"))
  ) }}
*/}}
{{- define "maichess.app.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/component: {{ .name }}
  ports:
    {{- toYaml .ports | nindent 4 }}
{{- end -}}

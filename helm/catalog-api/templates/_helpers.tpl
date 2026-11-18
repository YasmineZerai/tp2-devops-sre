{{- define "catalog-api.labels" -}}
app.kubernetes.io/name: catalog-api
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "boat-backend.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- range $key, $value := .Values.commonLabels }}
{{ $key }}: {{ $value | quote }}
{{- end }}
app.kubernetes.io/environment: {{ .Values.environment | quote }}
{{- end }}

{{- define "boat-backend.selectorLabels" -}}
app.kubernetes.io/name: {{ .name | quote }}
{{- end }}

{{- define "boat-backend.backendName" -}}
{{- .Values.backend.name -}}
{{- end }}

{{- define "boat-backend.postgresqlName" -}}
{{- .Values.postgresql.name -}}
{{- end }}

{{- define "boat-backend.migrationName" -}}
{{- .Values.migration.name -}}
{{- end }}

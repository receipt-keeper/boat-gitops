{{- define "boatlab.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- range $key, $value := .Values.commonLabels }}
{{ $key }}: {{ $value | quote }}
{{- end }}
app.kubernetes.io/environment: {{ .Values.environment | quote }}
{{- end }}

{{- define "boatlab.selectorLabels" -}}
app.kubernetes.io/name: {{ .name | quote }}
{{- end }}

{{- define "boatlab.backendName" -}}
{{- .Values.backend.name -}}
{{- end }}

{{- define "boatlab.postgresqlName" -}}
{{- .Values.postgresql.name -}}
{{- end }}

{{- define "boatlab.migrationName" -}}
{{- .Values.migration.name -}}
{{- end }}

{{- define "boatlab.pushNotificationSchedulerName" -}}
{{- .Values.pushNotificationScheduler.name -}}
{{- end }}

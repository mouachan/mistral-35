{{- define "mistral.fullname" -}}
{{- .Values.model.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mistral.labels" -}}
app.kubernetes.io/name: {{ include "mistral.fullname" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: mistral-medium-3-5
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

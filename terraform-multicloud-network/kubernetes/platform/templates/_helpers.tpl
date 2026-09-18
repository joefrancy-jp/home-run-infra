{{- define "platform.namespaces" -}}
{{- if eq .Values.environment "dev" -}}dev,qa
{{- else if has .Values.environment (list "uat" "prod") -}}{{ .Values.environment }}
{{- else -}}{{ fail "environment must be dev, uat, or prod" }}{{- end -}}
{{- end -}}

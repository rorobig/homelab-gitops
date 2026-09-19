{{- define "solo-agent-gateway.fullname" -}}
{{- printf "%s-agent" .Release.Name | trunc 63 -}}
{{- end -}}

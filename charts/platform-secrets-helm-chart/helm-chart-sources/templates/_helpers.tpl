{{/*
Generate ExternalSecret resources for a single secret definition.
Usage: include "platform-secrets.externalSecret" (dict "secret" $secret "root" .)
*/}}
{{- define "platform-secrets.externalSecret" -}}
{{- $secret := .secret -}}
{{- $root := .root -}}
{{- if and $secret.enabled $secret.namespaces -}}
{{- range $secret.namespaces }}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ $secret.name }}
  namespace: {{ . }}
  labels:
    app.kubernetes.io/managed-by: platform-secrets
spec:
  refreshInterval: {{ $root.Values.refreshInterval }}
  secretStoreRef:
    name: {{ ($secret.secretStoreRef).name | default $root.Values.secretStoreRef.name }}
    kind: {{ ($secret.secretStoreRef).kind | default $root.Values.secretStoreRef.kind }}
  target:
    name: {{ $secret.name }}
    {{- if $secret.secretType }}
    template:
      type: {{ $secret.secretType }}
    {{- end }}
  data:
    {{- range $secret.remoteRefs }}
    - secretKey: {{ .secretKey }}
      remoteRef:
        key: {{ .remoteKey }}
        {{- if .property }}
        property: {{ .property }}
        {{- end }}
    {{- end }}
{{- end }}
{{- end }}
{{- end }}

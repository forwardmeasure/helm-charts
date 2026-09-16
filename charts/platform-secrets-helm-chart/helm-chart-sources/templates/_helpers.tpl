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
    {{- if or $secret.secretType $secret.templateData }}
    template:
      {{- if $secret.secretType }}
      type: {{ $secret.secretType }}
      {{- end }}
      {{- if $secret.templateData }}
      # Composes one or more target Secret fields from multiple fetched remoteRefs (each
      # available by its own secretKey alias, e.g. {{ "{{ .server }}" }}) instead of a single
      # remoteRef being copied verbatim - used when the remote store holds a secret's real parts
      # separately (e.g. a registry's server/auth pair) rather than one pre-assembled blob
      # (e.g. a full .dockerconfigjson). External Secrets Operator evaluates these as real Go
      # templates at sync time - the {{ "{{ }}" }} markers below are meant to survive Helm
      # rendering unevaluated, not be filled in by this chart.
      data:
        {{- range $key, $value := $secret.templateData }}
        {{ $key | quote }}: {{ $value | quote }}
        {{- end }}
      {{- end }}
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

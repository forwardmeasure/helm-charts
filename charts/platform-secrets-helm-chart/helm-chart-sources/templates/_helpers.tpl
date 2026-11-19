{{/*
Generate ExternalSecret resources for a single secret definition.
Usage: include "platform-secrets.externalSecret" (dict "secret" $secret "root" .)
*/}}
{{- define "platform-secrets.externalSecret" -}}
{{- $secret := .secret -}}
{{- $root := .root -}}
{{- if and $secret.enabled $secret.namespaces -}}
{{- range $secret.namespaces }}
{{- /* What this Secret's content is made of (credentialFingerprints.<namespace>.<name>, see
values.yaml): it changes exactly when the content does, so a Helm upgrade that changes the content
changes this ExternalSecret, and External Secrets Operator synchronizes it at once instead of at
its next refresh. */}}
{{- $fingerprint := dig . $secret.name "" ($root.Values.credentialFingerprints | default dict) }}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ $secret.name }}
  namespace: {{ . }}
  labels:
    app.kubernetes.io/managed-by: platform-secrets
    {{- if $secret.identityClientCredentials }}
    platform.forwardmeasure.com/identity-client-credentials: "true"
    {{- end }}
  {{- if $fingerprint }}
  annotations:
    platform.forwardmeasure.com/credential-fingerprint: {{ $fingerprint | quote }}
  {{- end }}
spec:
  refreshInterval: {{ $root.Values.refreshInterval }}
  secretStoreRef:
    name: {{ ($secret.secretStoreRef).name | default $root.Values.secretStoreRef.name }}
    kind: {{ ($secret.secretStoreRef).kind | default $root.Values.secretStoreRef.kind }}
  target:
    name: {{ $secret.name }}
    {{- if or $secret.secretType $secret.templateData $fingerprint }}
    template:
      {{- if $fingerprint }}
      # The same fingerprint on the Secret proves which content it holds. A template with
      # metadata and no data keeps ordinary spec.data as it is.
      metadata:
        annotations:
          platform.forwardmeasure.com/credential-fingerprint: {{ $fingerprint | quote }}
      {{- end }}
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

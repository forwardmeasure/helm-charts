{{- define "docling-serve.preparationContainer" -}}
image: {{ include "docling-serve.preparationImage" . | quote }}
imagePullPolicy: {{ (index .Values.modelDownload.image (ternary "cpu" .Values.mode .Values.modelDownload.useCpuImage)).pullPolicy }}
command: [python, -B, /scripts/model-preparation.py]
args:
  - prepare
  - --config
  - /scripts/models.json
  - --cache
  - {{ .Values.paths.models | quote }}
  - --bundled
  - {{ .Values.paths.imageModels | quote }}
  - --staging
  - /tmp/hf-staging
  - --lock-timeout
  - {{ .Values.modelDownload.lockTimeoutSeconds | quote }}
env:
  - {name: HF_HOME, value: /tmp/hf-staging/hf-home}
  - {name: HF_HUB_CACHE, value: /tmp/hf-staging/hf-home/hub}
  {{- if .Values.hfToken.secretName }}
  - name: HF_TOKEN
    valueFrom:
      secretKeyRef: {name: {{ .Values.hfToken.secretName | quote }}, key: {{ .Values.hfToken.secretKey | quote }}}
  {{- end }}
securityContext:
  {{- toYaml .Values.securityContext | nindent 2 }}
resources:
  {{- toYaml (index .Values.modelDownload.resources (ternary "cpu" .Values.mode .Values.modelDownload.useCpuImage)) | nindent 2 }}
volumeMounts:
  - {name: model-cache, mountPath: {{ .Values.paths.models | quote }}}
  - {name: model-download-lib, mountPath: /scripts, readOnly: true}
  - {name: hf-download-staging, mountPath: /tmp/hf-staging}
  - {name: temporary, mountPath: /tmp}
{{- end -}}

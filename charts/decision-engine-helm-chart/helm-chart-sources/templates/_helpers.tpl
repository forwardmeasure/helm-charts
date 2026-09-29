# Licensed to the Apache Software Foundation (ASF) under one or more contributor license
# agreements. See the NOTICE file distributed with this work for additional information
# regarding copyright ownership. The ASF licenses this file to You under the Apache License,
# Version 2.0 (the "License"); you may not use this file except in compliance with the License.
# You may obtain a copy of the License at https://www.apache.org/licenses/LICENSE-2.0
{{/*
  Licensed to the Apache Software Foundation (ASF) under one or more contributor license
  agreements. See the NOTICE file distributed with this work for additional information.
  The ASF licenses this file under the Apache License, Version 2.0.
*/}}
{{- define "decision-engine.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "decision-engine.fullname" -}}
{{- if .Values.fullnameOverride -}}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}{{- else -}}{{ include "decision-engine.name" . }}{{- end -}}
{{- end -}}
{{- define "decision-engine.labels" -}}
app.kubernetes.io/name: {{ include "decision-engine.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
{{- define "decision-engine.serviceAccountName" -}}
{{- default (include "decision-engine.fullname" .) .Values.serviceAccount.name -}}
{{- end -}}

{{/*
Cloud SQL Auth Proxy instance-connection-name Secret. Same resolution as
java-microservice-helm-chart's cloudSqlProxySecretName: existingSecretName is used verbatim;
otherwise secretName is release-scoped (<release>-<secretName>).
*/}}
{{- define "decision-engine.cloudSqlProxySecretName" -}}
{{- if .Values.cloudSqlProxy.existingSecretName -}}
{{- .Values.cloudSqlProxy.existingSecretName -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (required "cloudSqlProxy.secretName or cloudSqlProxy.existingSecretName is required when cloudSqlProxy.enabled" .Values.cloudSqlProxy.secretName) -}}
{{- end -}}
{{- end -}}

{{/*
Cloud SQL Auth Proxy, rendered as a native sidecar (initContainer with restartPolicy: Always) so it
is listening on localhost before both the optional database-migration init container and the
decision-engine container start. The instance connection name is Secret-key-only, matching
java-microservice-helm-chart (see its values.yaml "deliberately still Secret-key-only" comment).
*/}}
{{- define "decision-engine.cloudSqlProxySidecar" -}}
{{- $proxy := .Values.cloudSqlProxy -}}
- name: cloud-sql-proxy
  image: "{{ $proxy.image.repository }}{{ if $proxy.image.digest }}@{{ $proxy.image.digest }}{{ else }}:{{ $proxy.image.tag }}{{ end }}"
  imagePullPolicy: {{ $proxy.image.pullPolicy | default "IfNotPresent" }}
  restartPolicy: Always
  args:
    - "--structured-logs"
    - "--port={{ $proxy.port | default 5432 }}"
    {{- if $proxy.privateIp }}
    - "--private-ip"
    {{- end }}
    - "$(DECISION_ENGINE_DB_CLOUD_SQL_INSTANCE)"
  env:
    - name: DECISION_ENGINE_DB_CLOUD_SQL_INSTANCE
      valueFrom:
        secretKeyRef:
          name: {{ include "decision-engine.cloudSqlProxySecretName" . }}
          key: {{ $proxy.instanceKey | default "db-cloud-sql-instance" }}
  resources:
    {{- toYaml $proxy.resources | nindent 4 }}
  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: [ALL]
{{- end -}}

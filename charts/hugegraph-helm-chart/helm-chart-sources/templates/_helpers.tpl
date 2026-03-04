{{- define "hugegraph.name" -}}hugegraph{{- end }}
{{- define "hugegraph.fullname" -}}hugegraph{{- end }}

{{- define "hugegraph.labels" -}}
app.kubernetes.io/name: {{ include "hugegraph.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "hugegraph.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hugegraph.name" . }}
{{- end }}

{{/* Comma-separated PD gRPC DNS list for pd.peers in hugegraph.properties */}}
{{- define "hugegraph.pdGrpcPeers" -}}
{{- $ns := .Release.Namespace -}}
{{- $port := int .Values.pd.ports.grpc -}}
{{- $peers := list -}}
{{- range $i, $e := until (int .Values.pd.replicaCount) -}}
  {{- $peers = append $peers (printf "hugegraph-pd-%d.hugegraph-pd.%s.svc.cluster.local:%d" $i $ns $port) -}}
{{- end -}}
{{- join "," $peers -}}
{{- end }}

{{/* Comma-separated PD Raft peer list for pd raft.peers-list */}}
{{- define "hugegraph.pdRaftPeers" -}}
{{- $ns := .Release.Namespace -}}
{{- $port := int .Values.pd.ports.raft -}}
{{- $peers := list -}}
{{- range $i, $e := until (int .Values.pd.replicaCount) -}}
  {{- $peers = append $peers (printf "hugegraph-pd-%d.hugegraph-pd.%s.svc.cluster.local:%d" $i $ns $port) -}}
{{- end -}}
{{- join "," $peers -}}
{{- end }}

{{/* Comma-separated Store gRPC list for pd.initial-store-list */}}
{{- define "hugegraph.storeGrpcList" -}}
{{- $ns := .Release.Namespace -}}
{{- $port := int .Values.store.ports.grpc -}}
{{- $peers := list -}}
{{- range $i, $e := until (int .Values.store.replicaCount) -}}
  {{- $peers = append $peers (printf "hugegraph-store-%d.hugegraph-store.%s.svc.cluster.local:%d" $i $ns $port) -}}
{{- end -}}
{{- join "," $peers -}}
{{- end }}

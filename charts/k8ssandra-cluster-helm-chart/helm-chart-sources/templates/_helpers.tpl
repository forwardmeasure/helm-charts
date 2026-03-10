{{- define "k8ssandra.cassandraServerImage" -}}
{{- if and .Values.cassandra.serverImage .Values.cassandra.serverImage.enabled -}}
  {{- if .Values.cassandra.serverImage.name -}}
    {{- .Values.cassandra.serverImage.name -}}
  {{- else -}}
    {{- printf "%s/%s:%s" .Values.cassandra.serverImage.registry .Values.cassandra.serverImage.repository .Values.cassandra.serverImage.tag -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- define "k8ssandra.renderGeneratedRacks" -}}
{{- $dc := .dc -}}
{{- $root := .root -}}
{{- $size := int $dc.size -}}
{{- $rackCount := int ($dc.rackCount | default $size) -}}
{{- $rt := $root.Values.cassandra.rackTemplate | default dict -}}
{{- $namePrefix := get $rt "namePrefix" | default "rack" -}}
{{- $startAt := int (get $rt "startAt" | default 1) -}}

{{- if lt $size 1 -}}
  {{- fail (printf "datacenter %q: size must be at least 1" $dc.name) -}}
{{- end -}}
{{- if lt $rackCount 1 -}}
  {{- fail (printf "datacenter %q: rackCount must be at least 1" $dc.name) -}}
{{- end -}}
{{- if gt $rackCount $size -}}
  {{- fail (printf "datacenter %q: rackCount (%d) cannot be greater than size (%d)" $dc.name $rackCount $size) -}}
{{- end -}}

racks:
{{- range $i, $_ := until $rackCount }}
  - name: {{ printf "%s%d" $namePrefix (add $startAt $i) | quote }}
{{- end }}
{{- end -}}
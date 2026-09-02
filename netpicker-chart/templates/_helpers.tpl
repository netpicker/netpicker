{{/*
Expand the name of the chart.
*/}}
{{- define "netpicker.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "netpicker.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "netpicker.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "netpicker.labels" -}}
helm.sh/chart: {{ include "netpicker.chart" . }}
{{ include "netpicker.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "netpicker.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netpicker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "netpicker.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "netpicker.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the proper image name
*/}}
{{- define "netpicker.image" -}}
{{- $registryName := .global.imageRegistry -}}
{{- $repositoryName := .image.repository -}}
{{- $tag := .image.tag | toString -}}
{{- if $registryName -}}
    {{- printf "%s/%s:%s" $registryName $repositoryName $tag -}}
{{- else -}}
    {{- printf "%s:%s" $repositoryName $tag -}}
{{- end -}}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "netpicker.imagePullSecrets" -}}
{{- if .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.global.imagePullSecrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Create a default fully qualified app name for database
*/}}
{{- define "netpicker.db.fullname" -}}
{{- printf "db" -}}
{{- end -}}

{{/*
Create a default fully qualified app name for redis
*/}}
{{- define "netpicker.redis.fullname" -}}
{{- printf "redis" -}}
{{- end -}}

{{/*
Create a default fully qualified app name for api
*/}}
{{- define "netpicker.api.fullname" -}}
{{- printf "api" -}}
{{- end -}}

{{/*
Create a default fully qualified app name for celery
*/}}
{{- define "netpicker.celery.fullname" -}}
{{- printf "celery" -}}
{{- end -}}

{{/*
Create a default fully qualified app name for gitd
*/}}
{{- define "netpicker.gitd.fullname" -}}
{{- printf "gitd" -}}
{{- end -}}

{{/*
Create a default fully qualified app name for gitdctrl
*/}}
{{- define "netpicker.gitdctrl.fullname" -}}
{{- printf "gitdctrl" -}}
{{- end -}}

{{/*
Create a default fully qualified app name for swagger
*/}}
{{- define "netpicker.swagger.fullname" -}}
{{- printf "swagger" -}}
{{- end -}}

{{/*
Create a default fully qualified app name for frontend
*/}}
{{- define "netpicker.frontend.fullname" -}}
{{- printf "frontend" -}}
{{- end -}}

{{/*
Create a default fully qualified app name for kibbitzer
*/}}
{{- define "netpicker.kibbitzer.fullname" -}}
{{- printf "kibbitzer" -}}
{{- end -}}

{{/*
Create a default fully qualified app name for agent
*/}}
{{- define "netpicker.agent.fullname" -}}
{{- printf "agent" -}}
{{- end -}}

{{/*
Create a default fully qualified app name for syslog-ng
*/}}
{{- define "netpicker.syslogng.fullname" -}}
{{- printf "syslogng" -}}
{{- end -}}

{{/*
Pod volumes for the persistent claims.
Each one gives the claim when its persistence is on and an emptyDir when it
is off, so a pod never references a claim that the chart does not make.
*/}}
{{- define "netpicker.volume.dcVol" -}}
- name: dc-vol
{{- if .Values.persistence.dcVol.enabled }}
  persistentVolumeClaim:
    claimName: {{ include "netpicker.fullname" . }}-dc-vol
{{- else }}
  emptyDir: {}
{{- end }}
{{- end -}}

{{- define "netpicker.volume.secret" -}}
- name: secret
{{- if .Values.persistence.secret.enabled }}
  persistentVolumeClaim:
    claimName: {{ include "netpicker.fullname" . }}-secret
{{- else }}
  emptyDir: {}
{{- end }}
{{- end -}}

{{- define "netpicker.volume.transferium" -}}
- name: transferium
{{- if .Values.persistence.transferium.enabled }}
  persistentVolumeClaim:
    claimName: {{ include "netpicker.fullname" . }}-transferium
{{- else }}
  emptyDir: {}
{{- end }}
{{- end -}}

{{- define "netpicker.volume.policyData" -}}
- name: policy-data
{{- if .Values.api.persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ include "netpicker.api.fullname" . }}-data
{{- else }}
  emptyDir: {}
{{- end }}
{{- end -}}

{{- define "netpicker.volume.git" -}}
- name: git
{{- if .Values.gitd.persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ include "netpicker.gitd.fullname" . }}-data
{{- else }}
  emptyDir: {}
{{- end }}
{{- end -}}

{{- define "netpicker.volume.redisData" -}}
- name: data
{{- if .Values.redis.persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ include "netpicker.redis.fullname" . }}-data
{{- else }}
  emptyDir: {}
{{- end }}
{{- end -}}

{{- define "netpicker.volume.syslogngData" -}}
- name: data
{{- if .Values.syslogng.persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ include "netpicker.syslogng.fullname" . }}-data
{{- else }}
  emptyDir: {}
{{- end }}
{{- end -}}

{{/*
Return the storage class for a claim.
Call it with a dict that holds "ctx", the root context, and "override", the
storage class of that one volume. The override wins. If the override is
empty, the helper gives global.storageClass. If both are empty, the helper
gives an empty string and the claim keeps no storageClassName field. The
cluster default storage class then applies.

The RWO claims and the RWX claims can need different classes. Longhorn
serves both access modes from one class, but Ceph and NetApp Trident do not:
the block driver serves ReadWriteOnce and the file driver serves
ReadWriteMany. Each claim therefore has its own override.
*/}}
{{- define "netpicker.storageClass" -}}
{{- default .ctx.Values.global.storageClass .override -}}
{{- end -}}

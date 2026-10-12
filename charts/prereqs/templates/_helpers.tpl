{{/*
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc.
SPDX-License-Identifier: Apache-2.0
*/}}

{{- define "dsx-ai-factory-prereqs.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: dsx-ai-factory
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
OCP CLI image for hook Jobs.

Resolution order:
  1. .Values.ocpCliImage if explicitly set (non-empty)
  2. Cluster version discovered via Helm lookup (requires live cluster access):
       quay.io/openshift/origin-cli:<major>.<minor>
  3. Fallback: quay.io/openshift/origin-cli:latest

Override ocpCliImage in values.yaml for air-gapped clusters pointing to a
mirror registry, or to pin a specific digest.
*/}}
{{- define "dsx-ai-factory-prereqs.ocpCliImage" -}}
{{- if .Values.ocpCliImage }}
{{- .Values.ocpCliImage }}
{{- else }}
{{- $cv := lookup "config.openshift.io/v1" "ClusterVersion" "" "version" }}
{{- if and $cv $cv.status $cv.status.desired $cv.status.desired.version }}
{{- $full := $cv.status.desired.version }}
{{- $minor := regexFind "^[0-9]+\\.[0-9]+" $full }}
{{- printf "quay.io/openshift/origin-cli:%s" $minor }}
{{- else }}
{{- "quay.io/openshift/origin-cli:latest" }}
{{- end }}
{{- end }}
{{- end }}

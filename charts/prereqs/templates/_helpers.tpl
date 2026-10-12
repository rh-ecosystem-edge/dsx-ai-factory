{{/*
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc.
SPDX-License-Identifier: Apache-2.0
*/}}

{{- define "dsx-ai-factory-prereqs.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: dsx-ai-factory
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

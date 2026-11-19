[[- /* ---------- validation: fail the render instead of deploying something unsafe ---------- */ -]]
[[- define "validate" -]]
[[- if eq (var "server_group" .) "" -]][[ fail "server_group must be set (one job per server group)" ]][[- end -]]
[[- if not (or (eq (var "component" .) "be") (eq (var "component" .) "fe")) -]][[ fail "component must be \"be\" or \"fe\"" ]][[- end -]]
[[- if not (or (eq (var "rollout_mode" .) "server") (eq (var "rollout_mode" .) "group")) -]][[ fail "rollout_mode must be \"server\" or \"group\"" ]][[- end -]]
[[- if not (or (eq (var "service_provider" .) "nomad") (eq (var "service_provider" .) "consul")) -]][[ fail "service_provider must be \"nomad\" or \"consul\"" ]][[- end -]]
[[- end -]]

[[- define "job_name" -]]doris-[[ var "component" . ]]-[[ var "server_group" . ]][[- end -]]

[[- /* Pin the job to exactly one server group. */ -]]
[[- define "placement" ]]
  datacenters = [[ var "datacenters" . | toJson ]]
  node_pool   = [[ var "node_pool" . | quote ]]

  constraint {
    attribute = "${node.meta.[[ var "server_group_meta_key" . ]]}"
    value     = [[ var "server_group" . | quote ]]
  }
[[- end -]]

[[- /* Service lookup function used inside consul-template blocks. */ -]]
[[- define "svc_fn" -]][[ if eq (var "service_provider" .) "consul" ]]service[[ else ]]nomadService[[ end ]][[- end -]]

[[- /* Endpoints of all FEs (MySQL port), one host:port per line, re-rendered on change. */ -]]
[[- define "fe_endpoints_template" ]]
      template {
        destination = "local/fe_endpoints"
        change_mode = "noop"
        data        = <<EOT
{{- range [[ template "svc_fn" . ]] "[[ var "fe_query_service" . ]]" }}{{ .Address }}:{{ .Port }}
{{ end -}}
EOT
      }
[[- end -]]

[[- /* Secrets / bootstrap flag from Nomad Variables. noop: changing them never restarts Doris. */ -]]
[[- define "doris_env_template" ]]
      template {
        destination = "secrets/doris.env"
        env         = true
        change_mode = "noop"
        data        = <<EOT
{{ with nomadVar "[[ var "doris_var_path" . ]]" }}MYSQL_PWD={{ .root_password }}
FE_BOOTSTRAP_GROUP={{ .fe_bootstrap_group }}{{ end }}
EOT
      }
[[- end -]]

[[- /* Shared settings: never move data elsewhere, recover in place. */ -]]
[[- define "stateful_group_policy" ]]
    # Data is local: a disconnected node keeps its allocation; nothing is started elsewhere.
    disconnect {
      lost_after = [[ var "disconnect_lost_after" . | quote ]]
      replace    = false
      reconcile  = "keep_original"
    }

    # Sticky volume => a rescheduled allocation can only land on the node holding its volume.
    reschedule {
      delay          = "30s"
      delay_function = "exponential"
      max_delay      = "10m"
      unlimited      = true
    }

    restart {
      attempts = 3
      interval = "10m"
      delay    = "20s"
      mode     = "delay"
    }
[[- end -]]

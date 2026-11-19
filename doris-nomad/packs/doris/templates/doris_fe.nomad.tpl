[[- if eq (var "component" .) "fe" -]]
[[- template "validate" . -]]
job "[[ template "job_name" . ]]" {
  type = "service"
[[ template "placement" . ]]

  constraint {
    attribute = "${node.meta.doris_fe}"
    value     = "true"
  }

  # One FE follower per server group => 3 followers, quorum 2, one group may be down.
  group "fe" {
    count = 1

    volume "meta" {
      type            = "host"
      source          = [[ var "fe_volume_name" . | quote ]]
      sticky          = true
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }

[[ template "stateful_group_policy" . ]]

    update {
      max_parallel      = 1
      canary            = 0
      health_check      = "checks"
      min_healthy_time  = [[ var "min_healthy_time" . | quote ]]
      healthy_deadline  = [[ var "healthy_deadline" . | quote ]]
      progress_deadline = [[ var "progress_deadline" . | quote ]]
      auto_revert       = true
    }

    network {
      mode = "host"
      port "http"     { static = [[ (var "fe_ports" .).http ]] }
      port "rpc"      { static = [[ (var "fe_ports" .).rpc ]] }
      port "query"    { static = [[ (var "fe_ports" .).query ]] }
      port "edit_log" { static = [[ (var "fe_ports" .).edit_log ]] }
    }

    service {
      provider = [[ var "service_provider" . | quote ]]
      name     = [[ var "fe_query_service" . | quote ]]
      port     = "query"
      tags     = [[ list (var "server_group" .) | toJson ]]

      check {
        name     = "fe-query-port"
        type     = "tcp"
        interval = "10s"
        timeout  = "3s"
      }
    }

    service {
      provider = [[ var "service_provider" . | quote ]]
      name     = "doris-fe-http"
      port     = "http"
      tags     = [[ list (var "server_group" .) | toJson ]]
    }

    # Runs before EVERY FE start and decides how to start, based on the local volume:
    #   metadata present        -> plain restart (rolling upgrade path)
    #   empty, cluster exists   -> ADD FOLLOWER + start with --helper (first deploy / rebuilt node)
    #   empty, no FE reachable, and this group is the bootstrap group -> create the cluster
    task "fe-init" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      config {
        image        = [[ var "mysql_client_image" . | quote ]]
        network_mode = "host"
        entrypoint   = ["/bin/sh", "/local/fe-init.sh"]
      }

      volume_mount {
        volume      = "meta"
        destination = "/doris-meta"
        read_only   = true
      }

      env {
        DORIS_FE_META_DIR = "/doris-meta"
        SERVER_GROUP      = [[ var "server_group" . | quote ]]
        SELF_IP           = "${NOMAD_IP_edit_log}"
        EDIT_LOG_PORT     = "${NOMAD_PORT_edit_log}"
      }

[[ template "fe_endpoints_template" . ]]
[[ template "doris_env_template" . ]]

      template {
        destination = "local/fe-init.sh"
        perms       = "0755"
        change_mode = "noop"
        data        = <<EOS_DORIS
[[ fileContents (printf "%s/scripts/fe-init.sh" (meta "pack.path" .)) ]]
EOS_DORIS
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }

    task "fe" {
      driver = "docker"

      config {
        image        = [[ var "fe_image" . | quote ]]
        network_mode = "host"
        entrypoint   = ["/bin/bash", "/local/fe-start.sh"]
        ulimit {
          nofile = "655350:655350"
        }
      }

      volume_mount {
        volume      = "meta"
        destination = [[ var "fe_meta_path" . | quote ]]
      }

      env {
        DORIS_FE_META_DIR = [[ var "fe_meta_path" . | quote ]]
      }

      kill_signal    = "SIGTERM"
      kill_timeout   = [[ var "kill_timeout" . | quote ]]
      shutdown_delay = "10s"

      template {
        destination = "local/fe.conf.nomad"
        change_mode = "noop"
        data        = <<EOT
priority_networks = [[ var "priority_networks" . ]]
meta_dir = [[ var "fe_meta_path" . ]]
http_port = [[ (var "fe_ports" .).http ]]
rpc_port = [[ (var "fe_ports" .).rpc ]]
query_port = [[ (var "fe_ports" .).query ]]
edit_log_port = [[ (var "fe_ports" .).edit_log ]]
[[ var "fe_conf_extra" . ]]
EOT
      }

      template {
        destination = "local/fe-start.sh"
        perms       = "0755"
        change_mode = "noop"
        data        = <<EOS_DORIS
[[ fileContents (printf "%s/scripts/fe-start.sh" (meta "pack.path" .)) ]]
EOS_DORIS
      }

      resources {
        cpu    = [[ (var "fe_resources" .).cpu ]]
        memory = [[ (var "fe_resources" .).memory ]]
      }
    }
  }
}
[[- end -]]

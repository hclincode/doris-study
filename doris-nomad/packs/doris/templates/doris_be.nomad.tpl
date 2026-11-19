[[- if eq (var "component" .) "be" -]]
[[- template "validate" . -]]
job "[[ template "job_name" . ]]" {
  type = "service"
[[ template "placement" . ]]

  constraint {
    attribute = "${node.meta.doris_be}"
    value     = "true"
  }

  group "be" {
    count = [[ var "be_count" . ]]

    # One BE per server (static ports enforce this too).
    constraint {
      operator = "distinct_hosts"
      value    = "true"
    }

    # Local disk. sticky = every replacement of an allocation gets the SAME volume ID,
    # i.e. the same node and the same data. First placement claims a free volume.
    volume "storage" {
      type            = "host"
      source          = [[ var "be_volume_name" . | quote ]]
      sticky          = true
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }

[[ template "stateful_group_policy" . ]]

    update {
      # server mode: 1 BE at a time. group mode: the whole server group at once.
      # Groups are separate jobs rolled one after another by scripts/rollout.sh,
      # so at most one server group is ever affected.
      max_parallel      = [[ if eq (var "rollout_mode" .) "group" ]][[ var "be_count" . ]][[ else ]]1[[ end ]]
      canary            = 0
      health_check      = "checks"
      min_healthy_time  = [[ var "min_healthy_time" . | quote ]]
      healthy_deadline  = [[ var "healthy_deadline" . | quote ]]
      progress_deadline = [[ var "progress_deadline" . | quote ]]
      auto_revert       = true
    }

    network {
      mode = "host"
      port "heartbeat" { static = [[ (var "be_ports" .).heartbeat ]] }
      port "be"        { static = [[ (var "be_ports" .).be ]] }
      port "webserver" { static = [[ (var "be_ports" .).webserver ]] }
      port "brpc"      { static = [[ (var "be_ports" .).brpc ]] }
    }

    service {
      provider = [[ var "service_provider" . | quote ]]
      name     = "doris-be"
      port     = "webserver"
      tags     = [[ list (var "server_group" .) | toJson ]]

      check {
        name     = "be-http-health"
        type     = "http"
        path     = "/api/health"
        interval = "10s"
        timeout  = "3s"
      }
    }

    task "be" {
      driver = "docker"

      config {
        image        = [[ var "be_image" . | quote ]]
        network_mode = "host"
        entrypoint   = ["/bin/bash", "/local/be-start.sh"]
        ulimit {
          nofile = "655350:655350"
        }
      }

      volume_mount {
        volume      = "storage"
        destination = [[ var "be_storage_path" . | quote ]]
      }

      env {
        DORIS_BE_STORAGE = [[ var "be_storage_path" . | quote ]]
      }

      kill_signal    = "SIGTERM"
      kill_timeout   = [[ var "kill_timeout" . | quote ]]
      shutdown_delay = "10s"

      template {
        destination = "local/be.conf.nomad"
        change_mode = "noop"
        data        = <<EOT
priority_networks = [[ var "priority_networks" . ]]
storage_root_path = [[ var "be_storage_path" . ]]
heartbeat_service_port = [[ (var "be_ports" .).heartbeat ]]
be_port = [[ (var "be_ports" .).be ]]
webserver_port = [[ (var "be_ports" .).webserver ]]
brpc_port = [[ (var "be_ports" .).brpc ]]
[[ var "be_conf_extra" . ]]
EOT
      }

      template {
        destination = "local/be-start.sh"
        perms       = "0755"
        change_mode = "noop"
        data        = <<EOS_DORIS
[[ fileContents (printf "%s/scripts/be-start.sh" (meta "pack.path" .)) ]]
EOS_DORIS
      }

      resources {
        cpu    = [[ (var "be_resources" .).cpu ]]
        memory = [[ (var "be_resources" .).memory ]]
      }
    }

    # Registers this BE with the FE and sets tag.location = server group.
    # Idempotent: first deploy => ADD BACKEND, later restarts/upgrades => no-op.
    task "register" {
      driver = "docker"

      lifecycle {
        hook    = "poststart"
        sidecar = false
      }

      config {
        image        = [[ var "mysql_client_image" . | quote ]]
        network_mode = "host"
        entrypoint   = ["/bin/sh", "/local/be-register.sh"]
      }

      env {
        SERVER_GROUP   = [[ var "server_group" . | quote ]]
        SELF_IP        = "${NOMAD_IP_heartbeat}"
        HEARTBEAT_PORT = "${NOMAD_PORT_heartbeat}"
      }

[[ template "fe_endpoints_template" . ]]
[[ template "doris_env_template" . ]]

      template {
        destination = "local/be-register.sh"
        perms       = "0755"
        change_mode = "noop"
        data        = <<EOS_DORIS
[[ fileContents (printf "%s/scripts/be-register.sh" (meta "pack.path" .)) ]]
EOS_DORIS
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
[[- end -]]

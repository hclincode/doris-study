# ---------------------------------------------------------------------------
# What this render produces: exactly ONE job = one component in one server group.
#   nomad-pack run packs/doris --name doris-be-dc1 \
#       -f vars/common.hcl -f vars/dc1.hcl --var component=be
# Never render more than one server group per run; scripts/rollout.sh does the ordering.
# ---------------------------------------------------------------------------

variable "component" {
  description = "Which Doris component this job runs: \"be\" or \"fe\"."
  type        = string
  default     = "be"
}

variable "server_group" {
  description = "Server group (failure domain / DC) this job is pinned to, e.g. dc1. Also used as the Doris tag.location."
  type        = string
  default     = ""
}

variable "datacenters" {
  description = "Nomad datacenters of this server group."
  type        = list(string)
  default     = ["*"]
}

variable "node_pool" {
  description = "Nomad node pool reserved for Doris nodes."
  type        = string
  default     = "doris"
}

variable "server_group_meta_key" {
  description = "Client node meta key that holds the server group name."
  type        = string
  default     = "server_group"
}

variable "rollout_mode" {
  description = "\"server\": max_parallel=1 (one server down in the whole cluster). \"group\": max_parallel=be_count (the whole server group at once, never more than one group)."
  type        = string
  default     = "server"
}

variable "be_count" {
  description = "Number of BE nodes in this server group. Must be <= number of BE volumes created in the group."
  type        = number
  default     = 1
}

variable "be_image" {
  description = "Doris BE image. Pin an exact version."
  type        = string
  default     = "apache/doris:be-2.1.9"
}

variable "fe_image" {
  description = "Doris FE image. Pin an exact version (same Doris version as BE)."
  type        = string
  default     = "apache/doris:fe-2.1.9"
}

variable "mysql_client_image" {
  description = "Image with a mysql client, used by the FE init and BE register helper tasks."
  type        = string
  default     = "mysql:8.0"
}

variable "be_volume_name" {
  description = "Name of the dynamic host volume holding BE storage (one per BE node)."
  type        = string
  default     = "doris-be-storage"
}

variable "fe_volume_name" {
  description = "Name of the dynamic host volume holding FE doris-meta (one per FE node)."
  type        = string
  default     = "doris-fe-meta"
}

variable "be_storage_path" {
  description = "Mount point of the BE volume inside the container (storage_root_path)."
  type        = string
  default     = "/opt/apache-doris/be/storage"
}

variable "fe_meta_path" {
  description = "Mount point of the FE volume inside the container (meta_dir)."
  type        = string
  default     = "/opt/apache-doris/fe/doris-meta"
}

variable "priority_networks" {
  description = "Doris priority_networks CIDR, must contain the node IPs Nomad advertises."
  type        = string
  default     = "10.0.0.0/8"
}

variable "be_ports" {
  description = "Static BE ports (FE identifies a BE by host:heartbeat port, so these must not change)."
  type = object({
    heartbeat = number
    be        = number
    webserver = number
    brpc      = number
  })
  default = {
    heartbeat = 9050
    be        = 9060
    webserver = 8040
    brpc      = 8060
  }
}

variable "fe_ports" {
  description = "Static FE ports (FE identifies an FE by host:edit_log port)."
  type = object({
    http     = number
    rpc      = number
    query    = number
    edit_log = number
  })
  default = {
    http     = 8030
    rpc      = 9020
    query    = 9030
    edit_log = 9010
  }
}

variable "be_resources" {
  description = "BE task resources (MHz / MB)."
  type = object({
    cpu    = number
    memory = number
  })
  default = {
    cpu    = 8000
    memory = 32768
  }
}

variable "fe_resources" {
  description = "FE task resources (MHz / MB)."
  type = object({
    cpu    = number
    memory = number
  })
  default = {
    cpu    = 4000
    memory = 16384
  }
}

variable "be_conf_extra" {
  description = "Extra lines appended to be.conf (later keys win)."
  type        = string
  default     = ""
}

variable "fe_conf_extra" {
  description = "Extra lines appended to fe.conf (later keys win)."
  type        = string
  default     = ""
}

variable "service_provider" {
  description = "\"nomad\" or \"consul\" service discovery."
  type        = string
  default     = "nomad"
}

variable "fe_query_service" {
  description = "Service name for the FE MySQL port."
  type        = string
  default     = "doris-fe-query"
}

variable "doris_var_path" {
  description = "Nomad Variable path holding root_password and fe_bootstrap_group (jobs need a read policy, see acl/)."
  type        = string
  default     = "nomad/jobs/doris"
}

variable "min_healthy_time" {
  description = "How long a replaced allocation must stay healthy before the next one is replaced."
  type        = string
  default     = "60s"
}

variable "healthy_deadline" {
  description = "Max time for a replaced allocation to become healthy."
  type        = string
  default     = "15m"
}

variable "progress_deadline" {
  description = "Deployment progress deadline (must be > healthy_deadline)."
  type        = string
  default     = "30m"
}

variable "kill_timeout" {
  description = "Time Doris gets to shut down after SIGTERM before SIGKILL."
  type        = string
  default     = "120s"
}

variable "disconnect_lost_after" {
  description = "How long a disconnected node keeps its allocations before they are marked lost (never replaced elsewhere: data is local)."
  type        = string
  default     = "30m"
}

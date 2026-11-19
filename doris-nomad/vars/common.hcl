# Shared by every job. Change versions here, then run scripts/rollout.sh.
be_image           = "apache/doris:be-2.1.9"
fe_image           = "apache/doris:fe-2.1.9"
mysql_client_image = "mysql:8.0"

node_pool         = "doris"
priority_networks = "10.0.0.0/8"
service_provider  = "nomad"

min_healthy_time  = "60s"
healthy_deadline  = "15m"
progress_deadline = "30m"
kill_timeout      = "120s"

be_resources = {
  cpu    = 8000
  memory = 32768
}

fe_resources = {
  cpu    = 4000
  memory = 16384
}

app {
  url = "https://doris.apache.org"
}

pack {
  name        = "doris"
  description = "Apache Doris (FE + BE) on local disk. One Nomad job per component per server group, sticky dynamic host volumes, ordered rolling upgrades."
  version     = "0.1.0"
}

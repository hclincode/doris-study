# Server group dc1. Nodes must carry: node_pool = "doris", meta.server_group = "dc1",
# meta.doris_be = "true" (BE nodes) and/or meta.doris_fe = "true" (the FE node).
server_group = "dc1"
datacenters  = ["dc1"]
be_count     = 3

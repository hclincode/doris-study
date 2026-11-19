# Server group dc2. Nodes must carry: node_pool = "doris", meta.server_group = "dc2",
# meta.doris_be = "true" (BE nodes) and/or meta.doris_fe = "true" (the FE node).
server_group = "dc2"
datacenters  = ["dc2"]
be_count     = 3

# Server group dc3. Nodes must carry: node_pool = "doris", meta.server_group = "dc3",
# meta.doris_be = "true" (BE nodes) and/or meta.doris_fe = "true" (the FE node).
server_group = "dc3"
datacenters  = ["dc3"]
be_count     = 3

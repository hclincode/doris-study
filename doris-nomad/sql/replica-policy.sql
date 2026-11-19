-- One replica of every tablet in every server group.
-- This is what makes "one whole server group down" safe: 2 of 3 replicas stay up,
-- loads still reach a majority, queries still find a replica.
-- Tags are set on the BEs automatically by the BE "register" task (tag.location = server group).

-- New tables: put this in every CREATE TABLE ... PROPERTIES (...)
--   "replication_allocation" = "tag.location.dc1: 1, tag.location.dc2: 1, tag.location.dc3: 1"

-- Database default (so tables created without the property inherit it; check your Doris
-- version supports a database-level replication_allocation):
-- ALTER DATABASE <db> SET PROPERTIES ("replication_allocation" = "tag.location.dc1: 1, tag.location.dc2: 1, tag.location.dc3: 1");

-- Existing tables still on "replication_num" = "3" (no location guarantee):
-- ALTER TABLE <db>.<tbl> SET ("default.replication_allocation" = "tag.location.dc1: 1, tag.location.dc2: 1, tag.location.dc3: 1");
-- ALTER TABLE <db>.<tbl> MODIFY PARTITION (*) SET ("replication_allocation" = "tag.location.dc1: 1, tag.location.dc2: 1, tag.location.dc3: 1");
-- Doris then migrates replicas; wait for SHOW PROC '/cluster_health/tablet_health' to be clean.

-- Verify (scripts/check-cluster.sh --audit-tables does this for every table):
-- SHOW PARTITIONS FROM <db>.<tbl>;            -- column ReplicaAllocation
-- ADMIN SHOW REPLICA DISTRIBUTION FROM <db>.<tbl>;

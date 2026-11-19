# Lets the Doris jobs' workload identities read the shared variable nomad/jobs/doris
# (root_password, fe_bootstrap_group). Only needed when Nomad ACLs are enabled.
# bootstrap.sh attaches it to every doris-* job.
namespace "default" {
  variables {
    path "nomad/jobs/doris" {
      capabilities = ["read"]
    }
  }
}

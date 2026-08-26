locals {
  job_env_vars = {
    for key, value in var.job_env_vars : key => trimspace(value)
    if value != null && try(trimspace(value), "") != ""
  }

  orchestrator_vars = {
    node_pool  = var.node_pool
    port       = var.port
    proxy_port = var.proxy_port

    artifact_source = var.artifact_source

    job_env_vars               = local.job_env_vars
    version_constraint_enabled = var.version_constraint_enabled
  }

  # Render with placeholder to detect changes in job definition
  orchestrator_job_check = templatefile("${path.module}/jobs/orchestrator.hcl", merge(
    local.orchestrator_vars, {
      latest_orchestrator_job_id = "placeholder",
    }
  ))
}

resource "random_id" "orchestrator_job" {
  keepers = {
    # Use both the orchestrator job (including vars) definition and the latest orchestrator checksum to detect changes
    orchestrator_job = sha256("${local.orchestrator_job_check}-${var.orchestrator_checksum}")
  }

  byte_length = 8
}

locals {
  # Providers without version-constrained node metadata replace a stable job
  # in place. Keeping this ID known during planning avoids the Nomad provider
  # changing an Update into DeleteThenCreate while applying a saved plan.
  latest_orchestrator_job_id = var.environment == "dev" || !var.version_constraint_enabled ? var.environment : random_id.orchestrator_job.hex
}

resource "nomad_variable" "orchestrator_hash" {
  path = "nomad/jobs"
  items = {
    latest_orchestrator_job_id = local.latest_orchestrator_job_id
  }
}

resource "nomad_job" "orchestrator" {
  # Version-constrained pools keep old jobs registered while nodes roll between
  # versions. AWS does not set that node metadata, so it replaces the old job.
  deregister_on_id_change = !var.version_constraint_enabled

  jobspec = templatefile("${path.module}/jobs/orchestrator.hcl", merge(
    local.orchestrator_vars, {
      latest_orchestrator_job_id = local.latest_orchestrator_job_id
    }
  ))

  depends_on = [nomad_variable.orchestrator_hash, random_id.orchestrator_job]
}

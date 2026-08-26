job "orchestrator-${latest_orchestrator_job_id}" {
  type = "system"
  node_pool = "${node_pool}"

  priority = 91

  group "client-orchestrator" {
    // For future as we can remove static and allow multiple instances on one machine if needed.
    // Also network allocation is used by Nomad service discovery on API and edge API to find jobs and register them.
    network {
      port "orchestrator" {
        static = "${port}"
      }

      port "orchestrator-proxy" {
        static = "${proxy_port}"
      }
    }

%{ if version_constraint_enabled && latest_orchestrator_job_id != "dev" }
    constraint {
      attribute = "$${meta.orchestrator_job_version}"
      value     = "${latest_orchestrator_job_id}"
    }
%{ endif }

    service {
      name = "orchestrator"
      port = "${port}"

      provider = "nomad"

      check {
        type         = "http"
        path         = "/health"
        name         = "health"
        interval     = "20s"
        timeout      = "5s"
      }
    }

    service {
      name = "orchestrator-proxy"
      port = "${proxy_port}"

      provider = "nomad"

      check {
        type     = "tcp"
        name     = "health"
        interval = "30s"
        timeout  = "1s"
      }
    }

    task "start" {
      driver = "raw_exec"

      # The process drains live sandboxes, then pending snapshot uploads.
      # Matches the Nomad client cap; pre-drain nodes before replacement.
      # This is a ceiling, not a delay: an empty node exits immediately after cleanup.
      kill_timeout = "24h"
      kill_signal  = "SIGTERM"

      restart {
        attempts = 0
      }

      resources {
        memory     = 1024
        memory_max = -1
      }

      env {
        NODE_ID     = "$${node.unique.name}"
        NODE_IP     = "$${attr.unique.network.ip-address}"
        NODE_LABELS = "$${meta.node_labels}"

        GRPC_PORT                    = "${port}"
        PROXY_PORT                   = "${proxy_port}"

%{ for key, value in job_env_vars ~}
        ${key} = "${value}"
%{ endfor ~}

      }

      config {
        command = "/bin/bash"
        args    = ["-c", " chmod +x local/orchestrator && exec local/orchestrator"]
      }

      artifact {
        source      = "${artifact_source}"
        destination = "local/orchestrator"
        mode        = "file"
      }
    }
  }
}

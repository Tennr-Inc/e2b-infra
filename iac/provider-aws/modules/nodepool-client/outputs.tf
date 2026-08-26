output "capacity_configuration" {
  description = "Sandbox capacity bounds and automatic scale-out policy."
  value = {
    instance_type             = aws_launch_template.client.instance_type
    instance_store_cache      = var.use_instance_store
    min_nodes                 = aws_autoscaling_group.client.min_size
    max_nodes                 = aws_autoscaling_group.client.max_size
    scale_in_protection       = aws_autoscaling_group.client.protect_from_scale_in
    memory_target             = try(aws_autoscaling_policy.memory[0].target_tracking_configuration[0].target_value, null)
    memory_scale_in_disabled  = try(aws_autoscaling_policy.memory[0].target_tracking_configuration[0].disable_scale_in, null)
    cpu_scale_in_disabled     = try(aws_autoscaling_policy.cpu[0].target_tracking_configuration[0].disable_scale_in, null)
    base_hugepages_percentage = var.base_hugepages_percentage
    reserved_host_memory_mib  = var.reserved_host_memory_mib
    sandbox_memory_limit_mib  = var.sandbox_memory_limit_mib
    max_sandboxes_per_node    = var.max_sandboxes_per_node
    capacity_metric           = local.admission_enabled ? "SandboxCapacityUtilization" : "SandboxMemoryUtilization"
  }
}

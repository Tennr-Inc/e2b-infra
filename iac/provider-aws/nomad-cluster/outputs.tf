output "sandbox_capacity" {
  value = module.client.capacity_configuration
}

output "build_capacity" {
  value = module.build.capacity_configuration
}

output "sandbox_asg_name" { value = module.client.asg_name }
output "sandbox_asg_arn" { value = module.client.asg_arn }

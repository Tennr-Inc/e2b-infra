resource "random_password" "master" {
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.prefix}${var.name}"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.prefix}${var.name}"
  }
}

resource "aws_security_group" "this" {
  name        = "${var.prefix}${var.name}"
  description = "Allow PostgreSQL from approved private security groups"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from approved private security groups"
    from_port       = var.port
    to_port         = var.port
    protocol        = "tcp"
    security_groups = var.ingress_security_group_ids
  }

  tags = {
    Name = "${var.prefix}${var.name}"
  }
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.prefix}${var.name}"
  family = "postgres${split(".", var.engine_version)[0]}"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "immediate"
  }

  tags = {
    Name = "${var.prefix}${var.name}"
  }
}

resource "aws_db_instance" "this" {
  identifier = "${var.prefix}${var.name}"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.database_name
  username = var.master_username
  password = random_password.master.result
  port     = var.port

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  parameter_group_name   = aws_db_parameter_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  backup_retention_period = var.backup_retention_period
  copy_tags_to_snapshot   = true
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : format(
    "%s%s-final",
    var.prefix,
    var.name,
  )

  auto_minor_version_upgrade = true
  enabled_cloudwatch_logs_exports = [
    "postgresql",
    "upgrade",
  ]

  tags = {
    Name = "${var.prefix}${var.name}"
  }
}

locals {
  connection_string = format(
    "postgresql://%s:%s@%s:%d/%s?sslmode=require",
    var.master_username,
    random_password.master.result,
    aws_db_instance.this.address,
    var.port,
    var.database_name,
  )
}

resource "aws_secretsmanager_secret_version" "connection_string" {
  secret_id     = var.connection_string_secret_id
  secret_string = local.connection_string
}

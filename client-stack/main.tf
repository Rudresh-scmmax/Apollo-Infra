terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name_prefix = "${var.client_code}-${var.environment}"

  tags = merge(
    {
      Client      = var.client_code
      Environment = var.environment
      ManagedBy   = "terraform"
      Workspace   = "apollo-v2"
    },
    var.tags
  )

  selected_azs = length(var.availability_zones) > 0 ? var.availability_zones : data.aws_availability_zones.available.names

  lambda_function_names = {
    for name in [
      "utility-function-v2",
      "forecast-model-v2",
      "quote-compare-v2",
      "correlation-v2",
      "read-mail-inbox-v2",
      "private_db_query",
      "etl"
    ] :
    name => "${var.client_code}-${name}"
  }

  lambda_image_tags = merge(
    {
      for name in keys(local.lambda_function_names) : name => "latest"
    },
    var.lambda_image_tags
  )

  lambda_common_env = merge(
    {
      # AWS_REGION is automatically set by Lambda and cannot be overridden
      PRIVATE_DB_QUERY_FUNCTION = local.lambda_function_names["private_db_query"]
      PRIVATE_FILES_BUCKET      = var.private_assets_bucket_name
    },
    var.lambda_extra_env
  )
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-igw" })
}

resource "aws_subnet" "public" {
  for_each = { for idx, cidr in var.public_subnet_cidrs : idx => { cidr = cidr, az = element(local.selected_azs, idx) } }

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-public-${each.key}" })
}

resource "aws_subnet" "private" {
  for_each = { for idx, cidr in var.private_subnet_cidrs : idx => { cidr = cidr, az = element(local.selected_azs, idx) } }

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = merge(local.tags, { Name = "${local.name_prefix}-private-${each.key}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-public-rt" })
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${local.name_prefix}-nat-eip" })
}

resource "aws_nat_gateway" "nat" {
  subnet_id     = element(values(aws_subnet.public), 0).id
  allocation_id = aws_eip.nat.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-nat" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-private-rt" })
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.alb_allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-alb-sg" })
}

resource "aws_security_group" "ecs" {
  name        = "${local.name_prefix}-ecs-sg"
  description = "ECS service security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Allow ALB"
    from_port       = var.backend_container_port
    to_port         = var.backend_container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-ecs-sg" })
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "PostgreSQL security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "ECS access"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  ingress {
    description     = "Lambda access"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda_db.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-rds-sg" })
}

resource "aws_security_group" "lambda_db" {
  name        = "${local.name_prefix}-lambda-db-sg"
  description = "Lambda security group for DB access"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-lambda-db-sg" })
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.name_prefix}-vpc-endpoints-sg"
  description = "Security group for VPC endpoints (Bedrock, Lambda, etc.)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTPS from Lambda"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda_db.id]
  }

  ingress {
    description     = "HTTPS from ECS"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-vpc-endpoints-sg" })
}

# -----------------------------------------------------------------------------
# S3 buckets
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "private_assets" {
  bucket        = var.private_assets_bucket_name
  force_destroy = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-private-assets" })
}

resource "aws_s3_bucket_versioning" "private_assets" {
  bucket = aws_s3_bucket.private_assets.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "private_assets" {
  bucket = aws_s3_bucket.private_assets.id

  block_public_acls   = true
  block_public_policy = true
  ignore_public_acls  = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "private_assets" {
  bucket = aws_s3_bucket.private_assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket" "frontend" {
  bucket        = var.frontend_bucket_name
  force_destroy = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-frontend" })
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# -----------------------------------------------------------------------------
# RDS
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "postgres" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = [for subnet in aws_subnet.private : subnet.id]

  tags = merge(local.tags, { Name = "${local.name_prefix}-db-subnet-group" })
}

resource "aws_db_instance" "postgres" {
  identifier = "${var.client_code}-${var.environment}-postgres"
  engine     = "postgres"
  engine_version = var.db_engine_version

  instance_class         = var.db_instance_class
  allocated_storage      = var.db_allocated_storage
  max_allocated_storage  = var.db_max_allocated_storage
  storage_encrypted      = true
  username               = var.db_username
  password               = var.db_password
  db_name                = var.db_name
  port                   = 5432
  multi_az               = var.db_multi_az
  deletion_protection    = var.db_deletion_protection
  backup_retention_period = var.db_backup_retention
  skip_final_snapshot    = var.db_skip_final_snapshot

  publicly_accessible    = false
  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.postgres.name

  tags = merge(local.tags, { Name = "${local.name_prefix}-postgres" })
}

# -----------------------------------------------------------------------------
# VPC Endpoints (PrivateLink) for AWS Services
# -----------------------------------------------------------------------------

# Bedrock Runtime endpoint for Llama model access
resource "aws_vpc_endpoint" "bedrock_runtime" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for subnet in aws_subnet.private : subnet.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-bedrock-runtime-endpoint" })
}

# Lambda endpoint for Lambda-to-Lambda invocations
resource "aws_vpc_endpoint" "lambda" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.lambda"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for subnet in aws_subnet.private : subnet.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-lambda-endpoint" })
}

# CloudWatch Logs endpoint for Lambda logging
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for subnet in aws_subnet.private : subnet.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-logs-endpoint" })
}

# STS endpoint for credential requests
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for subnet in aws_subnet.private : subnet.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-sts-endpoint" })
}

# S3 Gateway endpoint (free, no data transfer charges)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.tags, { Name = "${local.name_prefix}-s3-endpoint" })
}

# -----------------------------------------------------------------------------
# Elastic Container Registry
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "backend" {
  name                 = "${var.client_code}-apollo-backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-backend-ecr" })
}

resource "aws_ecr_repository" "lambda" {
  for_each = local.lambda_function_names

  name                 = "${each.value}-repo"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.tags, { Name = "${each.value}-repo" })
}

# -----------------------------------------------------------------------------
# IAM for ECS
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${local.name_prefix}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

resource "aws_iam_role" "ecs_task" {
  name               = "${local.name_prefix}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution_default" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_task_extra" {
  name = "${local.name_prefix}-ecs-task-extra"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = "${aws_cloudwatch_log_group.ecs.arn}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.private_assets.arn,
          "${aws_s3_bucket.private_assets.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          for _, fn in aws_lambda_function.serverless : fn.arn
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# CloudWatch Logs
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = var.ecs_log_retention
  tags              = local.tags
}

# -----------------------------------------------------------------------------
# ECS Cluster, Task Definition, and Service
# -----------------------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.tags
}

locals {
  database_url = "postgresql+asyncpg://${var.db_username}:${var.db_password}@${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}/${var.db_name}"
}

resource "aws_ecs_task_definition" "backend" {
  family                   = "${local.name_prefix}-backend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.backend_cpu
  memory                   = var.backend_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "apollo-backend"
      image     = "${aws_ecr_repository.backend.repository_url}:${var.backend_image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = var.backend_container_port
          hostPort      = var.backend_container_port
          protocol      = "tcp"
        }
      ]
      environment = concat([
        {
          name  = "DATABASE_URL"
          value = local.database_url
        },
        {
          name  = "SECRET_KEY"
          value = var.backend_secret_key
        },
        {
          name  = "ALGORITHM"
          value = "HS256"
        },
        {
          name  = "SESSION_SECRET_KEY"
          value = var.backend_session_secret
        },
        {
          name  = "S3_BUCKET"
          value = var.private_assets_bucket_name
        },
        {
          name  = "ENVIRONMENT"
          value = var.environment
        },
        {
          name  = "LAMBDA_UTILITY_FUNCTION"
          value = local.lambda_function_names["utility-function-v2"]
        },
        {
          name  = "LAMBDA_FORECAST_MODEL"
          value = local.lambda_function_names["forecast-model-v2"]
        },
        {
          name  = "LAMBDA_QUOTE_COMPARE"
          value = local.lambda_function_names["quote-compare-v2"]
        },
        {
          name  = "LAMBDA_CORRELATION"
          value = local.lambda_function_names["correlation-v2"]
        },
        {
          name  = "LAMBDA_READ_MAIL_INBOX"
          value = local.lambda_function_names["read-mail-inbox-v2"]
        },
        {
          name  = "LAMBDA_PRIVATE_DB_QUERY"
          value = local.lambda_function_names["private_db_query"]
        }
      ], var.backend_extra_env)
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.backend_container_port}/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = local.tags
}

resource "aws_lb" "backend" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for subnet in aws_subnet.public : subnet.id]

  enable_deletion_protection = false

  tags = merge(local.tags, { Name = "${local.name_prefix}-alb" })
}

resource "aws_lb_target_group" "backend" {
  name        = "${local.name_prefix}-tg"
  port        = var.backend_container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = var.backend_health_check_path
    matcher             = "200"
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-tg" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.backend.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

resource "aws_ecs_service" "backend" {
  name            = "${local.name_prefix}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = var.backend_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [for subnet in aws_subnet.private : subnet.id]
    security_groups = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = "apollo-backend"
    container_port   = var.backend_container_port
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  tags = merge(local.tags, { Name = "${local.name_prefix}-service" })
}

# -----------------------------------------------------------------------------
# CloudFront + S3 Website
# -----------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.name_prefix}-oac"
  description                       = "OAC for ${var.frontend_bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

locals {
  viewer_certificate = var.acm_certificate_arn != "" ? {
    acm_certificate_arn      = var.acm_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  } : null
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "SCM-MAX frontend for ${var.client_code}"
  price_class     = var.cloudfront_price_class
  default_root_object = "index.html"
  aliases         = var.frontend_domain != "" ? [var.frontend_domain] : []

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-${var.frontend_bucket_name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  origin {
    domain_name = aws_lb.backend.dns_name
    origin_id   = "api-backend"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-${var.frontend_bucket_name}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = var.frontend_default_ttl
    max_ttl     = 31536000
  }

  ordered_cache_behavior {
    path_pattern           = var.backend_api_path
    target_origin_id       = "api-backend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Content-Type"]

      cookies {
        forward = "all"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Custom error responses for SPA routing
  # When user refreshes on /dashboard or any route, CloudFront will return index.html
  # so the React router can handle the routing client-side
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
    error_caching_min_ttl = 300
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
    error_caching_min_ttl = 300
  }

  viewer_certificate {
    cloudfront_default_certificate = var.acm_certificate_arn == ""
    acm_certificate_arn            = var.acm_certificate_arn != "" ? var.acm_certificate_arn : null
    ssl_support_method             = var.acm_certificate_arn != "" ? "sni-only" : null
    minimum_protocol_version       = var.acm_certificate_arn != "" ? "TLSv1.2_2021" : null
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-cf" })
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.frontend.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# S3 Bucket for ETL Uploads
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "etl_uploads" {
  bucket        = "${var.client_code}-${var.environment}-etl-uploads"
  force_destroy = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-etl-uploads" })
}

resource "aws_s3_bucket_versioning" "etl_uploads" {
  bucket = aws_s3_bucket.etl_uploads.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "etl_uploads" {
  bucket = aws_s3_bucket.etl_uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "etl_uploads" {
  bucket = aws_s3_bucket.etl_uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# -----------------------------------------------------------------------------
# Lambda IAM
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda_general" {
  name               = "${local.name_prefix}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "lambda_general_basic" {
  role       = aws_iam_role.lambda_general.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_general_vpc" {
  role       = aws_iam_role.lambda_general.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_general_extra" {
  name = "${local.name_prefix}-lambda-extra"
  role = aws_iam_role.lambda_general.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.private_assets.arn,
          "${aws_s3_bucket.private_assets.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.client_code}-*"
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "lambda_db" {
  name               = "${local.name_prefix}-lambda-db-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "lambda_db_basic" {
  role       = aws_iam_role.lambda_db.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_db_vpc" {
  role       = aws_iam_role.lambda_db.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_db_extra" {
  name = "${local.name_prefix}-lambda-db-extra"
  role = aws_iam_role.lambda_db.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "kms:Decrypt"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "${aws_s3_bucket.etl_uploads.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.etl_uploads.arn
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Lambda functions
# -----------------------------------------------------------------------------

locals {
  lambda_settings = {
    "utility-function-v2" = {
      timeout    = 900
      memory     = 2048
      enable_vpc = true
    }
    "forecast-model-v2" = {
      timeout    = 900
      memory     = 4096
      enable_vpc = true
    }
    "quote-compare-v2" = {
      timeout    = 900
      memory     = 2048
      enable_vpc = true
    }
    "correlation-v2" = {
      timeout    = 300
      memory     = 1024
      enable_vpc = true
    }
    "read-mail-inbox-v2" = {
      timeout    = 900
      memory     = 2048
      enable_vpc = true
    }
    "private_db_query" = {
      timeout    = 60
      memory     = 1024
      enable_vpc = true
    }
    "etl" = {
      timeout    = 900
      memory     = 2048
      enable_vpc = true
    }
  }
}

resource "aws_lambda_function" "serverless" {
  for_each = local.lambda_function_names

  function_name = each.value
  role          = (each.key == "private_db_query" || each.key == "etl") ? aws_iam_role.lambda_db.arn : aws_iam_role.lambda_general.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.lambda[each.key].repository_url}:${lookup(local.lambda_image_tags, each.key)}"
  timeout       = lookup(local.lambda_settings[each.key], "timeout", 900)
  memory_size   = lookup(local.lambda_settings[each.key], "memory", 1024)
  architectures = ["x86_64"]

  vpc_config {
    subnet_ids         = [for subnet in aws_subnet.private : subnet.id]
    security_group_ids = [aws_security_group.lambda_db.id]
  }

  environment {
    variables = merge(
      local.lambda_common_env,
      lookup(var.lambda_env_overrides, each.key, {}),
      each.key == "private_db_query" ? {
        DB_HOST = aws_db_instance.postgres.address
        DB_PORT = tostring(aws_db_instance.postgres.port)
        DB_USER = var.db_username
        DB_PASSWORD = var.db_password
        DB_NAME = var.db_name
      } : {},
      each.key == "etl" ? {
        DB_HOST = aws_db_instance.postgres.address
        DB_PORT = tostring(aws_db_instance.postgres.port)
        DB_USER = var.db_username
        DB_PASS = var.db_password
        DB_NAME = var.db_name
      } : {},
      each.key == "quote-compare-v2" ? { SERPER_API_KEY = var.serper_api_key } : {},
      each.key == "utility-function-v2" ? { SERPER_API_KEY = var.serper_api_key } : {}
    )
  }

  depends_on = [
    aws_iam_role.lambda_general,
    aws_iam_role.lambda_db
  ]

  tags = merge(local.tags, { Name = each.value })
}

# -----------------------------------------------------------------------------
# S3 Trigger for ETL Lambda
# -----------------------------------------------------------------------------

resource "aws_lambda_permission" "etl_s3_trigger" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.serverless["etl"].function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.etl_uploads.arn

  depends_on = [aws_lambda_function.serverless["etl"]]
}

resource "aws_s3_bucket_notification" "etl_trigger" {
  bucket = aws_s3_bucket.etl_uploads.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.serverless["etl"].arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = ""
    filter_suffix       = ".xlsx"
  }

  depends_on = [aws_lambda_permission.etl_s3_trigger]
}



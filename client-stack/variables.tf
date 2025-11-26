variable "aws_region" {
  description = "AWS region for this client stack"
  type        = string
  default     = "us-east-1"
}

variable "client_code" {
  description = "Short code used to namespace resources per client (lowercase, no spaces)"
  type        = string
}

variable "environment" {
  description = "Deployment environment label"
  type        = string
  default     = "prod"
}

variable "tags" {
  description = "Additional tags to apply to every resource"
  type        = map(string)
  default     = {}
}

variable "availability_zones" {
  description = "Optional override for availability zones (defaults to all available in region)"
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.30.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.30.0.0/24", "10.30.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.30.10.0/24", "10.30.11.0/24"]
}

variable "alb_allowed_cidrs" {
  description = "CIDR blocks allowed to reach the Application Load Balancer"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "private_assets_bucket_name" {
  description = "S3 bucket for backend/lambda private assets (must be globally unique)"
  type        = string
}

variable "frontend_bucket_name" {
  description = "S3 bucket for hosting the React frontend (must be globally unique)"
  type        = string
}

variable "frontend_domain" {
  description = "Optional custom domain pointing to CloudFront"
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN in us-east-1 for the CloudFront distribution (required when using a custom domain)"
  type        = string
  default     = ""
}

variable "cloudfront_price_class" {
  description = "CloudFront price class"
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_All", "PriceClass_200", "PriceClass_100"], var.cloudfront_price_class)
    error_message = "Valid price classes are PriceClass_All, PriceClass_200, PriceClass_100."
  }
}

variable "frontend_default_ttl" {
  description = "Default TTL for static assets served from CloudFront"
  type        = number
  default     = 86400
}

variable "backend_api_path" {
  description = "Path pattern that should be forwarded to the backend through CloudFront"
  type        = string
  default     = "/api/*"
}

variable "db_engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "15.3"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Initial storage size (GB)"
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Maximum storage size (GB)"
  type        = number
  default     = 100
}

variable "db_username" {
  description = "Database master username"
  type        = string
  default     = "postgres"
}

variable "db_password" {
  description = "Database master password"
  type        = string
  sensitive   = true
}

variable "db_name" {
  description = "Default database name"
  type        = string
  default     = "apollo"
}

variable "db_multi_az" {
  description = "Enable Multi-AZ for RDS"
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "Enable deletion protection on RDS"
  type        = bool
  default     = false
}

variable "db_backup_retention" {
  description = "Backup retention period in days"
  type        = number
  default     = 7
}

variable "db_skip_final_snapshot" {
  description = "Skip final snapshot on RDS deletion"
  type        = bool
  default     = true
}

variable "backend_cpu" {
  description = "CPU units for the ECS task definition (Fargate allowed values)"
  type        = string
  default     = "1024"
}

variable "backend_memory" {
  description = "Memory (MiB) for the ECS task definition (Fargate allowed values)"
  type        = string
  default     = "2048"
}

variable "backend_container_port" {
  description = "Container port exposed by the FastAPI service"
  type        = number
  default     = 8000
}

variable "backend_health_check_path" {
  description = "Path used by the ALB target group health check"
  type        = string
  default     = "/"
}

variable "backend_desired_count" {
  description = "Desired number of ECS service tasks"
  type        = number
  default     = 2
}

variable "backend_image_tag" {
  description = "Docker image tag to deploy for the backend"
  type        = string
  default     = "latest"
}

variable "backend_secret_key" {
  description = "FastAPI SECRET_KEY value"
  type        = string
  sensitive   = true
}

variable "backend_session_secret" {
  description = "Session secret key used by the backend"
  type        = string
  sensitive   = true
}

variable "ecs_log_retention" {
  description = "Retention in days for ECS CloudWatch logs"
  type        = number
  default     = 14
}

variable "serper_api_key" {
  description = "API key used by the quote comparison lambda for Google Serper lookups"
  type        = string
  default     = ""
  sensitive   = true
}

variable "lambda_image_tags" {
  description = "Optional overrides for lambda image tags (keyed by logical lambda name)"
  type        = map(string)
  default     = {}
}

variable "lambda_extra_env" {
  description = "Global environment variables injected into every lambda"
  type        = map(string)
  default     = {}
}

variable "lambda_env_overrides" {
  description = "Per-lambda environment variable overrides"
  type        = map(map(string))
  default     = {}
}

variable "backend_extra_env" {
  description = "Additional environment variables for the backend ECS task (list of {name, value} maps)"
  type        = list(map(string))
  default     = []
}


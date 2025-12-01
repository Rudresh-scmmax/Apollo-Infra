output "alb_dns_name" {
  description = "Public DNS name of the backend Application Load Balancer"
  value       = aws_lb.backend.dns_name
}

output "cloudfront_domain" {
  description = "Domain name of the CloudFront distribution serving the frontend"
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "cloudfront_distribution_id" {
  description = "ID of the CloudFront distribution (useful for invalidations)"
  value       = aws_cloudfront_distribution.frontend.id
}

output "frontend_bucket" {
  description = "S3 bucket name that stores the React build artifacts"
  value       = aws_s3_bucket.frontend.bucket
}

output "private_assets_bucket" {
  description = "S3 bucket used for private assets referenced by the backend and lambdas"
  value       = aws_s3_bucket.private_assets.bucket
}

output "database_endpoint" {
  description = "PostgreSQL endpoint hostname"
  value       = aws_db_instance.postgres.address
}

output "backend_ecr_repository" {
  description = "ECR repository URL for the backend container image"
  value       = aws_ecr_repository.backend.repository_url
}

output "lambda_ecr_repositories" {
  description = "Map of lambda logical names to their ECR repository URLs"
  value = {
    for name, repo in aws_ecr_repository.lambda :
    name => repo.repository_url
  }
}

output "lambda_function_names" {
  description = "Map of logical lambda identifiers to their deployed function names"
  value       = local.lambda_function_names
}

output "etl_uploads_bucket" {
  description = "S3 bucket name for ETL Excel file uploads"
  value       = aws_s3_bucket.etl_uploads.bucket
}


# Unified Client Deployment Script

## Overview

The `deploy-unified-client.ps1` script provides a complete, automated deployment solution for deploying the SCM-MAX stack (frontend, backend, and Lambda functions) for a new client.

## Features

✅ **Client-Wise Deployment**: Each client gets isolated infrastructure with unique resource names  
✅ **Unified Deployment**: Deploys frontend, backend, and all Lambda functions in one script  
✅ **Interactive Setup**: Prompts for all required information (client name, AWS creds, etc.)  
✅ **Configuration Management**: Saves client configuration to `{client-name}.auto.tfvars`  
✅ **Safe Isolation**: Uses client-prefixed resource names to avoid conflicts with existing deployments  
✅ **Automatic Lambda Configuration**: Backend automatically uses correct Lambda function names via environment variables

## Usage

### Basic Usage

```powershell
.\scripts\deploy-unified-client.ps1
```

The script will interactively prompt for:
- Client identifier
- AWS credentials (profile or access keys)
- S3 bucket names
- Database credentials
- Backend secrets
- Docker image tags

### With Parameters

```powershell
.\scripts\deploy-unified-client.ps1 -ClientName "client1" -AwsProfile "myprofile"
```

## What It Does

1. **Collects Configuration**: Prompts for all required settings
2. **Creates Config File**: Saves to `infrastructure/client-stack/clients/{client}.auto.tfvars`
3. **Phase 1 - ECR**: Creates ECR repositories for backend and Lambda functions
4. **Phase 2 - Build**: Builds and pushes Docker images for:
   - Backend (from `Apollo-v2/Dockerfile.production`)
   - All Lambda functions (from `Apollo-V2-Lambda/*/Dockerfile`)
5. **Phase 3 - Infrastructure**: Deploys complete infrastructure via Terraform:
   - VPC, subnets, security groups
   - RDS PostgreSQL database
   - ECS Fargate cluster and service
   - Application Load Balancer
   - Lambda functions (6 total)
   - S3 buckets (frontend + private assets)
   - CloudFront distribution
6. **Phase 4 - Frontend**: Builds and deploys React frontend to S3/CloudFront

## Client Configuration

After deployment, the client configuration is saved to:
```
infrastructure/client-stack/clients/{client-name}.auto.tfvars
```

Example:
```hcl
aws_region  = "us-east-1"
client_code = "client1"
environment = "prod"

private_assets_bucket_name = "client1-private-fastapi"
frontend_bucket_name       = "client1-frontend"

db_username = "postgres"
db_password = "***"
db_name     = "apollo"

backend_secret_key     = "***"
backend_session_secret = "***"
backend_image_tag      = "client1-prod"

lambda_image_tags = {
  "utility-function-v2" = "client1-prod"
  "forecast-model-v2"   = "client1-prod"
  # ... etc
}
```

## Lambda Function Names

The backend automatically receives Lambda function names as environment variables:

- `LAMBDA_UTILITY_FUNCTION` → `{client}-utility-function-v2`
- `LAMBDA_FORECAST_MODEL` → `{client}-forecast-model-v2`
- `LAMBDA_QUOTE_COMPARE` → `{client}-quote-compare-v2`
- `LAMBDA_CORRELATION` → `{client}-correlation-v2`
- `LAMBDA_READ_MAIL_INBOX` → `{client}-read-mail-inbox-v2`
- `LAMBDA_PRIVATE_DB_QUERY` → `{client}-private_db_query`

The backend code (`Apollo-v2/app/utils/aws_interface.py`) automatically uses these environment variables, falling back to default names for backward compatibility.

## Safety Features

- **Isolated Infrastructure**: Each client gets their own VPC and resources
- **Client-Prefixed Names**: All resources use `{client}-{resource}` naming
- **No Impact on Existing**: Existing deployments remain untouched
- **State Isolation**: Each client can use separate Terraform state

## Requirements

- Terraform >= 1.5.0
- AWS CLI
- Docker
- Node.js/npm
- PowerShell (Windows) or PowerShell Core

## Troubleshooting

### AWS Credentials
If you get authentication errors, verify your AWS credentials:
```powershell
aws sts get-caller-identity
```

### Docker Issues
Ensure Docker Desktop is running and has sufficient resources allocated.

### Terraform State
If deploying multiple clients, consider using Terraform workspaces:
```powershell
cd infrastructure\client-stack
terraform workspace new client1
terraform apply -var-file=clients\client1.auto.tfvars
```

### ECR Login
The script handles ECR login automatically, but if you need to do it manually:
```powershell
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin {account-id}.dkr.ecr.us-east-1.amazonaws.com
```

## Output

After successful deployment, you'll see:
- Backend ALB URL
- CloudFront domain
- S3 bucket names
- Lambda function names

Example:
```
Backend ALB URL     : http://client1-prod-alb-123456789.us-east-1.elb.amazonaws.com
CloudFront domain   : https://d1234567890.cloudfront.net
Frontend bucket     : s3://client1-frontend
Private assets bucket: s3://client1-private-fastapi
```

## Next Steps

1. Configure DNS to point to CloudFront (if using custom domain)
2. Set up CloudWatch alarms and monitoring
3. Configure RDS backups
4. Review security group rules
5. Set up CI/CD for automated updates

## Manual Deployment

If you prefer to deploy manually, see `infrastructure/client-stack/DEPLOYMENT.md` for step-by-step instructions.


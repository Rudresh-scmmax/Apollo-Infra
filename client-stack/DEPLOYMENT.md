# Unified Client Deployment Guide

This guide explains how to deploy the complete SCM-MAX stack (frontend, backend, and Lambda functions) for a new client using the unified deployment script.

## Overview

The unified deployment script (`scripts/deploy-unified-client.ps1`) automates the entire deployment process:

1. **Infrastructure Setup**: Creates VPC, RDS, ECS, Lambda functions, S3 buckets, and CloudFront distribution
2. **Backend Deployment**: Builds and deploys the FastAPI backend to ECS Fargate
3. **Lambda Deployment**: Builds and deploys all Lambda functions
4. **Frontend Deployment**: Builds and deploys the React frontend to S3/CloudFront

Each client gets their own isolated infrastructure with client-prefixed resource names, ensuring no interference with existing deployments.

## Prerequisites

- **Terraform** >= 1.5.0
- **AWS CLI** configured or credentials available
- **Docker** for building container images
- **Node.js/npm** for building the frontend
- **PowerShell** (Windows) or PowerShell Core (cross-platform)

## Quick Start

### 1. Run the Deployment Script

```powershell
cd C:\SCM-MAX-V2
.\scripts\deploy-unified-client.ps1
```

The script will prompt you for:
- **Client Name**: A unique identifier (e.g., "client1", "acme-corp")
- **Environment**: Deployment environment (default: "prod")
- **AWS Region**: AWS region to deploy to (default: "us-east-1")
- **AWS Credentials**: Either a named profile or access keys
- **S3 Bucket Names**: For frontend and private assets
- **Database Credentials**: PostgreSQL username and password
- **Backend Secrets**: SECRET_KEY and SESSION_SECRET_KEY
- **Docker Image Tags**: Tags for backend and Lambda images

### 2. Using Command Line Parameters

You can also provide some parameters directly:

```powershell
.\scripts\deploy-unified-client.ps1 -ClientName "client1" -AwsProfile "myprofile"
```

### 3. What Gets Created

The deployment creates:

- **Networking**: VPC with public/private subnets, NAT gateway, security groups
- **Database**: PostgreSQL RDS instance (encrypted, in private subnets)
- **Backend**: ECS Fargate service with Application Load Balancer
- **Lambda Functions**:
  - `{client}-utility-function-v2`
  - `{client}-forecast-model-v2`
  - `{client}-quote-compare-v2`
  - `{client}-correlation-v2`
  - `{client}-read-mail-inbox-v2`
  - `{client}-private_db_query`
- **Storage**: S3 buckets for frontend and private assets
- **CDN**: CloudFront distribution for frontend with API routing
- **ECR**: Container registries for backend and all Lambda functions

## Client Configuration Files

After the first deployment, a configuration file is created at:
```
infrastructure/client-stack/clients/{client-name}.auto.tfvars
```

This file contains all client-specific settings. You can edit it directly and re-run Terraform:

```powershell
cd infrastructure\client-stack
terraform apply -var-file=clients\client1.auto.tfvars
```

## Lambda Function Names

The backend automatically uses the correct Lambda function names through environment variables:

- `LAMBDA_UTILITY_FUNCTION` → `{client}-utility-function-v2`
- `LAMBDA_FORECAST_MODEL` → `{client}-forecast-model-v2`
- `LAMBDA_QUOTE_COMPARE` → `{client}-quote-compare-v2`
- `LAMBDA_CORRELATION` → `{client}-correlation-v2`
- `LAMBDA_READ_MAIL_INBOX` → `{client}-read-mail-inbox-v2`
- `LAMBDA_PRIVATE_DB_QUERY` → `{client}-private_db_query`

These are automatically set in the ECS task definition, so the backend code doesn't need changes.

## Deployment Phases

The script runs in 4 phases:

### Phase 1: ECR Repositories
Creates ECR repositories for backend and Lambda functions so images can be pushed.

### Phase 2: Build and Push Images
- Builds backend Docker image from `Apollo-v2/Dockerfile.production`
- Builds Lambda Docker images from `Apollo-V2-Lambda/*/Dockerfile`
- Pushes all images to their respective ECR repositories

### Phase 3: Infrastructure Deployment
Applies Terraform to create all AWS resources:
- VPC, subnets, security groups
- RDS database
- ECS cluster, task definition, service
- ALB and target groups
- Lambda functions
- S3 buckets
- CloudFront distribution

### Phase 4: Frontend Deployment
- Installs npm dependencies
- Builds React application
- Uploads to S3 bucket
- Invalidates CloudFront cache

## Updating an Existing Deployment

To update an existing client deployment:

1. **Update Infrastructure**:
   ```powershell
   cd infrastructure\client-stack
   terraform apply -var-file=clients\client1.auto.tfvars
   ```

2. **Rebuild and Push Images**:
   ```powershell
   # Build and push backend
   docker build -f Apollo-v2/Dockerfile.production -t {ecr-url}:{tag} Apollo-v2
   docker push {ecr-url}:{tag}
   
   # Build and push Lambda functions (repeat for each)
   docker build -t {lambda-ecr-url}:{tag} Apollo-V2-Lambda/{lambda-name}
   docker push {lambda-ecr-url}:{tag}
   ```

3. **Update ECS Service** (if backend image changed):
   ```powershell
   aws ecs update-service --cluster {client}-{env}-cluster --service {client}-{env}-service --force-new-deployment
   ```

4. **Update Frontend**:
   ```powershell
   cd SCM-MAX-REACT\app
   npm run build
   aws s3 sync dist s3://{frontend-bucket} --delete
   aws cloudfront create-invalidation --distribution-id {cf-id} --paths "/*"
   ```

## Isolation and Safety

- **Separate VPCs**: Each client gets their own VPC with unique CIDR blocks
- **Client-Prefixed Resources**: All resources are named with `{client}-{resource}`
- **Separate State**: Terraform state is stored per client (can use workspaces or separate state files)
- **No Cross-Client Access**: Security groups and IAM policies are scoped per client

## Troubleshooting

### Terraform State Conflicts
If deploying multiple clients, consider using Terraform workspaces:
```powershell
terraform workspace new client1
terraform apply -var-file=clients\client1.auto.tfvars
```

### Docker Build Failures
Ensure Docker is running and has enough resources allocated.

### ECR Login Issues
The script automatically logs in to ECR, but if you need to do it manually:
```powershell
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin {account-id}.dkr.ecr.us-east-1.amazonaws.com
```

### Frontend Build Issues
Ensure Node.js version matches the project requirements. Check `SCM-MAX-REACT/app/package.json`.

## Outputs

After deployment, Terraform outputs include:
- `alb_dns_name`: Backend API URL
- `cloudfront_domain`: Frontend CDN URL
- `frontend_bucket`: S3 bucket name
- `private_assets_bucket`: Private assets bucket name
- `database_endpoint`: RDS endpoint
- `lambda_function_names`: Map of logical names to actual Lambda function names

View outputs:
```powershell
cd infrastructure\client-stack
terraform output
```

## Cost Considerations

Each client deployment includes:
- RDS instance (db.t3.micro by default)
- NAT Gateway (~$32/month)
- ECS Fargate tasks (pay per use)
- Lambda functions (pay per invocation)
- S3 storage (minimal for static assets)
- CloudFront (pay per data transfer)

Consider using smaller instance types for non-production environments.

## Next Steps

After deployment:
1. Configure DNS to point to CloudFront distribution (if using custom domain)
2. Set up monitoring and alerts in CloudWatch
3. Configure backup policies for RDS
4. Set up CI/CD pipelines for automated deployments
5. Review and adjust security group rules as needed


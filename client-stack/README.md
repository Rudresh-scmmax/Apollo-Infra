# Unified Client Stack (Terraform)

This stack provisions everything needed to run the Apollo v2 backend (ECS + RDS), React frontend (S3 + CloudFront), and all Bedrock-powered Lambda workloads for a single client.  Each client receives its own VPC, networking, security groups, containers, Lambda functions, and storage buckets so that deployments stay isolated and your currently running infrastructure remains untouched.

## What gets created

- **Networking** – VPC with 2 public + 2 private subnets, NAT gateway, routing tables, and security groups purpose-built for ALB/ECS, Lambda, and RDS.
- **Data layer** – Encrypted PostgreSQL (RDS) with configurable class/storage, subnet group, and SG rules to allow only the ECS service + DB Lambda.
- **Compute** – Fargate-based ECS cluster, task definition, and service with an internet-facing ALB + target group that fronts the FastAPI backend.
- **Storage** – 
  - Private assets bucket used by the backend + AI Lambdas (replaces the hard-coded `private-bucket-fastapi`).
  - Static website bucket for the React build plus a CloudFront distribution with an API behavior that forwards `/api/*` to the ALB.
- **ECR** – One repo for the backend image and one per Lambda function.
- **Lambda** – Container-image Lambdas for:
  - `utility-function-v2`
  - `forecast-model-v2`
  - `quote-compare-v2`
  - `correlation-v2`
  - `read-mail-inbox-v2`
  - `private_db_query` (VPC-enabled + DB credentials)
- **IAM** – Task roles, execution roles, Lambda roles (with Bedrock + S3 permissions), and least-privilege policies so the backend can invoke the serverless functions.

All resources are tagged with the provided `client_code` + `environment` so they’re easy to trace per customer.

## Getting started

1. Create a new client variables file (see [`clients/client1.auto.tfvars.example`](./clients/client1.auto.tfvars.example)) and fill in:
   - `client_code`
   - unique S3 bucket names
   - DB credentials
   - backend secrets
   - Docker image tags you plan to push
   - optional Serper API key / custom domain
2. Run Terraform:

```powershell
cd infrastructure/client-stack
terraform init
# First pass (creates ECR so you can push images)
terraform apply -target=aws_ecr_repository.backend -target=aws_ecr_repository.lambda
# Build + push backend and lambda images using the repo URLs from terraform output
# Final apply
terraform apply
```

3. Build + deploy the React frontend:

```powershell
cd ..\..\SCM-MAX-REACT\app
npm install
npm run build
aws s3 sync dist s3://<frontend_bucket> --delete
aws cloudfront create-invalidation --distribution-id <id> --paths "/*"
```

4. Update your backend `.env` (or ECS env vars) using the outputs from Terraform (`database_url`, `alb_dns_name`, etc.).

## Client automation script

The forthcoming `deploy-client.ps1` helper (see project root `scripts/`) will:

1. Ask for the client name, AWS credentials/profile, DB/passwords, and bucket names.
2. Generate the tfvars file automatically.
3. Run the two-phase Terraform apply (ECR first, full stack second).
4. Build + push Docker images for the backend + every lambda using the existing Dockerfiles under `Apollo-v2` and `Apollo-V2-Lambda`.
5. Build the React frontend and upload it to the newly created bucket, then invalidate CloudFront.

You can still run the Terraform code manually if you prefer finer control.

## Key variables

| Variable | Purpose |
|----------|---------|
| `client_code` | Short slug prepended to all resource names |
| `frontend_bucket_name` | Target bucket for React build artifacts |
| `private_assets_bucket_name` | Bucket that replaces the legacy `private-bucket-fastapi` |
| `backend_image_tag` | Tag that will be pushed to the backend ECR repo |
| `lambda_image_tags` | Map of lambda logical names → image tag (defaults to `latest`) |
| `serper_api_key` | Passes the Google Serper key into quote-comparison + utility lambdas |

See `variables.tf` for the complete list plus defaults.

## Outputs

- `alb_dns_name` – base URL for the backend API (before CloudFront).
- `cloudfront_domain` – domain you can CNAME to your frontend.
- `frontend_bucket` / `private_assets_bucket` – handy for build scripts.
- `backend_ecr_repository` & `lambda_ecr_repositories` – feed these to Docker build/push steps.
- `lambda_function_names` – actual AWS Lambda names so the backend can reference them through environment variables.

## Notes & tips

- Every lambda uses the container images defined in `Apollo-V2-Lambda/*/Dockerfile`. Keep those Dockerfiles up-to-date with runtime dependencies (PyMuPDF, pytesseract, etc.).
- `private_db_query` now receives a unique function name per client; the supporting lambdas read the name from the `PRIVATE_DB_QUERY_FUNCTION` env var (falling back to the legacy value so existing deployments stay intact).
- The private assets bucket + env vars replace any hard-coded `private-bucket-fastapi` references, which lets you maintain separate storage per customer.
- If you enable a custom domain, make sure you request/validate the ACM certificate in **us-east-1** (CloudFront requirement) and supply its ARN via `acm_certificate_arn`.

Review the generated plan carefully before applying in production accounts. The stack is intentionally self-contained so you can spin up or tear down a full environment per client without risking currently deployed infrastructure.


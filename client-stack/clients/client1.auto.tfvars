aws_region  = "us-east-1"
client_code = "client1"
environment = "prod"

private_assets_bucket_name = "client1-private-fastapi"
frontend_bucket_name       = "client1-frontend"
frontend_domain            = ""
acm_certificate_arn        = ""

db_username = "client1"
db_password = "Client1Pass123"
db_name     = "apollo"
db_engine_version = "15.8"

backend_secret_key     = "client1@123"
backend_session_secret = "client1@123"
backend_image_tag      = "client1-prod"

lambda_image_tags = {
  "utility-function-v2" = "client1-prod"
  "forecast-model-v2"   = "client1-prod"
  "quote-compare-v2"    = "client1-prod"
  "correlation-v2"      = "client1-prod"
  "read-mail-inbox-v2"  = "client1-prod"
  "private_db_query"    = "client1-prod"
}

serper_api_key = ""

tags = {
  Owner       = "SupplyChain"
  ManagedBy   = "terraform"
  Client      = "client1"
  Environment = "prod"
}

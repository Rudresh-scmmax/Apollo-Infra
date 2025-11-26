# Client Deployment Variables
# Copy this file and rename it to match your client (e.g., client1.vars.ps1)
# Then use: .\scripts\deploy-unified-client.ps1 -ClientName "client1" -UseVarsFile

@{
    # Client Information
    ClientName   = "client1"
    Environment  = "prod"
    AwsRegion    = "us-east-1"
    
    # AWS Credentials (choose one method)
    # Option 1: Use AWS Profile
    UseAwsProfile = $true
    AwsProfile    = "default"
    
    # Option 2: Use Access Keys (set UseAwsProfile = $false)
    # UseAwsProfile = $false
    # AwsAccessKeyId = "YOUR_ACCESS_KEY"
    # AwsSecretAccessKey = "YOUR_SECRET_KEY"  # Will be prompted if not set
    # AwsSessionToken = ""  # Optional, for STS
    
    # S3 Buckets
    PrivateAssetsBucket = "client1-private-fastapi"
    FrontendBucket      = "client1-frontend"
    
    # Custom Domain (optional)
    FrontendDomain = ""
    AcmCertificateArn = ""
    
    # Database Configuration
    DbUsername = "client1"
    DbPassword = "client1@123"  # Will be prompted if not set or empty
    DbName     = "apollo"
    DbEngineVersion = "15.3"  # PostgreSQL engine version (default: 15.3)
    
    # Backend Secrets
    BackendSecretKey     = "client1@123"  # Will be prompted if not set or empty
    BackendSessionSecret = "client1@123"  # Will be prompted if not set or empty
    
    # Docker Image Tags
    BackendImageTag = "client1-prod"
    LambdaImageTag  = "client1-prod"
    
    # Optional API Keys
    SerperApiKey = ""
}


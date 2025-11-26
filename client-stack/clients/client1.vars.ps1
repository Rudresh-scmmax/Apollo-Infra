# Client Deployment Variables for client1
# This file contains the deployment configuration for client1

@{
    # Client Information
    ClientName   = "client1"
    Environment  = "prod"
    AwsRegion    = "us-east-1"
    
    # AWS Credentials - Using AWS Profile
    UseAwsProfile = $true
    AwsProfile    = "default"
    
    # S3 Buckets
    PrivateAssetsBucket = "client1-private-fastapi"
    FrontendBucket      = "client1-frontend"
    
    # Custom Domain (optional)
    FrontendDomain = ""
    AcmCertificateArn = ""
    
    # Database Configuration
    DbUsername = "client1"
    DbPassword = "Client1Pass123"  # RDS password: only printable ASCII except '/', '@', '"', ' ' (spaces)
    DbName     = "apollo"
    DbEngineVersion = "15.8"  # PostgreSQL engine version (15.8 is the latest available)
    
    # Backend Secrets
    BackendSecretKey     = "client1@123"
    BackendSessionSecret = "client1@123"
    
    # Docker Image Tags
    BackendImageTag = "client1-prod"
    LambdaImageTag  = "client1-prod"
    
    # Optional API Keys
    SerperApiKey = ""
}


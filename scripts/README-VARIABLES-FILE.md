# Using Variables Files for Deployment

Instead of entering all parameters interactively, you can create a variables file to store your deployment configuration.

## Quick Start

1. **Copy the example file:**
   ```powershell
   Copy-Item infrastructure\client-stack\clients\client1.vars.example.ps1 infrastructure\client-stack\clients\client1.vars.ps1
   ```

2. **Edit the file** with your client-specific values

3. **Run deployment with variables file:**
   ```powershell
   .\scripts\deploy-unified-client.ps1 -ClientName "client1" -UseVarsFile
   ```

## Variables File Format

The variables file is a PowerShell script that returns a hashtable. Example:

```powershell
@{
    # Client Information
    ClientName   = "client1"
    Environment  = "prod"
    AwsRegion    = "us-east-1"
    
    # AWS Credentials (choose one method)
    UseAwsProfile = $true
    AwsProfile    = "default"
    
    # OR use access keys (set UseAwsProfile = $false)
    # UseAwsProfile = $false
    # AwsAccessKeyId = "YOUR_ACCESS_KEY"
    # AwsSecretAccessKey = "YOUR_SECRET_KEY"
    
    # S3 Buckets
    PrivateAssetsBucket = "client1-private-fastapi"
    FrontendBucket      = "client1-frontend"
    
    # Database Configuration
    DbUsername = "client1"
    DbPassword = "client1@123"
    DbName     = "apollo"
    
    # Backend Secrets
    BackendSecretKey     = "client1@123"
    BackendSessionSecret = "client1@123"
    
    # Docker Image Tags
    BackendImageTag = "client1-prod"
    LambdaImageTag  = "client1-prod"
}
```

## Required Variables

- `ClientName` - Client identifier
- `Environment` - Deployment environment (e.g., "prod", "dev")
- `AwsRegion` - AWS region
- `PrivateAssetsBucket` - S3 bucket for private assets
- `FrontendBucket` - S3 bucket for frontend
- `DbUsername` - Database username
- `BackendImageTag` - Docker image tag for backend
- `LambdaImageTag` - Docker image tag for Lambda functions

## Optional Variables

- `DbPassword` - If not set, will prompt
- `BackendSecretKey` - If not set, will prompt
- `BackendSessionSecret` - If not set, will prompt
- `FrontendDomain` - Custom domain for frontend
- `AcmCertificateArn` - ACM certificate ARN (required if FrontendDomain is set)
- `SerperApiKey` - Optional API key
- `DbName` - Defaults to "apollo" if not set

## AWS Credentials

You can use either method:

### Option 1: AWS Profile (Recommended)
```powershell
UseAwsProfile = $true
AwsProfile    = "default"
```

### Option 2: Access Keys
```powershell
UseAwsProfile = $false
AwsAccessKeyId = "YOUR_ACCESS_KEY"
AwsSecretAccessKey = "YOUR_SECRET_KEY"  # Will prompt if not set
AwsSessionToken = ""  # Optional, for STS
```

**Security Note:** For sensitive values like passwords and API keys, you can leave them empty in the file and the script will prompt for them interactively.

## Usage Examples

### Using Default Variables File Location
```powershell
# Looks for: infrastructure\client-stack\clients\client1.vars.ps1
.\scripts\deploy-unified-client.ps1 -ClientName "client1" -UseVarsFile
```

### Using Custom Variables File Path
```powershell
.\scripts\deploy-unified-client.ps1 -ClientName "client1" -VarsFile ".\my-custom-vars.ps1"
```

### Interactive Mode (No Variables File)
```powershell
.\scripts\deploy-unified-client.ps1 -ClientName "client1"
```

## File Location

By default, variables files are stored in:
```
infrastructure/client-stack/clients/{client-name}.vars.ps1
```

Example:
- `infrastructure/client-stack/clients/client1.vars.ps1`
- `infrastructure/client-stack/clients/client2.vars.ps1`

## Security Best Practices

1. **Don't commit sensitive values** - Use `.gitignore` to exclude `.vars.ps1` files
2. **Use AWS Profiles** - Prefer AWS profiles over hardcoded access keys
3. **Prompt for secrets** - Leave passwords/keys empty in the file to be prompted
4. **Use environment variables** - For CI/CD, consider using environment variables instead

## Example .gitignore Entry

```
# Exclude client variables files (may contain secrets)
infrastructure/client-stack/clients/*.vars.ps1
!infrastructure/client-stack/clients/*.vars.example.ps1
```


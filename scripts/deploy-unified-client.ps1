<#
.SYNOPSIS
    Unified deployment script for SCM-MAX frontend, backend, and Lambda functions per client.

.DESCRIPTION
    This script deploys the complete stack for a client:
    - Prompts for client name and AWS credentials
    - Creates/updates Terraform configuration for the client
    - Deploys infrastructure (VPC, RDS, ECS, Lambda, S3, CloudFront)
    - Builds and pushes Docker images for backend and all Lambda functions
    - Builds and deploys the React frontend
    - Configures Lambda function names in backend environment variables

.PARAMETER ClientName
    Client identifier (letters/numbers/hyphens). If not provided, will prompt.

.PARAMETER AwsProfile
    AWS named profile to use. If not provided, will prompt for credentials.

.PARAMETER UseVarsFile
    If specified, will look for a variables file at infrastructure\client-stack\clients\{ClientName}.vars.ps1
    If the file exists, it will load all configuration from it. Otherwise, falls back to interactive mode.

.PARAMETER VarsFile
    Path to a custom variables file. If specified, loads configuration from this file instead of prompting.
    The file should return a hashtable. See client1.vars.example.ps1 for format.

.EXAMPLE
    # Interactive mode - prompts for all values
    .\deploy-unified-client.ps1 -ClientName "client1" -AwsProfile "myprofile"
    
.EXAMPLE
    # Use variables file (looks for client-stack\clients\client1.vars.ps1)
    .\deploy-unified-client.ps1 -ClientName "client1" -UseVarsFile
    
.EXAMPLE
    # Use custom variables file path
    .\deploy-unified-client.ps1 -ClientName "client1" -VarsFile ".\custom-vars.ps1"
#>

[CmdletBinding()]
param(
    [string]$ClientName,
    [string]$AwsProfile,
    [switch]$UseVarsFile,
    [string]$VarsFile
)

function ConvertFrom-SecureStringPlain {
    param([System.Security.SecureString]$SecureString)
    if (-not $SecureString) { return "" }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Command '$Name' was not found on PATH. Please install it before rerunning the script."
    }
}

function Invoke-CheckedCommand {
    param(
        [string]$Title,
        [scriptblock]$Block
    )

    Write-Host ""
    Write-Host "==> $Title" -ForegroundColor Cyan
    & $Block
    if ($LASTEXITCODE -ne 0) {
        throw "Step '$Title' failed with exit code $LASTEXITCODE"
    }
}

function Get-TerraformOutputRaw {
    param(
        [string]$Name,
        [string]$Chdir = $null
    )

    $args = @()
    if ($Chdir) {
        $args += "-chdir=$Chdir"
    }
    $args += @("output", "-raw", $Name)

    $result = & terraform @args
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read terraform output '$Name'"
    }

    return $result.Trim()
}

function Load-VariablesFromFile {
    param(
        [string]$FilePath,
        [string]$ClientName
    )
    
    if (-not (Test-Path $FilePath)) {
        throw "Variables file not found: $FilePath"
    }
    
    Write-Host "Loading variables from: $FilePath" -ForegroundColor Cyan
    $vars = & $FilePath
    
    if (-not $vars -or $vars -isnot [hashtable]) {
        throw "Variables file must return a hashtable. See client1.vars.example.ps1 for format."
    }
    
    # Validate required fields
    $requiredFields = @("ClientName", "Environment", "AwsRegion", "PrivateAssetsBucket", "FrontendBucket", 
                        "DbUsername", "BackendImageTag", "LambdaImageTag")
    foreach ($field in $requiredFields) {
        if (-not $vars.ContainsKey($field) -or [string]::IsNullOrWhiteSpace($vars[$field])) {
            throw "Required variable '$field' is missing or empty in variables file."
        }
    }
    
    # Set defaults for optional fields
    if (-not $vars.ContainsKey("DbName")) { $vars["DbName"] = "apollo" }
    if (-not $vars.ContainsKey("FrontendDomain")) { $vars["FrontendDomain"] = "" }
    if (-not $vars.ContainsKey("AcmCertificateArn")) { $vars["AcmCertificateArn"] = "" }
    if (-not $vars.ContainsKey("SerperApiKey")) { $vars["SerperApiKey"] = "" }
    if (-not $vars.ContainsKey("UseAwsProfile")) { $vars["UseAwsProfile"] = $false }
    
    return $vars
}

# Script is in infrastructure/scripts, so repo root is two levels up
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repoRoot

try {
    # Check required commands
    $requiredCommands = @("terraform", "aws", "docker", "npm")
    foreach ($cmd in $requiredCommands) {
        Require-Command -Name $cmd
    }
    
    # Verify Docker is running
    Write-Host "Checking Docker daemon..." -ForegroundColor Cyan
    $dockerRunning = docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker is not running. Please start Docker Desktop and try again."
    }
    Write-Host "Docker is running" -ForegroundColor Green

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  SCM-MAX Unified Client Deployment" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""

    # Determine variables file path
    $vars = $null
    $varsFilePath = $null
    
    if ($VarsFile) {
        $varsFilePath = $VarsFile
        if (-not [System.IO.Path]::IsPathRooted($varsFilePath)) {
            $varsFilePath = Join-Path $repoRoot $varsFilePath
        }
        $vars = Load-VariablesFromFile -FilePath $varsFilePath -ClientName $ClientName
        $ClientName = $vars["ClientName"]
    } elseif ($UseVarsFile -or $ClientName) {
        # Try to find variables file
        if (-not $ClientName) {
            $ClientName = Read-Host "Client identifier (letters/numbers/hyphens, e.g., 'client1')"
        }
        $clientSlug = ($ClientName -replace "\s+", "-").ToLower()
        $defaultVarsPath = Join-Path $repoRoot "infrastructure\client-stack\clients\$clientSlug.vars.ps1"
        
        if ($UseVarsFile -and (Test-Path $defaultVarsPath)) {
            $varsFilePath = $defaultVarsPath
            $vars = Load-VariablesFromFile -FilePath $varsFilePath -ClientName $ClientName
            $ClientName = $vars["ClientName"]
        } elseif ($UseVarsFile) {
            Write-Warning "Variables file not found at: $defaultVarsPath"
            Write-Host "Falling back to interactive mode..." -ForegroundColor Yellow
        }
    }

    # Get client information (from vars file or prompt)
    if ($vars) {
        $ClientName = $vars["ClientName"]
        $environment = $vars["Environment"]
        $region = $vars["AwsRegion"]
        $privateBucket = $vars["PrivateAssetsBucket"]
        $frontendBucket = $vars["FrontendBucket"]
        $frontendDomain = $vars["FrontendDomain"]
        $acmArn = $vars["AcmCertificateArn"]
        $dbUser = $vars["DbUsername"]
        $dbPassword = if ($vars.ContainsKey("DbPassword") -and $vars["DbPassword"]) { 
            $vars["DbPassword"] 
        } else { 
            ConvertFrom-SecureStringPlain -SecureString (Read-Host "Database password" -AsSecureString)
        }
        $dbName = $vars["DbName"]
        $dbEngineVersion = if ($vars.ContainsKey("DbEngineVersion") -and $vars["DbEngineVersion"]) {
            $vars["DbEngineVersion"]
        } else {
            "15.8"  # Default to 15.8 (latest available PostgreSQL 15.x version)
        }
        $backendSecret = if ($vars.ContainsKey("BackendSecretKey") -and $vars["BackendSecretKey"]) { 
            $vars["BackendSecretKey"] 
        } else { 
            ConvertFrom-SecureStringPlain -SecureString (Read-Host "Backend SECRET_KEY" -AsSecureString)
        }
        $sessionSecret = if ($vars.ContainsKey("BackendSessionSecret") -and $vars["BackendSessionSecret"]) { 
            $vars["BackendSessionSecret"] 
        } else { 
            ConvertFrom-SecureStringPlain -SecureString (Read-Host "Backend SESSION_SECRET_KEY" -AsSecureString)
        }
        $serperKey = $vars["SerperApiKey"]
        $backendImageTag = $vars["BackendImageTag"]
        $lambdaTag = $vars["LambdaImageTag"]
        $useProfile = $vars["UseAwsProfile"]
        $AwsProfile = if ($vars.ContainsKey("AwsProfile")) { $vars["AwsProfile"] } else { "" }
        
        if ($useProfile) {
            if (-not $AwsProfile) {
                $AwsProfile = Read-Host "AWS Profile name"
            }
            $env:AWS_PROFILE = $AwsProfile
            Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
            Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
            Write-Host "Using AWS profile: $AwsProfile" -ForegroundColor Yellow
        } else {
            $accessKey = if ($vars.ContainsKey("AwsAccessKeyId") -and $vars["AwsAccessKeyId"]) {
                $vars["AwsAccessKeyId"]
            } else {
                Read-Host "AWS Access Key ID"
            }
            $secretKeyPlain = if ($vars.ContainsKey("AwsSecretAccessKey") -and $vars["AwsSecretAccessKey"]) {
                $vars["AwsSecretAccessKey"]
            } else {
                $secretKey = Read-Host "AWS Secret Access Key" -AsSecureString
                ConvertFrom-SecureStringPlain -SecureString $secretKey
            }
            $sessionToken = if ($vars.ContainsKey("AwsSessionToken")) { $vars["AwsSessionToken"] } else { "" }
            
            if (-not $accessKey -or -not $secretKeyPlain) {
                throw "AWS credentials are required."
            }
            
            $env:AWS_PROFILE = $null
            $env:AWS_ACCESS_KEY_ID = $accessKey
            $env:AWS_SECRET_ACCESS_KEY = $secretKeyPlain
            if ($sessionToken) {
                $env:AWS_SESSION_TOKEN = $sessionToken
            } else {
                Remove-Item Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
            }
            Write-Host "Using AWS access key: $accessKey" -ForegroundColor Yellow
        }
    } else {
        # Interactive mode - get client information
        if (-not $ClientName) {
            $ClientName = Read-Host "Client identifier (letters/numbers/hyphens, e.g., 'client1')"
        }
        if (-not $ClientName) {
            throw "Client identifier is required."
        }

        $environment = Read-Host "Environment label [prod]"
        if (-not $environment) { $environment = "prod" }

        $region = Read-Host "AWS region [us-east-1]"
        if (-not $region) { $region = "us-east-1" }

        # AWS Credentials
        $useProfile = $false
        if ($AwsProfile) {
            $useProfile = $true
        } else {
            $profileChoice = Read-Host "Use an existing AWS named profile? (y/N)"
            if ($profileChoice -match "^(y|yes)$") {
                $useProfile = $true
                $AwsProfile = Read-Host "Profile name"
            }
        }

        if ($useProfile) {
            if (-not $AwsProfile) {
                throw "AWS profile name cannot be empty."
            }
            $env:AWS_PROFILE = $AwsProfile
            Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
            Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
            Write-Host "Using AWS profile: $AwsProfile" -ForegroundColor Yellow
        } else {
            $accessKey = Read-Host "AWS Access Key ID"
            $secretKey = Read-Host "AWS Secret Access Key" -AsSecureString
            $secretKeyPlain = ConvertFrom-SecureStringPlain -SecureString $secretKey
            $sessionToken = Read-Host "AWS Session Token (press enter if not using STS)"

            if (-not $accessKey -or -not $secretKeyPlain) {
                throw "AWS credentials are required."
            }

            $env:AWS_PROFILE = $null
            $env:AWS_ACCESS_KEY_ID = $accessKey
            $env:AWS_SECRET_ACCESS_KEY = $secretKeyPlain
            if ($sessionToken) {
                $env:AWS_SESSION_TOKEN = $sessionToken
            } else {
                Remove-Item Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
            }
            Write-Host "Using AWS access key: $accessKey" -ForegroundColor Yellow
        }
    }

    $clientSlug = ($ClientName -replace "\s+", "-").ToLower()
    Write-Host "Client: $clientSlug" -ForegroundColor Yellow

    # Verify AWS credentials
    Write-Host ""
    Write-Host "Verifying AWS credentials..." -ForegroundColor Cyan
    
    # First, test basic network connectivity to AWS STS endpoint
    $stsEndpoint = "sts.$region.amazonaws.com"
    Write-Host "Testing connectivity to AWS STS endpoint: $stsEndpoint" -ForegroundColor Gray
    try {
        $dnsTest = Resolve-DnsName -Name $stsEndpoint -ErrorAction Stop -Type A
        Write-Host "DNS resolution: OK" -ForegroundColor Gray
    } catch {
        Write-Warning "DNS resolution failed for $stsEndpoint"
        Write-Warning "This may indicate a network connectivity issue."
    }
    
    # Attempt to verify credentials
    $awsAccount = aws sts get-caller-identity --query Account --output text 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errorOutput = $awsAccount -join "`n"
        
        # Check for network connectivity issues
        if ($errorOutput -match "Could not connect|Unable to locate credentials|network|connection|timeout|resolve|DNS|no such host") {
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Red
            Write-Host "  Network Connectivity Issue Detected" -ForegroundColor Red
            Write-Host "========================================" -ForegroundColor Red
            Write-Host ""
            Write-Host "Error details:" -ForegroundColor Yellow
            Write-Host $errorOutput -ForegroundColor Red
            Write-Host ""
            Write-Host "Troubleshooting steps:" -ForegroundColor Yellow
            Write-Host "  1. Check your internet connection" -ForegroundColor White
            Write-Host "  2. Verify DNS resolution:" -ForegroundColor White
            Write-Host "     Resolve-DnsName sts.$region.amazonaws.com" -ForegroundColor Gray
            Write-Host "  3. Test HTTPS connectivity:" -ForegroundColor White
            Write-Host "     Test-NetConnection -ComputerName sts.$region.amazonaws.com -Port 443" -ForegroundColor Gray
            Write-Host "  4. Check if VPN/proxy is blocking AWS endpoints" -ForegroundColor White
            Write-Host "  5. Verify firewall allows HTTPS (port 443) to AWS" -ForegroundColor White
            Write-Host "  6. If using a proxy, configure AWS CLI:" -ForegroundColor White
            Write-Host "     aws configure set proxy.http http://proxy:port" -ForegroundColor Gray
            Write-Host "     aws configure set proxy.https https://proxy:port" -ForegroundColor Gray
            Write-Host ""
            Write-Host "Current AWS configuration:" -ForegroundColor Yellow
            if ($env:AWS_PROFILE) {
                Write-Host "  AWS_PROFILE: $env:AWS_PROFILE" -ForegroundColor Gray
            }
            if ($env:AWS_ACCESS_KEY_ID) {
                Write-Host "  AWS_ACCESS_KEY_ID: $($env:AWS_ACCESS_KEY_ID.Substring(0,4))..." -ForegroundColor Gray
            }
            Write-Host "  Region: $region" -ForegroundColor Gray
            Write-Host ""
            throw "Failed to verify AWS credentials due to network connectivity issue. Please check the troubleshooting steps above."
        }
        
        # Check for credential issues
        if ($errorOutput -match "InvalidClientTokenId|SignatureDoesNotMatch|InvalidAccessKeyId|AccessDenied") {
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Red
            Write-Host "  AWS Credential Error" -ForegroundColor Red
            Write-Host "========================================" -ForegroundColor Red
            Write-Host ""
            Write-Host "Error details:" -ForegroundColor Yellow
            Write-Host $errorOutput -ForegroundColor Red
            Write-Host ""
            Write-Host "The AWS credentials appear to be invalid or expired." -ForegroundColor Yellow
            Write-Host "Please verify:" -ForegroundColor Yellow
            Write-Host "  1. AWS Access Key ID is correct" -ForegroundColor White
            Write-Host "  2. AWS Secret Access Key is correct" -ForegroundColor White
            Write-Host "  3. AWS Session Token (if using) is not expired" -ForegroundColor White
            Write-Host "  4. AWS profile (if using) is configured correctly" -ForegroundColor White
            Write-Host ""
            throw "Failed to verify AWS credentials. Please check your credentials and try again."
        }
        
        # Generic error
        Write-Host ""
        Write-Host "Error details:" -ForegroundColor Yellow
        Write-Host $errorOutput -ForegroundColor Red
        throw "Failed to verify AWS credentials: $errorOutput"
    }
    Write-Host "AWS Account: $awsAccount" -ForegroundColor Green
    
    # Test AWS service connectivity
    Write-Host ""
    Write-Host "Testing AWS service connectivity..." -ForegroundColor Cyan
    try {
        $testResult = aws ecr describe-repositories --region $region --max-items 1 2>&1
        if ($LASTEXITCODE -ne 0 -and $testResult -match "no such host|network|connection|timeout") {
            Write-Warning "Network connectivity issue detected. Error: $testResult"
            Write-Warning "Please check your internet connection, DNS settings, VPN, or firewall."
            Write-Warning "You may need to:"
            Write-Warning "  1. Check your internet connection"
            Write-Warning "  2. Verify DNS resolution (try: Resolve-DnsName api.ecr.$region.amazonaws.com)"
            Write-Warning "  3. Check if VPN/proxy is blocking AWS endpoints"
            Write-Warning "  4. Verify firewall allows HTTPS (port 443) to AWS"
            throw "Cannot connect to AWS services. Please fix network connectivity and try again."
        }
        Write-Host "AWS service connectivity: OK" -ForegroundColor Green
    } catch {
        if ($_.Exception.Message -match "Cannot connect") {
            throw
        }
        # If it's a different error (like no repos), that's fine - connectivity is working
        Write-Host "AWS service connectivity: OK" -ForegroundColor Green
    }

    # Get remaining configuration (if not loaded from vars file)
    if (-not $vars) {
        # S3 Bucket names
        $privateBucketDefault = "$clientSlug-private-fastapi"
        $frontendBucketDefault = "$clientSlug-frontend"
        $privateBucket = Read-Host "Private assets bucket [$privateBucketDefault]"
        if (-not $privateBucket) { $privateBucket = $privateBucketDefault }
        $frontendBucket = Read-Host "Frontend bucket [$frontendBucketDefault]"
        if (-not $frontendBucket) { $frontendBucket = $frontendBucketDefault }

        # Optional custom domain
        $frontendDomain = Read-Host "Custom frontend domain (leave blank to skip)"
        $acmArn = ""
        if ($frontendDomain) {
            $acmArn = Read-Host "ACM certificate ARN in us-east-1 for $frontendDomain"
        }

        # Database configuration
        $dbUserDefault = "postgres"
        $dbUser = Read-Host "Database username [$dbUserDefault]"
        if (-not $dbUser) { $dbUser = $dbUserDefault }
        $dbPassword = ConvertFrom-SecureStringPlain -SecureString (Read-Host "Database password" -AsSecureString)
        if (-not $dbPassword) {
            throw "Database password is required."
        }
        $dbName = "apollo"
        $dbEngineVersionDefault = "15.8"
        $dbEngineVersion = Read-Host "PostgreSQL engine version [$dbEngineVersionDefault]"
        if (-not $dbEngineVersion) { $dbEngineVersion = $dbEngineVersionDefault }

        # Backend secrets
        $backendSecret = ConvertFrom-SecureStringPlain -SecureString (Read-Host "Backend SECRET_KEY" -AsSecureString)
        if (-not $backendSecret) {
            throw "Backend SECRET_KEY is required."
        }
        $sessionSecret = ConvertFrom-SecureStringPlain -SecureString (Read-Host "Backend SESSION_SECRET_KEY" -AsSecureString)
        if (-not $sessionSecret) {
            throw "Backend SESSION_SECRET_KEY is required."
        }

        # Optional Serper API key
        $serperKey = Read-Host "Serper API key (optional, press enter to skip)"

        # Docker image tags
        $imageTagDefault = "$clientSlug-$environment"
        $backendImageTag = Read-Host "Backend Docker image tag [$imageTagDefault]"
        if (-not $backendImageTag) { $backendImageTag = $imageTagDefault }

        $lambdaTag = Read-Host "Lambda image tag (defaults to backend tag) [$backendImageTag]"
        if (-not $lambdaTag) { $lambdaTag = $backendImageTag }
    } else {
        # Loaded from vars file - handle optional custom domain ACM
        if ($frontendDomain -and -not $acmArn) {
            $acmArn = Read-Host "ACM certificate ARN in us-east-1 for $frontendDomain (leave blank to skip)"
        }
    }

    # Create client configuration directory if it doesn't exist
    $clientsDir = Join-Path $repoRoot "infrastructure\client-stack\clients"
    if (-not (Test-Path $clientsDir)) {
        New-Item -ItemType Directory -Path $clientsDir -Force | Out-Null
    }

    # Generate Terraform variables file
    $tfvarsPath = Join-Path $clientsDir "$clientSlug.auto.tfvars"
    $tfvarsContent = @"
aws_region  = "$region"
client_code = "$clientSlug"
environment = "$environment"

private_assets_bucket_name = "$privateBucket"
frontend_bucket_name       = "$frontendBucket"
frontend_domain            = "$frontendDomain"
acm_certificate_arn        = "$acmArn"

db_username = "$dbUser"
db_password = "$dbPassword"
db_name     = "apollo"
db_engine_version = "$dbEngineVersion"

backend_secret_key     = "$backendSecret"
backend_session_secret = "$sessionSecret"
backend_image_tag      = "$backendImageTag"

lambda_image_tags = {
  "utility-function-v2" = "$lambdaTag"
  "forecast-model-v2"   = "$lambdaTag"
  "quote-compare-v2"    = "$lambdaTag"
  "correlation-v2"      = "$lambdaTag"
  "read-mail-inbox-v2"  = "$lambdaTag"
  "private_db_query"    = "$lambdaTag"
  "etl"                 = "$lambdaTag"
}

serper_api_key = "$serperKey"

tags = {
  Owner       = "SupplyChain"
  ManagedBy   = "terraform"
  Client      = "$clientSlug"
  Environment = "$environment"
}
"@

    Set-Content -Path $tfvarsPath -Value $tfvarsContent -Encoding UTF8
    Write-Host ""
    Write-Host "[OK] Created client configuration: $tfvarsPath" -ForegroundColor Green

    # Navigate to infrastructure directory
    $infraDir = Join-Path $repoRoot "infrastructure\client-stack"
    Push-Location $infraDir

    # Initialize Terraform
    Invoke-CheckedCommand -Title "Initializing Terraform" -Block { 
        terraform init 
    }

    $varFile = "clients/$clientSlug.auto.tfvars"

    # Phase 1: Create ECR repositories first
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Phase 1: Creating ECR Repositories" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    # Build target list for ECR repositories
    $lambdaSource = @{
        "utility-function-v2" = "Apollo-V2-Lambda/Utility_function"
        "forecast-model-v2"   = "Apollo-V2-Lambda/forecast_model"
        "quote-compare-v2"    = "Apollo-V2-Lambda/Quote_compare"
        "correlation-v2"      = "Apollo-V2-Lambda/Correlation_price"
        "read-mail-inbox-v2"  = "Apollo-V2-Lambda/Read_mail_inbox"
        "private_db_query"    = "Apollo-V2-Lambda/Private_db_query"
        "etl"                 = "Apollo-DB-ETL"
    }
    
    # Build target list - Target all ECR repositories
    # Since targeting for_each resources with quotes is problematic in PowerShell,
    # we'll target the resource types and let Terraform create all instances
    $targets = @(
        "-target=aws_ecr_repository.backend",
        "-target=aws_ecr_repository.lambda"
    )
    
    Invoke-CheckedCommand -Title "Create ECR repositories" -Block {
        # Build terraform command arguments
        $terraformArgs = @("apply")
        $terraformArgs += $targets
        $terraformArgs += "-auto-approve"
        $terraformArgs += "-var-file=$varFile"
        
        # Execute terraform - this will create all ECR repositories (backend + all lambda repos)
        & terraform $terraformArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Terraform apply failed"
        }
    }

    # Get ECR repository URLs
    $backendRepo = Get-TerraformOutputRaw -Name "backend_ecr_repository"
    $lambdaReposJson = terraform output -json lambda_ecr_repositories
    $lambdaRepos = $lambdaReposJson | ConvertFrom-Json

    if (-not $backendRepo) {
        throw "Unable to read backend ECR repository URL from terraform output."
    }

    Write-Host ""
    Write-Host "Backend ECR: $backendRepo" -ForegroundColor Green
    Write-Host "Lambda ECR repositories created" -ForegroundColor Green

    # Login to ECR
    $registryHost = ($backendRepo -split "/")[0]
    Invoke-CheckedCommand -Title "Login to ECR" -Block {
        # Get ECR password - capture stdout only, not stderr
        $ecrPassword = aws ecr get-login-password --region $region 2>$null
        if ($LASTEXITCODE -ne 0) {
            $errorOutput = aws ecr get-login-password --region $region 2>&1
            $errorMsg = $errorOutput -join "`n"
            throw "Failed to get ECR login password: $errorMsg"
        }
        
        # Trim any whitespace
        $ecrPassword = $ecrPassword.Trim()
        
        if ([string]::IsNullOrWhiteSpace($ecrPassword)) {
            throw "ECR login password is empty"
        }
        
        # Configure Docker daemon.json to bypass proxy for ECR endpoints
        # This fixes the 400 Bad Request error caused by Docker Desktop proxy
        $daemonJsonPath = "$env:USERPROFILE\.docker\daemon.json"
        if (Test-Path $daemonJsonPath) {
            try {
                $content = Get-Content $daemonJsonPath -Raw
                $json = $content | ConvertFrom-Json
                $needsUpdate = $false
                
                if (-not $json.PSObject.Properties['proxies']) {
                    $json | Add-Member -MemberType NoteProperty -Name "proxies" -Value (New-Object PSObject)
                    $needsUpdate = $true
                }
                
                if (-not $json.proxies.PSObject.Properties['no_proxy']) {
                    $json.proxies | Add-Member -MemberType NoteProperty -Name "no_proxy" -Value @()
                    $needsUpdate = $true
                }
                
                $noProxyList = @($json.proxies.no_proxy)
                $ecrPattern = "*.dkr.ecr.*.amazonaws.com"
                if ($noProxyList -notcontains $ecrPattern) {
                    $noProxyList += $ecrPattern
                    $json.proxies.no_proxy = $noProxyList
                    $needsUpdate = $true
                }
                
                if ($needsUpdate) {
                    $json | ConvertTo-Json -Depth 10 | Set-Content $daemonJsonPath
                    Write-Host "Updated Docker daemon.json to bypass proxy for ECR endpoints" -ForegroundColor Yellow
                    Write-Host "Note: You may need to restart Docker Desktop for changes to take effect" -ForegroundColor Yellow
                }
            } catch {
                Write-Warning "Could not update Docker daemon.json: $($_.Exception.Message)"
            }
        }
        
        # Docker login with ECR - use --password flag to avoid PowerShell piping/newline issues
        # This approach avoids the 400 Bad Request error caused by newline characters in piped input
        # Note: Using --password shows a warning but works reliably in PowerShell
        docker login --username AWS --password $ecrPassword $registryHost 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Yellow
            Write-Host "  Docker ECR Login Failed" -ForegroundColor Yellow
            Write-Host "========================================" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "This error is often caused by Docker Desktop proxy configuration." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "If you just updated daemon.json, please:" -ForegroundColor Yellow
            Write-Host "  1. Restart Docker Desktop" -ForegroundColor White
            Write-Host "  2. Run this script again" -ForegroundColor White
            Write-Host ""
            Write-Host "Alternatively, configure Docker Desktop manually:" -ForegroundColor Yellow
            Write-Host "  1. Open Docker Desktop" -ForegroundColor White
            Write-Host "  2. Go to Settings > Resources > Proxies" -ForegroundColor White
            Write-Host "  3. Add to 'Bypass these hosts': *.dkr.ecr.*.amazonaws.com" -ForegroundColor White
            Write-Host "  4. Or disable the proxy if not needed" -ForegroundColor White
            Write-Host ""
            throw "Docker login failed. See instructions above to fix proxy configuration."
        }
    }

    # Phase 2: Build and push Docker images
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Phase 2: Building and Pushing Images" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    # Build and push backend
    Write-Host ""
    Write-Host "--- Backend ---" -ForegroundColor Yellow
    Invoke-CheckedCommand -Title "Build backend image" -Block {
        docker build `
            -f "$repoRoot/Apollo-v2/Dockerfile.production" `
            -t "${backendRepo}:${backendImageTag}" `
            "$repoRoot/Apollo-v2"
    }

    Invoke-CheckedCommand -Title "Push backend image" -Block {
        docker push "${backendRepo}:${backendImageTag}"
    }

    # Verify backend image was pushed successfully
    Invoke-CheckedCommand -Title "Verify backend image exists in ECR" -Block {
        $backendRepoName = $backendRepo.Split('/')[-1]
        $imageCheck = aws ecr describe-images `
            --repository-name $backendRepoName `
            --image-ids imageTag=$backendImageTag `
            --region $region `
            2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Backend image ${backendRepo}:${backendImageTag} was not found in ECR after push. Push may have failed."
        }
        Write-Host "Verified: Backend image ${backendRepo}:${backendImageTag} exists in ECR" -ForegroundColor Green
    }

    # Build and push Lambda functions
    foreach ($lambdaName in $lambdaSource.Keys) {
        if (-not $lambdaRepos.$lambdaName) {
            Write-Warning "Skipping $lambdaName because no repository output was found."
            continue
        }

        $repoUrl = $lambdaRepos.$lambdaName
        $lambdaPath = Join-Path $repoRoot $lambdaSource[$lambdaName]
        if (-not (Test-Path $lambdaPath)) {
            Write-Warning "Skipping $lambdaName because source path '$lambdaPath' was not found."
            continue
        }

        Write-Host ""
        Write-Host "--- Lambda: $lambdaName ---" -ForegroundColor Yellow

        Invoke-CheckedCommand -Title "Build $lambdaName image" -Block {
            # Lambda requires linux/amd64 platform with single-platform manifest (not manifest list)
            # Disable buildkit to ensure single-platform manifest is created
            $env:DOCKER_BUILDKIT = "0"
            docker build `
                --platform linux/amd64 `
                -t "${repoUrl}:${lambdaTag}" `
                $lambdaPath
            Remove-Item Env:\DOCKER_BUILDKIT -ErrorAction SilentlyContinue
        }

        Invoke-CheckedCommand -Title "Push $lambdaName image" -Block {
            docker push "${repoUrl}:${lambdaTag}"
        }

        # Verify image was pushed successfully
        Invoke-CheckedCommand -Title "Verify $lambdaName image exists in ECR" -Block {
            # Extract repository name from full ECR URL (e.g., "account.dkr.ecr.region.amazonaws.com/repo-name" -> "repo-name")
            $repoName = $repoUrl.Split('/')[-1]
            $imageCheck = aws ecr describe-images `
                --repository-name $repoName `
                --image-ids imageTag=$lambdaTag `
                --region $region `
                2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Image ${repoUrl}:${lambdaTag} was not found in ECR after push. Push may have failed."
            }
            Write-Host "Verified: Image ${repoUrl}:${lambdaTag} exists in ECR" -ForegroundColor Green
        }
    }

    # Phase 3: Deploy infrastructure
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Phase 3: Deploying Infrastructure" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    Invoke-CheckedCommand -Title "Apply full infrastructure" -Block {
        # Build terraform command arguments
        $terraformArgs = @("apply")
        $terraformArgs += "-auto-approve"
        $terraformArgs += "-var-file=$($varFile)"
        
        # Execute terraform
        & terraform $terraformArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Terraform apply failed"
        }
    }

    # Get infrastructure outputs
    $albDns = Get-TerraformOutputRaw -Name "alb_dns_name"
    $cloudfrontDomain = Get-TerraformOutputRaw -Name "cloudfront_domain"
    try {
        $cloudfrontId = Get-TerraformOutputRaw -Name "cloudfront_distribution_id"
    } catch {
        Write-Warning "Unable to read CloudFront distribution ID: $($_.Exception.Message)"
        $cloudfrontId = ""
    }
    try {
        $etlBucket = Get-TerraformOutputRaw -Name "etl_uploads_bucket"
    } catch {
        Write-Warning "Unable to read ETL uploads bucket: $($_.Exception.Message)"
        $etlBucket = ""
    }

    Pop-Location

    # Phase 4: Deploy frontend
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Phase 4: Deploying Frontend" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    $frontendAppDir = Join-Path $repoRoot "SCM-MAX-REACT/app"
    if (-not (Test-Path $frontendAppDir)) {
        throw "Frontend directory '$frontendAppDir' not found."
    }

    Push-Location $frontendAppDir

    Invoke-CheckedCommand -Title "Install frontend dependencies" -Block { npm install --legacy-peer-deps }
    
    # Build frontend using build:aws which sets relative /api paths
    # The frontend code appends paths like /register, /login to the base URL
    # So VITE_AUTH_API_URL=/api becomes /api/register when code does ${authApiUrl}/register
    # This works because CloudFront routes /api/* to the backend ALB
    # Using relative paths ensures it works with any CloudFront domain
    Invoke-CheckedCommand -Title "Build frontend" -Block { npm run build:aws }

    # Vite builds to ../build (one level up from app directory)
    $distPath = Join-Path $repoRoot "SCM-MAX-REACT/build"
    if (-not (Test-Path $distPath)) {
        # Fallback to app/dist if build doesn't exist
        $distPath = Join-Path $frontendAppDir "dist"
        if (-not (Test-Path $distPath)) {
            throw "Expected build output at $distPath or SCM-MAX-REACT/build but neither was found."
        }
    }

    Invoke-CheckedCommand -Title "Upload frontend assets to S3" -Block {
        aws s3 sync $distPath "s3://$frontendBucket" --delete
    }

    if ($cloudfrontId) {
        Invoke-CheckedCommand -Title "Create CloudFront invalidation" -Block {
            aws cloudfront create-invalidation --distribution-id $cloudfrontId --paths "/*" | Out-Null
        }
    } else {
        Write-Warning "CloudFront distribution ID not found; skipping invalidation."
    }

    Pop-Location

    # Summary
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Deployment Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Client: $clientSlug" -ForegroundColor Cyan
    Write-Host "Environment: $environment" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Backend ALB URL     : http://$albDns" -ForegroundColor Yellow
    Write-Host "CloudFront domain   : https://$cloudfrontDomain" -ForegroundColor Yellow
    Write-Host "Frontend bucket     : s3://$frontendBucket" -ForegroundColor Yellow
    Write-Host "Private assets bucket: s3://$privateBucket" -ForegroundColor Yellow
    if ($etlBucket) {
        Write-Host "ETL uploads bucket  : s3://$etlBucket" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Lambda functions deployed:" -ForegroundColor Cyan
    foreach ($lambdaName in $lambdaSource.Keys) {
        if ($lambdaRepos.$lambdaName) {
            $functionName = "$clientSlug-$($lambdaName -replace '-v2$', '-v2')"
            Write-Host "  - $functionName" -ForegroundColor Gray
        }
    }
    Write-Host ""
    Write-Host "Configuration saved to: $tfvarsPath" -ForegroundColor Gray
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  Deployment Failed!" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Error $_.Exception.Message
    Write-Host ""
    Write-Host 'Stack trace:' -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    exit 1
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    # Clean up sensitive environment variables
    Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
}


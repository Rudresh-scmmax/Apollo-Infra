# Destroy Unified Client Infrastructure
# This script destroys all infrastructure for a specific client deployment

param(
    [Parameter(Mandatory=$true)]
    [string]$ClientName,
    
    [Parameter(Mandatory=$false)]
    [switch]$UseVarsFile,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Get script directory
# Script is in infrastructure/scripts, so repo root is two levels up
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)

# Load helper functions from deploy script
$deployScript = Join-Path $scriptDir "deploy-unified-client.ps1"
if (Test-Path $deployScript) {
    # Extract helper functions (we'll define them inline instead)
}

function Write-Header {
    param([string]$Title)
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  $Title" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
}

function Invoke-CheckedCommand {
    param(
        [string]$Title,
        [scriptblock]$Block
    )
    
    Write-Host ""
    Write-Host "==> $Title" -ForegroundColor Yellow
    try {
        & $Block
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
            throw "Command failed with exit code $LASTEXITCODE"
        }
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

# Load client variables
$varsFile = Join-Path $repoRoot "infrastructure\client-stack\clients\$ClientName.vars.ps1"
$tfvarsFile = Join-Path $repoRoot "infrastructure\client-stack\clients\$ClientName.auto.tfvars"

if ($UseVarsFile -and (Test-Path $varsFile)) {
    Write-Host "Loading variables from: $varsFile" -ForegroundColor Cyan
    $vars = & $varsFile
    
    if ($vars.ClientName) {
        $ClientName = $vars.ClientName
    }
    if ($vars.AwsProfile) {
        $env:AWS_PROFILE = $vars.AwsProfile
        Write-Host "Using AWS profile: $($vars.AwsProfile)" -ForegroundColor Cyan
    }
} elseif (Test-Path $tfvarsFile) {
    Write-Host "Found Terraform variables file: $tfvarsFile" -ForegroundColor Cyan
} else {
    Write-Host "WARNING: No variables file found. Using client name: $ClientName" -ForegroundColor Yellow
}

Write-Header "Destroying Infrastructure for Client: $ClientName"

# Confirmation
if (-not $Force) {
    Write-Host "WARNING: This will DESTROY all infrastructure for client '$ClientName'!" -ForegroundColor Red
    Write-Host ""
    Write-Host "This includes:" -ForegroundColor Yellow
    Write-Host "  - VPC and all networking resources" -ForegroundColor White
    Write-Host "  - RDS database (ALL DATA WILL BE LOST)" -ForegroundColor Red
    Write-Host "  - ECS cluster and services" -ForegroundColor White
    Write-Host "  - Lambda functions" -ForegroundColor White
    Write-Host "  - S3 buckets (ALL DATA WILL BE LOST)" -ForegroundColor Red
    Write-Host "  - CloudFront distribution" -ForegroundColor White
    Write-Host "  - ECR repositories (images will be deleted)" -ForegroundColor White
    Write-Host "  - All security groups and IAM roles" -ForegroundColor White
    Write-Host ""
    
    $confirmation = Read-Host "Type 'yes' to confirm destruction"
    if ($confirmation -ne "yes") {
        Write-Host "Destruction cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# Change to Terraform directory
$tfDir = Join-Path $repoRoot "infrastructure\client-stack"
if (-not (Test-Path $tfDir)) {
    throw "Terraform directory not found: $tfDir"
}

Push-Location $tfDir

try {
    # Initialize Terraform if needed
    if (-not (Test-Path ".terraform")) {
        Write-Host ""
        Write-Host "==> Initializing Terraform" -ForegroundColor Yellow
        terraform init
        if ($LASTEXITCODE -ne 0) {
            throw "Terraform init failed"
        }
    }
    
    # Destroy infrastructure
    Write-Header "Destroying Infrastructure"
    
    Invoke-CheckedCommand -Title "Destroy all infrastructure" -Block {
        if (Test-Path $tfvarsFile) {
            terraform destroy -auto-approve -var-file="clients\$ClientName.auto.tfvars"
        } else {
            terraform destroy -auto-approve
        }
    }
    
    Write-Header "Destruction Complete!"
    Write-Host "All infrastructure for client '$ClientName' has been destroyed." -ForegroundColor Green
    Write-Host ""
    Write-Host "This includes:" -ForegroundColor Green
    Write-Host "  ✓ VPC and all networking resources" -ForegroundColor White
    Write-Host "  ✓ RDS database - all data deleted" -ForegroundColor White
    Write-Host "  ✓ ECS cluster and services" -ForegroundColor White
    Write-Host "  ✓ Lambda functions" -ForegroundColor White
    Write-Host "  ✓ S3 buckets - all data deleted" -ForegroundColor White
    Write-Host "  ✓ CloudFront distribution" -ForegroundColor White
    Write-Host "  ✓ ECR repositories - all images deleted" -ForegroundColor White
    Write-Host "  ✓ All security groups and IAM roles" -ForegroundColor White
    
} catch {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  Destruction Failed!" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    throw
} finally {
    Pop-Location
}


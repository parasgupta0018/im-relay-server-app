<#
.SYNOPSIS
  A universal script to install or cache npm packages using the GitHub REST API.

.DESCRIPTION
  This script has two modes and does NOT require the GitHub CLI.
  1. INSTALL MODE: If package names are provided as arguments, it installs them from a personal
     GitHub Packages cache. If a package is not in the cache, it triggers a GitHub Action to add it.
  2. CACHE-ALL MODE: If NO arguments are provided, it reads the project's package.json and ensures
     all dependencies are cached by triggering the workflow for any missing ones.

.NOTES
  Prerequisites:
  1. A GitHub Personal Access Token (PAT) with 'repo' and 'workflow' scopes.
  2. The PAT must be stored in an environment variable named 'GITHUB_TOKEN'.
  3. A workflow file named `publish-to-ghp.yml` must exist in your repository.
#>

# --- CONFIGURATION ---
# IMPORTANT: Change these to your actual GitHub username and repository name.
$GithubUsername = "parasgupta0018"
$GithubRepo = "im-relay-server-app"
# ---------------------

# --- SCRIPT SETUP ---
$GithubApiUrl = "https://api.github.com/repos/$($GithubUsername)/$($GithubRepo)/actions/workflows/publish-to-ghp.yml/dispatches"
$GithubToken = $env:GITHUB_TOKEN

if ([string]::IsNullOrEmpty($GithubToken)) {
    Write-Host "Error: GITHUB_TOKEN environment variable not set." -ForegroundColor Red
    Write-Host "Please create a Personal Access Token and set it as an environment variable."
    exit 1
}

$headers = @{
    "Authorization" = "token $GithubToken"
    "Accept" = "application/vnd.github.v3+json"
}

function Process-Package {
    param(
        [string]$PackageName
    )

    Write-Host "`n--- Processing package: $($PackageName) ---" -ForegroundColor Cyan
    
    if ($PackageName.StartsWith("@")) {
        Write-Host "Skipping already-scoped package: $($PackageName)" -ForegroundColor Green
        return
    }

    $ScopedPackageName = "@$($GithubUsername)/$($PackageName)"

    Write-Host "Checking for $($ScopedPackageName) in your cache..."
    npm view $ScopedPackageName --silent > $null
    if (-not $?) {
        Write-Host "Package not found. Caching $($PackageName) from npmjs.com..." -ForegroundColor Yellow
        try {
            $body = @{
                ref = "main" # Or your default branch
                inputs = @{
                    package_name = $PackageName
                    package_version = "latest"
                }
            } | ConvertTo-Json

            Invoke-RestMethod -Uri $GithubApiUrl -Method POST -Headers $headers -Body $body -ContentType "application/json"
            
            Write-Host "Caching workflow started successfully for $($PackageName)." -ForegroundColor Green
            Write-Host "Please wait for the workflow to complete, then run the install command again for this package."
            return $false
        }
        catch {
            Write-Host "Error starting GitHub workflow for $($PackageName). Check your PAT and repository configuration." -ForegroundColor Red
            Write-Host $_.Exception.Message
            return $false
        }
    }

    Write-Host "Package found in cache." -ForegroundColor Green
    return $true
}

# --- SCRIPT LOGIC ---

# Mode 1: Install specific packages
if ($args.Count -gt 0) {
    Write-Host "Running in INSTALL mode..." -ForegroundColor Magenta
    foreach ($PackageName in $args) {
        $canInstall = Process-Package -PackageName $PackageName
        if ($canInstall) {
            $ScopedPackageName = "@$($GithubUsername)/$($PackageName)"
            Write-Host "Installing $($ScopedPackageName)..."
            try {
                npm install $ScopedPackageName
                Write-Host "Successfully installed $($ScopedPackageName)!" -ForegroundColor Green
            }
            catch {
                Write-Host "Error installing $($ScopedPackageName)." -ForegroundColor Red
                Write-Host $_.Exception.Message
            }
        }
    }
}
# Mode 2: Process package.json
else {
    Write-Host "Running in CACHE-ALL mode for package.json..." -ForegroundColor Magenta
    $packageJsonPath = Resolve-Path "./package.json"
    if (-not (Test-Path $packageJsonPath)) {
        Write-Host "Error: package.json not found in the current directory." -ForegroundColor Red
        exit 1
    }
    $packageJson = Get-Content $packageJsonPath -Raw | ConvertFrom-Json

    $allDependencies = @{}
    if ($null -ne $packageJson.dependencies) { $packageJson.dependencies.psobject.Properties | ForEach-Object { $allDependencies[$_.Name] = $_.Value } }
    if ($null -ne $packageJson.devDependencies) { $packageJson.devDependencies.psobject.Properties | ForEach-Object { $allDependencies[$_.Name] = $_.Value } }

    if ($allDependencies.Count -eq 0) {
        Write-Host "No dependencies found in package.json." -ForegroundColor Green
        exit 0
    }
    
    Write-Host "Found $($allDependencies.Count) total dependencies. Checking cache status..."
    foreach ($entry in $allDependencies.GetEnumerator()) {
        Process-Package -PackageName $entry.Name
    }
    Write-Host "`nAll dependency checks are complete. Please verify the GitHub Actions runs have finished before proceeding."
}

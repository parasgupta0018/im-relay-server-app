<#
.SYNOPSIS
  A universal script to install or cache npm packages using the GitHub REST API with caching support.

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
  
  The updated workflow now includes caching functionality that:
  - Caches downloaded packages for faster subsequent runs
  - Resolves "latest" versions to specific version numbers
  - Provides better logging and status information
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

function Get-PackageVersion {
    param(
        [string]$PackageName,
        [string]$VersionSpec = "latest"
    )
    
    try {
        # Always query the public registry to resolve the specifier to a concrete version.
        # This handles 'latest', '1.8.0', '^1.8.0', etc., consistently.
        $packageWithSpec = "$($PackageName)@$($VersionSpec)"
        Write-Host "Resolving version for '$($packageWithSpec)' from public npm registry..." -ForegroundColor Gray

        $registryUrl = $PackageName | Select-String -Pattern $GithubUsername -Quiet
        if ($registryUrl) {
            $registryUrl = "https://npm.pkg.github.com/$($GithubUsername)"
        } else {
            $registryUrl = "https://registry.npmjs.org/"
        }
        $versionOutput = npm view $packageWithSpec version --registry=$registryUrl 2>$null | Select-Object -Last 1

        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrEmpty($versionOutput)) {
            # The command can sometimes return the version in quotes, so we trim everything.
            $resolved = $versionOutput.Trim().Trim("'").Trim('"')
            Write-Host "Resolved '$($packageWithSpec)' to concrete version: $($resolved)" -ForegroundColor DarkGray
            return $resolved
        } else {
            # If resolution fails on the public registry, the package/version likely doesn't exist at all.
            Write-Host "Error: Could not resolve version specifier '$($VersionSpec)' for package '$($PackageName)' from npmjs.org." -ForegroundColor Red
            return $VersionSpec # Fallback to the original spec, though it's likely to fail later.
        }
    }
    catch {
        Write-Host "Error during version resolution for $PackageName : $($_.Exception.Message)" -ForegroundColor Red
        return $VersionSpec
    }
}

function Check-WorkflowStatus {
    param(
        [string]$PackageName
    )
    
    $workflowRunsUrl = "https://api.github.com/repos/$($GithubUsername)/$($GithubRepo)/actions/runs"
    
    try {
        $runs = Invoke-RestMethod -Uri $workflowRunsUrl -Headers $headers
        $recentRuns = $runs.workflow_runs | Where-Object { 
            $_.name -eq "Publish to GitHub Packages with Caching" -and 
            $_.created_at -gt (Get-Date).AddMinutes(-10) 
        } | Select-Object -First 3
        
        if ($recentRuns.Count -gt 0) {
            $latestRun = $recentRuns[0]
            Write-Host "Latest workflow status: $($latestRun.status) - $($latestRun.conclusion)" -ForegroundColor Cyan
            if ($latestRun.status -eq "in_progress") {
                Write-Host "Workflow is still running. You can monitor it at: $($latestRun.html_url)" -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Host "Could not check workflow status (this is not critical)" -ForegroundColor Yellow
    }
}

function Wait-For-Workflow {
    param(
        [string]$WorkflowFileName,
        [string]$PackageName
    )

    Write-Host "Waiting for caching workflow for '$($PackageName)' to complete..." -ForegroundColor Yellow
    
    # Give GitHub a moment to create the workflow run
    Start-Sleep -Seconds 3

    try {
        # Find the specific workflow run that was just triggered for our package
        $runsUrl = "https://api.github.com/repos/$($GithubUsername)/$($GithubRepo)/actions/workflows/$($WorkflowFileName)/runs?event=workflow_dispatch"
        $workflowRuns = Invoke-RestMethod -Uri $runsUrl -Headers $headers
        $latestRun = $workflowRuns.workflow_runs | Sort-Object -Property created_at -Descending | Select-Object -First 1

        if (-not $latestRun) {
            Write-Host "Error: Could not find the triggered workflow run." -ForegroundColor Red
            return $false
        }

        Write-Host "Monitoring workflow run: $($latestRun.html_url)" -ForegroundColor Cyan
        
        $runId = $latestRun.id
        $status = $latestRun.status
        $conclusion = $latestRun.conclusion
        $timeout = (Get-Date).AddMinutes(1) # 1-minute timeout

        # Poll the API until the workflow is 'completed' or we time out
        while ($status -ne "completed" -and (Get-Date) -lt $timeout) {
            Write-Host "Current status: $($status)... waiting..." -ForegroundColor Gray
            Start-Sleep -Seconds 3
            
            $runUrl = "https://api.github.com/repos/$($GithubUsername)/$($GithubRepo)/actions/runs/$($runId)"
            $runDetails = Invoke-RestMethod -Uri $runUrl -Headers $headers
            $status = $runDetails.status
            $conclusion = $runDetails.conclusion
        }

        if ($status -ne "completed") {
            Write-Host "Timed out waiting for workflow to complete." -ForegroundColor Red
            return $false
        }

        if ($conclusion -eq 'success') {
            Write-Host "Workflow finished with conclusion: '$($conclusion)'" -ForegroundColor Green
        } else {
            Write-Host "Workflow finished with conclusion: '$($conclusion)'" -ForegroundColor Red
        }
        Start-Sleep -Seconds 3
        return ($conclusion -eq "success")
    }
    catch {
        Write-Host "An error occurred while monitoring the workflow: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Process-Package {
    param(
        [string]$PackageName,
        [string]$VersionSpec = "latest"
    )

    Write-Host "`n--- Processing package: $($PackageName)@$($VersionSpec) ---" -ForegroundColor Cyan
    
    if ($PackageName.StartsWith("@")) {
        Write-Host "Skipping already-scoped package: $($PackageName)" -ForegroundColor Green
        return $true
    }

    # Step 1: Resolve the requested version to a concrete version number from the public registry.
    $ConcreteVersion = Get-PackageVersion -PackageName $PackageName -VersionSpec $VersionSpec
    if (-not $ConcreteVersion) {
        Write-Host "Could not resolve package version, cannot proceed." -ForegroundColor Red
        return $false
    }

    $ScopedPackageNameWithVersion = "@$($GithubUsername)/$($PackageName)"
    Write-Host "Checking for exact package '$($ScopedPackageNameWithVersion)/$($ConcreteVersion)' in your GitHub Packages cache..."
    
    # Step 2: Perform a reliable check for that *exact* concrete version in your private cache.
    # This command will only succeed if the specific version exists.
    # npm view $ScopedPackageNameWithVersion versions --silent > $null 2>&1

    # Run the command and check the result
    $versionExists = (npm view $ScopedPackageNameWithVersion versions --silent) | Select-String -Pattern $ConcreteVersion -Quiet

    if ($versionExists) {
        # The package and exact version exist in the cache. We can install it.
        Write-Host "Package found in GitHub Packages cache." -ForegroundColor Green
        return $true
    }

    # Step 3: If the check failed, the package is not in the cache. Trigger the workflow.
    Write-Host "Package not found. Triggering caching workflow for '$($PackageName)@$($VersionSpec)'..." -ForegroundColor Yellow
    try {
        $body = @{
            ref = "main" # Or your default branch
            inputs = @{
                package_name = $PackageName
                # Trigger the workflow with the original version specifier
                package_version = $VersionSpec
            }
        } | ConvertTo-Json

        Invoke-RestMethod -Uri $GithubApiUrl -Method POST -Headers $headers -Body $body -ContentType "application/json"
        
        # Instead of a simple sleep, we now wait for the workflow to finish
        $workflowSucceeded = Wait-For-Workflow -WorkflowFileName "publish-to-ghp.yml" -PackageName $PackageName
        
        if ($workflowSucceeded) {
            Write-Host "Package should now be cached. The script will attempt to use it." -ForegroundColor Green
            # Returning $true allows the main script to proceed with installation immediately.
            return $true
        } else {
            Write-Host "Workflow failed or timed out. Please check the Actions tab in your GitHub repository." -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "Error starting GitHub workflow for $($PackageName)" -ForegroundColor Red
        Write-Host "Check your PAT permissions and repository configuration." -ForegroundColor Red
        Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Parse-VersionFromPackageJson {
    param(
        [string]$VersionSpec
    )
    
    # Remove common version prefixes like ^, ~, >=, etc.
    $cleanVersion = $VersionSpec -replace '^[\^~>=<]+', ''
    
    # If it's a complex version range, default to latest
    if ($cleanVersion -match '[*x]' -or $cleanVersion -match '\|\|' -or $cleanVersion -match ' - ') {
        return "latest"
    }
    
    return $cleanVersion
}

# --- SCRIPT LOGIC ---

Write-Host "GitHub Package Cache Manager" -ForegroundColor Magenta
Write-Host "Repository: $GithubUsername/$GithubRepo" -ForegroundColor Gray

# Mode 1: Install specific packages
if ($args.Count -gt 0) {
    Write-Host "`n Running in INSTALL mode..." -ForegroundColor Magenta
    
    $successfulPackages = @()
    $pendingPackages = @()
    
    # CORRECTED: Loop through arguments and parse them
    foreach ($arg in $args) {
        $packageNameFromArg = $arg
        $versionSpecFromArg = "latest"

        # Check for a version specifier, like 'axios@1.8.0'.
        $lastAtIndex = $packageNameFromArg.LastIndexOf('@')
        if ($lastAtIndex -gt 0) {
            $versionSpecFromArg = $packageNameFromArg.Substring($lastAtIndex + 1)
            $packageNameFromArg = $packageNameFromArg.Substring(0, $lastAtIndex)
        }

        # Now, process the package with the correctly parsed name and version
        $canInstall = Process-Package -PackageName $packageNameFromArg -VersionSpec $versionSpecFromArg
        if ($canInstall) {
            $ScopedPackageName = "@$($GithubUsername)/$($packageNameFromArg)"
            
            # Ensure we install the specific, resolved version, not just the 'latest' tag.
            $installVersion = Get-PackageVersion -PackageName $packageNameFromArg -VersionSpec $versionSpecFromArg
            $packageToInstall = "$($ScopedPackageName)@$($installVersion)"

            Write-Host "Installing $($packageToInstall)..."
            try {
                npm install $packageToInstall
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Successfully installed $($packageToInstall)!" -ForegroundColor Green
                    $successfulPackages += $packageToInstall
                } else {
                    Write-Host "Error installing $($packageToInstall)" -ForegroundColor Red
                }
            }
            catch {
                Write-Host "Error installing $($packageToInstall)" -ForegroundColor Red
                Write-Host $_.Exception.Message
            }
        } else {
            $pendingPackages += "$($packageNameFromArg)@$($versionSpecFromArg)"
        }
    }
    
    # Summary
    if ($successfulPackages.Count -gt 0) {
        Write-Host "`nSuccessfully installed: $($successfulPackages -join ', ')" -ForegroundColor Green
    }
    if ($pendingPackages.Count -gt 0) {
        Write-Host "`nPackages being cached: $($pendingPackages -join ', ')" -ForegroundColor Yellow
        Write-Host "Run the script again in a few minutes to install these packages." -ForegroundColor Yellow
    }
}
# Mode 2: Process package.json
else {
    Write-Host "`nRunning in CACHE-ALL mode for package.json..." -ForegroundColor Magenta
    $packageJsonPath = Resolve-Path "./package.json"
    if (-not (Test-Path $packageJsonPath)) {
        Write-Host "Error: package.json not found in the current directory." -ForegroundColor Red
        exit 1
    }
    
    $packageJson = Get-Content $packageJsonPath -Raw | ConvertFrom-Json

    $allDependencies = @{}
    if ($null -ne $packageJson.dependencies) { 
        $packageJson.dependencies.psobject.Properties | ForEach-Object { 
            $allDependencies[$_.Name] = Parse-VersionFromPackageJson $_.Value 
        } 
    }
    if ($null -ne $packageJson.devDependencies) { 
        $packageJson.devDependencies.psobject.Properties | ForEach-Object { 
            $allDependencies[$_.Name] = Parse-VersionFromPackageJson $_.Value 
        } 
    }

    if ($allDependencies.Count -eq 0) {
        Write-Host "No dependencies found in package.json." -ForegroundColor Green
        exit 0
    }
    
    Write-Host "Found $($allDependencies.Count) total dependencies. Checking cache status..."
    
    $cachedCount = 0
    $pendingCount = 0
    
    foreach ($entry in $allDependencies.GetEnumerator()) {
        $isAvailable = Process-Package -PackageName $entry.Name -VersionSpec $entry.Value
        if ($isAvailable) {
            $ScopedPackageName = "$($entry.Name)"

            # Check for a version specifier, like 'axios@1.8.0'.
            $lastAtIdx = $entry.Name.LastIndexOf('@')
            if ($lastAtIdx -gt 0) {
                $entry.Name = $entry.Name.Substring($lastAtIdx + 1)
            }
            
            # Ensure we install the specific, resolved version, not just the 'latest' tag.
            $versionSpecFromArg = Get-PackageVersion -PackageName $entry.Name -VersionSpec $entry.Value
            $packageToInstall = "$($ScopedPackageName)@$($versionSpecFromArg)"
            Write-Host "Installing $($packageToInstall)..."

            try {
                npm install $packageToInstall
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Successfully installed $($packageToInstall)!" -ForegroundColor Green
                    $cachedCount++
                } else {
                    Write-Host "Error installing $($packageToInstall)" -ForegroundColor Red
                }
            }
            catch {
                Write-Host "Error installing $($packageToInstall)" -ForegroundColor Red
                Write-Host $_.Exception.Message
            }
        } else {
            $pendingCount++
        }
    }
    
    Write-Host "`nSummary:" -ForegroundColor Magenta
    Write-Host "Already cached: $cachedCount packages" -ForegroundColor Green
    Write-Host "Being cached: $pendingCount packages" -ForegroundColor Yellow
    
    if ($pendingCount -gt 0) {
        Write-Host "`nWorkflows have been triggered for missing packages." -ForegroundColor Yellow
        Write-Host "Monitor progress at: https://github.com/$GithubUsername/$GithubRepo/actions" -ForegroundColor Cyan
        Write-Host "Run this script again once workflows complete to verify all packages are cached." -ForegroundColor Yellow
    } else {
        Write-Host "`nAll dependencies are cached and ready to use!" -ForegroundColor Green
    }
}

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

function Load-DotEnv {
    param([string]$Path = ".env")
    
    if (Test-Path $Path) {
        Get-Content $Path | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object {
            $key, $value = $_ -split '=', 2
            if ($key -and $value) {
                $value = $value.Trim('"').Trim("'")
                [Environment]::SetEnvironmentVariable($key.Trim(), $value, "Process")
            }
        }
    } else {
        Write-Warning "Environment file not found: $Path"
    }
}

# Load environment variables from .env file if it exists
Load-DotEnv -Path "./.env"

# --- CONFIGURATION ---
$GithubUsername = [Environment]::GetEnvironmentVariable("GITHUB_USER_NAME")
$GithubRepo = [Environment]::GetEnvironmentVariable("GITHUB_REPOSITORY_NAME")

# --- SCRIPT SETUP ---
$GithubApiUrl = "https://api.github.com/repos/$($GithubUsername)/$($GithubRepo)/actions/workflows/publish-to-ghp.yml/dispatches"
$GithubToken = [Environment]::GetEnvironmentVariable("GITHUB_PERSONAL_ACCESS_TOKEN")

# At the top of your script or in the function, define allowed licenses
$allowedLicenses = @(
    'MIT',
    'ISC',
    'Apache-2.0',
    'BSD-2-Clause',
    'BSD-3-Clause'
    # Add other licenses you approve
)

if ([string]::IsNullOrEmpty($GithubToken)) {
    Write-Host "Error: GITHUB_TOKEN environment variable not set." -ForegroundColor Red
    Write-Host "Please create a Personal Access Token and set it as an environment variable."
    exit 1
}

$headers = @{
    "Authorization" = "token $GithubToken"
    "Accept" = "application/vnd.github.v3+json"
}

# Helper: Update package.json to ensure unscoped dependency is present with exact version
function Update-PackageJsonDependency {
    param(
        [string]$PackageName,
        [string]$Version
    )
    $pkgPath = Join-Path (Get-Location) 'package.json'
    if (-not (Test-Path $pkgPath)) { return }
    try {
        $jsonRaw = Get-Content $pkgPath -Raw
        $pkgObj = $jsonRaw | ConvertFrom-Json
        if (-not $pkgObj.dependencies) { $pkgObj | Add-Member -NotePropertyName dependencies -NotePropertyValue (@{}) }
        # Remove any scoped variant referencing this base name for our user scope
        $scopePrefix = "@$GithubUsername/"
        $toRemove = @()
        foreach ($prop in $pkgObj.dependencies.PSObject.Properties) {
            if ($prop.Name -eq "$scopePrefix$PackageName") { $toRemove += $prop.Name }
        }
        foreach ($r in $toRemove) { $pkgObj.dependencies.PSObject.Properties.Remove($r) }
        $pkgObj.dependencies.PSObject.Properties.Remove($PackageName) | Out-Null 2>$null
        $pkgObj.dependencies | Add-Member -NotePropertyName $PackageName -NotePropertyValue $Version
        ConvertTo-Json $pkgObj -Depth 10 | Format-Json | Set-Content $pkgPath -Encoding UTF8

        Write-Host "package.json updated: $PackageName@$Version (unscoped)" -ForegroundColor DarkGreen
    } catch {
        Write-Warning "Failed to update package.json: $($_.Exception.Message)"
    }
}

# Helper: Create an unscoped alias (symlink or copy) so require('pkg') works when only @user/pkg is installed
function Ensure-UnscopedAlias {
    param(
        [string]$PackageName
    )
    $scopedDir = Join-Path (Join-Path (Get-Location) 'node_modules') "@$GithubUsername"
    $scopedPath = Join-Path $scopedDir $PackageName
    $unscopedPath = Join-Path (Join-Path (Get-Location) 'node_modules') $PackageName
    if (-not (Test-Path $scopedPath)) { return }
    if (Test-Path $unscopedPath) { return }
    try {
        New-Item -ItemType SymbolicLink -Path $unscopedPath -Target $scopedPath -ErrorAction Stop | Out-Null
        Write-Host "Created symlink alias: $unscopedPath -> $scopedPath" -ForegroundColor Gray
    } catch {
        try {
            Copy-Item $scopedPath $unscopedPath -Recurse -Force
            Write-Host "Copied directory as alias (symlink failed): $unscopedPath" -ForegroundColor Gray
        } catch {
            Write-Warning "Could not create alias: $($_.Exception.Message)"
        }
    }
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

# Suggest alternative non-deprecated versions when a requested version is deprecated or unavailable
function Get-AlternativeVersions {
    param(
        [string]$PackageName,
        [string]$ProblemVersion,
        [int]$Max = 5
    )
    try {
        $raw = npm view "$PackageName" versions --json --registry=https://registry.npmjs.org/ 2>$null
        if (-not $raw) { return @() }
        $versions = $raw | ConvertFrom-Json
        if (-not $versions) { return @() }

        # Keep only versions different from the problem one; take last ( newest ) slice
        $candidates = ($versions | Where-Object { $_ -ne $ProblemVersion }) | Select-Object -Last 30
        # Reverse to have newest first
        $ordered = [System.Collections.Generic.List[string]]::new()
        ($candidates | Sort-Object -Descending) | ForEach-Object { $ordered.Add($_) }

        return $ordered | Select-Object -First $Max
    } catch {
        return @()
    }
}

function Write-VersionSuggestions {
    param(
        [string]$PackageName,
        [string]$ProblemVersion
    )
    $alts = Get-AlternativeVersions -PackageName $PackageName -ProblemVersion $ProblemVersion -Max 3
    if ($alts.Count -gt 0) {
        Write-Host "Suggested alternative versions for $PackageName (problem with $ProblemVersion):" -ForegroundColor Yellow
        Write-Host ("  " + ($alts -join ", ")) -ForegroundColor Yellow
        Write-Host "Try: npm run im-install -- $PackageName@$($alts[0])" -ForegroundColor DarkYellow
    } else {
        Write-Host "No alternative version suggestions available for $PackageName right now." -ForegroundColor Yellow
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

function Check-NodeCompatibility {
    param (
        [string]$PackageName,
        [string]$PackageVersion = "latest"
    )

    # Check if Node.js is available
    try {
        $null = Get-Command node -ErrorAction Stop
    }
    catch {
        Write-Warning "Node.js not found. Skipping compatibility check for $PackageName"
        return $true
    }

    # Get current Node version
    try {
        $currentNodeVersionRaw = node -v 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($currentNodeVersionRaw)) {
            Write-Warning "Could not determine Node.js version. Skipping compatibility check."
            return $true
        }
        
        $currentNodeVersion = $currentNodeVersionRaw -replace '^v', ''
        $currentVer = [System.Version]::Parse($currentNodeVersion)
        Write-Host "Current Node.js version: $currentNodeVersion" -ForegroundColor Gray
    }
    catch {
        Write-Warning "Could not parse Node.js version: $currentNodeVersionRaw"
        return $true
    }

    try {
        # Get the engines.node field - handle both string and object responses
        $enginesNodeRaw = npm view "$PackageName@$PackageVersion" engines.node --json --registry=https://registry.npmjs.org/ 2>$null
        
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($enginesNodeRaw) -or $enginesNodeRaw -eq "undefined") {
            Write-Host "No Node.js engine constraints found for $PackageName@$PackageVersion" -ForegroundColor Gray
            return $true
        }

        # Clean up the JSON response
        $enginesNode = $enginesNodeRaw.Trim('"') -replace '\\', ''
        
        if ([string]::IsNullOrEmpty($enginesNode) -or $enginesNode -eq "null") {
            Write-Host "No Node.js engine constraints specified for $PackageName@$PackageVersion" -ForegroundColor Gray
            return $true
        }

        Write-Host "Checking Node.js compatibility for $PackageName@$PackageVersion (requires: $enginesNode)" -ForegroundColor Yellow
        
        # Handle different constraint formats
        $compatible = Test-NodeVersionConstraint -CurrentVersion $currentVer -Constraint $enginesNode
        
        if (-not $compatible) {
            Write-Warning "COMPATIBILITY WARNING: $PackageName@$PackageVersion requires Node.js $enginesNode, but you have $currentNodeVersion"
            Write-Host "Consider upgrading Node.js or using a different package version." -ForegroundColor Yellow
            return $false
        }
        else {
            Write-Host "Node.js version compatibility: OK" -ForegroundColor Green
            return $true
        }
    }
    catch {
        Write-Warning "Could not check Node.js compatibility for $PackageName@$PackageVersion : $($_.Exception.Message)"
        return $true  # Don't block installation on compatibility check failures
    }
}

function Test-NodeVersionConstraint {
    param(
        [System.Version]$CurrentVersion,
        [string]$Constraint
    )
    
    # Handle range constraints like ">=14.0.0 <17.0.0" or ">=16"
    if ($Constraint -match '\s+') {
        $constraints = $Constraint -split '\s+'
        foreach ($c in $constraints) {
            $c = $c.Trim()
            if (-not [string]::IsNullOrEmpty($c) -and -not (Test-SingleVersionConstraint -CurrentVersion $CurrentVersion -Constraint $c)) {
                return $false
            }
        }
        return $true
    }
    else {
        return Test-SingleVersionConstraint -CurrentVersion $CurrentVersion -Constraint $Constraint
    }
}

function Test-SingleVersionConstraint {
    param(
        [System.Version]$CurrentVersion,
        [string]$Constraint
    )
    
    # Parse version constraint patterns
    if ($Constraint -match '^(>=|<=|>|<|=|~|\^)?\s*([0-9]+(?:\.[0-9]+)?(?:\.[0-9]+)?)(.*)$') {
        $operator = if ($matches[1]) { $matches[1] } else { "=" }
        $versionStr = $matches[2]
        
        # Handle incomplete version numbers (e.g., "14" -> "14.0.0")
        $versionParts = $versionStr -split '\.'
        while ($versionParts.Length -lt 3) {
            $versionParts += "0"
        }
        $normalizedVersion = $versionParts[0..2] -join '.'
        
        try {
            $targetVer = [System.Version]::Parse($normalizedVersion)
        }
        catch {
            Write-Warning "Could not parse version constraint: $Constraint"
            return $true
        }

        switch ($operator) {
            ">=" { 
                return $CurrentVersion -ge $targetVer
            }
            "<=" { 
                return $CurrentVersion -le $targetVer
            }
            ">" { 
                return $CurrentVersion -gt $targetVer
            }
            "<" { 
                return $CurrentVersion -lt $targetVer
            }
            "=" { 
                return $CurrentVersion -eq $targetVer
            }
            "~" {
                # Tilde allows patch-level changes if a minor version is specified
                # ~1.2.3 := >=1.2.3 <1.3.0 (reasonably close to 1.2.3)
                # ~1.2 := >=1.2.0 <1.3.0 (Same as ~1.2.0)
                # ~1 := >=1.0.0 <2.0.0 (Same as ~1.0.0)
                if ($versionParts.Length -ge 2) {
                    $nextMinor = [System.Version]::new($targetVer.Major, $targetVer.Minor + 1, 0)
                    return ($CurrentVersion -ge $targetVer) -and ($CurrentVersion -lt $nextMinor)
                }
                else {
                    $nextMajor = [System.Version]::new($targetVer.Major + 1, 0, 0)
                    return ($CurrentVersion -ge $targetVer) -and ($CurrentVersion -lt $nextMajor)
                }
            }
            "^" {
                # Caret allows changes that do not modify the left-most non-zero digit
                # ^1.2.3 := >=1.2.3 <2.0.0
                # ^0.2.3 := >=0.2.3 <0.3.0
                # ^0.0.3 := >=0.0.3 <0.0.4
                if ($targetVer.Major -gt 0) {
                    $nextMajor = [System.Version]::new($targetVer.Major + 1, 0, 0)
                    return ($CurrentVersion -ge $targetVer) -and ($CurrentVersion -lt $nextMajor)
                }
                elseif ($targetVer.Minor -gt 0) {
                    $nextMinor = [System.Version]::new($targetVer.Major, $targetVer.Minor + 1, 0)
                    return ($CurrentVersion -ge $targetVer) -and ($CurrentVersion -lt $nextMinor)
                }
                else {
                    $nextPatch = [System.Version]::new($targetVer.Major, $targetVer.Minor, $targetVer.Build + 1)
                    return ($CurrentVersion -ge $targetVer) -and ($CurrentVersion -lt $nextPatch)
                }
            }
            default {
                Write-Warning "Unrecognized version operator: $operator"
                return $true
            }
        }
    }
    else {
        Write-Warning "Could not parse version constraint: $Constraint"
        return $true
    }
}

function Process-Package {
    param(
        [string]$PackageName,
        [string]$VersionSpec = "latest"
    )

    Write-Host "`n--- Processing package: $($PackageName)@$($VersionSpec) ---" -ForegroundColor Cyan
    
    # Resolve concrete version FIRST so later checks reference the right version
    $ConcreteVersion = Get-PackageVersion -PackageName $PackageName -VersionSpec $VersionSpec
    if (-not $ConcreteVersion) {
        Write-Host "Could not resolve package version, cannot proceed." -ForegroundColor Red
        return $false
    }

    $deprecationMessage = npm view "${PackageName}@${ConcreteVersion}" deprecated --registry=https://registry.npmjs.org/
    if (-not [string]::IsNullOrEmpty($deprecationMessage)) {
        Write-Warning "This package version is deprecated. Message: $deprecationMessage"
        Write-Host "Consider using a different version or package." -ForegroundColor Yellow
        Write-VersionSuggestions -PackageName $PackageName -ProblemVersion $ConcreteVersion
    }

    $packageLicense = npm view "${PackageName}@${ConcreteVersion}" license --registry=https://registry.npmjs.org/
    if (-not ($allowedLicenses -contains $packageLicense)) {
        Write-Error "LICENSE VIOLATION: The license '$($packageLicense)' for $($PackageName)@$($ConcreteVersion) is not on the approved list. Halting installation."
        return $false
    }

    function Check-DependencyLicenses {
        param(
            [string]$RootPackage,
            [string]$RootVersion
        )
        $checked = @{}
        function CheckRecursively {
            param(
                [string]$Pkg,
                [string]$Ver
            )
            $key = "$Pkg@$Ver"
            if ($checked.ContainsKey($key)) { return $true }
            $checked[$key] = $true
            $depLicense = npm view "$Pkg@$Ver" license --registry=https://registry.npmjs.org/
            if (-not ($allowedLicenses -contains $depLicense)) {
                Write-Error "LICENSE VIOLATION: The license '$($depLicense)' for dependency $Pkg@$Ver is not on the approved list. Halting installation."
                return $false
            }
            $deps = npm view "$Pkg@$Ver" dependencies --json --registry=https://registry.npmjs.org/
            if (-not [string]::IsNullOrEmpty($deps)) {
                try {
                    $depObj = $deps | ConvertFrom-Json
                    foreach ($depName in $depObj.Keys) {
                        $depVerSpec = $depObj[$depName]
                        $depVer = Get-PackageVersion -PackageName $depName -VersionSpec $depVerSpec
                        if (-not (CheckRecursively -Pkg $depName -Ver $depVer)) {
                            return $false
                        }
                    }
                } catch {}
            }
            return $true
        }
        return CheckRecursively -Pkg $RootPackage -Ver $RootVersion
    }

    if (-not (Check-DependencyLicenses -RootPackage $PackageName -RootVersion $ConcreteVersion)) {
        Write-Error "LICENSE VIOLATION: One or more dependencies of $PackageName@$ConcreteVersion have unapproved licenses. Halting installation."
        return $false
    }

    # Check Node.js compatibility before proceeding
    $isCompatible = Check-NodeCompatibility -PackageName $PackageName -PackageVersion $ConcreteVersion
    if (-not $isCompatible) {
        Write-Host "Proceeding despite compatibility warning..." -ForegroundColor Yellow
    }

    if ($PackageName.StartsWith("@")) {
        Write-Host "Skipping already-scoped package: $($PackageName)" -ForegroundColor Green
        return $true
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

        # Check if the package still exists publicly
        npm view "$($PackageName)@$($ConcreteVersion)" version --registry=https://registry.npmjs.org/ > $null 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "The original package '$($PackageName)@$($ConcreteVersion)' no longer exists on the public NPM registry. You are installing from your private cache." -ForegroundColor Red
        }
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

function Format-Json {
    [CmdletBinding(DefaultParameterSetName = 'Prettify')]
    Param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [string]$Json,

        [Parameter(ParameterSetName = 'Minify')]
        [switch]$Minify,

        [Parameter(ParameterSetName = 'Prettify')]
        [ValidateRange(1, 1024)]
        [int]$Indentation = 2,

        [Parameter(ParameterSetName = 'Prettify')]
        [switch]$AsArray
    )
    if ($PSCmdlet.ParameterSetName -eq 'Minify') {
        return ($Json | ConvertFrom-Json) | ConvertTo-Json -Depth 100 -Compress
    }
    if ($Json -notmatch '\r?\n') {
        $Json = ($Json | ConvertFrom-Json) | ConvertTo-Json -Depth 100
    }
    $indent = 0
    $regexUnlessQuoted = '(?=([^"]*"[^"]*")*[^"]*$)'
    $result = ($Json -split '\r?\n' | ForEach-Object {
        if (($_ -match "[}\]]$regexUnlessQuoted") -and ($_ -notmatch "[\{\[]$regexUnlessQuoted")) {
            $indent = [Math]::Max($indent - $Indentation, 0)
        }
        # Replace all colon-space combinations by ": " unless it is inside quotes.
        $line = (' ' * $indent) + ($_.TrimStart() -replace ":\s+$regexUnlessQuoted", ': ')
        if (($_ -match "[\{\[]$regexUnlessQuoted") -and ($_ -notmatch "[}\]]$regexUnlessQuoted")) {
            $indent += $Indentation
        }
        $line -replace '\\u0027', "'"
    # join the array with newlines and convert multiline empty [] or {} into inline arrays or objects
    }) -join [Environment]::NewLine -replace '(\[)\s+(\])', '$1$2' -replace '(\{)\s+(\})', '$1$2'

    if ($AsArray) { return ,[string[]]($result -split '\r?\n') }
    $result
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
            # Resolve concrete version
            $installVersion = Get-PackageVersion -PackageName $packageNameFromArg -VersionSpec $versionSpecFromArg
            $scopedInstall = "@$GithubUsername/$packageNameFromArg@$installVersion"
            Write-Host "Installing (scoped from GitHub cache) $scopedInstall ..." -ForegroundColor Cyan
            try {
                # Install scoped package (registry for this scope is set via .npmrc; don't override global to allow unscoped deps from public registry)
                $installOutput = npm install $scopedInstall --no-save 2>&1 | Tee-Object -Variable rawOut
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Downloaded scoped package: $scopedInstall" -ForegroundColor Green
                    Update-PackageJsonDependency -PackageName $packageNameFromArg -Version $installVersion
                    Ensure-UnscopedAlias -PackageName $packageNameFromArg
                    $successfulPackages += "$packageNameFromArg@$installVersion"
                } else {
                    if ($rawOut -match 'E404' -or $rawOut -match '404 Not Found') {
                        Write-Warning "Scoped package not found. Falling back to public unscoped install: $packageNameFromArg@$installVersion"
                        npm install "$packageNameFromArg@$installVersion" --save-exact
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "Installed unscoped from public registry: $packageNameFromArg@$installVersion" -ForegroundColor Yellow
                            Update-PackageJsonDependency -PackageName $packageNameFromArg -Version $installVersion
                            $successfulPackages += "$packageNameFromArg@$installVersion"
                        } else {
                            Write-Host "Error installing fallback unscoped package $packageNameFromArg@$installVersion" -ForegroundColor Red
                            Write-VersionSuggestions -PackageName $packageNameFromArg -ProblemVersion $installVersion
                        }
                    } else {
                        Write-Host "Error installing $scopedInstall" -ForegroundColor Red
                        Write-VersionSuggestions -PackageName $packageNameFromArg -ProblemVersion $installVersion
                    }
                }
            } catch {
                Write-Host "Error installing $scopedInstall" -ForegroundColor Red
                Write-Host $_.Exception.Message
                Write-VersionSuggestions -PackageName $packageNameFromArg -ProblemVersion $installVersion
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
            $resolvedVersion = Get-PackageVersion -PackageName $entry.Name -VersionSpec $entry.Value
            $scopedInstall = "@$GithubUsername/$($entry.Name)@$resolvedVersion"
            try {
                # Scoped install; .npmrc handles registry routing
                $cacheOut = npm install $scopedInstall --no-save 2>&1 | Tee-Object -Variable rawCacheOut
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Cached / verified $scopedInstall" -ForegroundColor Green
                    Update-PackageJsonDependency -PackageName $entry.Name -Version $resolvedVersion
                    Ensure-UnscopedAlias -PackageName $entry.Name
                    $cachedCount++
                } else {
                    if ($rawCacheOut -match 'E404' -or $rawCacheOut -match '404 Not Found') {
                        Write-Warning "Scoped package not found for $($entry.Name). Falling back to unscoped public install."
                        npm install "$($entry.Name)@$resolvedVersion" --save-exact --no-save
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "Installed unscoped $($entry.Name)@$resolvedVersion from public registry" -ForegroundColor Yellow
                            Update-PackageJsonDependency -PackageName $entry.Name -Version $resolvedVersion
                            $cachedCount++
                        } else {
                            Write-Host "Error installing fallback unscoped $($entry.Name)@$resolvedVersion" -ForegroundColor Red
                            Write-VersionSuggestions -PackageName $entry.Name -ProblemVersion $resolvedVersion
                        }
                    } else {
                        Write-Host "Error installing $scopedInstall" -ForegroundColor Red
                        Write-VersionSuggestions -PackageName $entry.Name -ProblemVersion $resolvedVersion
                    }
                }
            } catch {
                Write-Host "Error installing $scopedInstall" -ForegroundColor Red
                Write-VersionSuggestions -PackageName $entry.Name -ProblemVersion $resolvedVersion
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


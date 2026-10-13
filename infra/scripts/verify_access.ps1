<#
.SYNOPSIS
    Verifies that the Content Processing frontend/API can reach Azure Cosmos DB
    and Azure Blob Storage, and (optionally) enables access when it can't.

.DESCRIPTION
    The API/back-end reaches its data stores using the SAME Azure identity you are
    logged in with locally (DefaultAzureCredential -> Azure CLI credential). This
    script exercises each of those access paths and reports PASS / FAIL:

      1. Azure App Configuration  - AAD/RBAC ("App Configuration Data Reader").
                                    All other endpoints are read from here.
      2. Azure Blob Storage       - AAD/RBAC ("Storage Blob Data Contributor").
      3. Azure Cosmos DB (Mongo)  - key-based connection string stored in App
                                    Configuration + network reachability.

    When a check fails and remediation is possible (RBAC), the script assigns the
    required role to the signed-in user (or -PrincipalId). Cosmos DB uses a
    key-based connection string, so there is no role to assign - the script
    validates connectivity and the connection string instead.

.PARAMETER AppConfigEndpoint
    Azure App Configuration endpoint (e.g. https://appcs-xxxx.azconfig.io).
    If omitted, it is read from src/ContentProcessorAPI/app/.env (APP_CONFIG_ENDPOINT).

.PARAMETER PrincipalId
    Object ID of the identity to grant access to. Defaults to the signed-in user.

.PARAMETER CheckOnly
    Only verify. Never create role assignments or change anything.

.PARAMETER Force
    Skip the confirmation prompt before creating role assignments.

.EXAMPLE
    ./verify_access.ps1
    Reads the endpoint from the API .env, verifies access, and offers to fix issues.

.EXAMPLE
    ./verify_access.ps1 -AppConfigEndpoint https://appcs-abc.azconfig.io -Force

.EXAMPLE
    ./verify_access.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
    [string]$AppConfigEndpoint,
    [string]$PrincipalId,
    [switch]$CheckOnly,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Well-known role definition IDs (stable across tenants).
$RoleAppConfigDataReader = '516239f1-63e1-4d78-a4de-a74fb236a071'  # App Configuration Data Reader
$RoleStorageBlobContrib  = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'  # Storage Blob Data Contributor

$script:failures = 0
$script:fixes    = 0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Header($text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }
function Write-Pass($text)   { Write-Host "  [PASS] $text" -ForegroundColor Green }
function Write-Fail($text)   { Write-Host "  [FAIL] $text" -ForegroundColor Red;    $script:failures++ }
function Write-Fixed($text)  { Write-Host "  [FIXED] $text" -ForegroundColor Green; $script:fixes++ }
function Write-Info($text)   { Write-Host "  $text" -ForegroundColor Gray }
function Write-Warn2($text)  { Write-Host "  [WARN] $text" -ForegroundColor Yellow }

# Run an `az` command. Returns @{ Ok = $bool; Output = <string>; Error = <string> }.
# stderr is captured separately so warnings emitted by `az` (e.g. deprecation
# notices) never contaminate stdout - otherwise JSON parsing of the output fails.
function Invoke-Az {
    param([string[]]$AzArgs)
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = & az @AzArgs 2>$errFile
        $ok = ($LASTEXITCODE -eq 0)
        $errText = (Get-Content -Raw -Path $errFile -ErrorAction SilentlyContinue)
    } finally {
        Remove-Item $errFile -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{
        Ok     = $ok
        Output = (($stdout | Out-String).Trim())
        Error  = (($errText | Out-String).Trim())
    }
}

function Confirm-Fix([string]$action) {
    if ($CheckOnly) { return $false }
    if ($Force)     { return $true }
    Write-Host "  About to: $action" -ForegroundColor Yellow
    $ans = Read-Host "  Proceed? (y/N)"
    return ($ans -match '^(y|yes)$')
}

# Best-effort public IP of this client, used to allow-list the machine on a
# resource firewall when public network access has to be (re-)enabled.
function Get-ClientIp {
    foreach ($u in @('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com')) {
        try {
            $ip = (Invoke-RestMethod -Uri $u -TimeoutSec 8).ToString().Trim()
            if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip }
        } catch { }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 0. Preflight - Azure CLI present and logged in
# ---------------------------------------------------------------------------
Write-Header 'Preflight'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Fail 'Azure CLI (az) is not installed or not on PATH. Install it first.'
    exit 1
}

$account = Invoke-Az @('account', 'show', '-o', 'json')
if (-not $account.Ok) {
    Write-Fail 'Not logged in to Azure CLI. Run: az login'
    exit 1
}
$accountObj   = $account.Output | ConvertFrom-Json
$subscription = $accountObj.id
Write-Pass "Azure CLI logged in (subscription: $($accountObj.name))"

# Resolve the principal (signed-in user by default).
if (-not $PrincipalId) {
    $me = Invoke-Az @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv')
    if ($me.Ok -and $me.Output) {
        $PrincipalId = $me.Output
        Write-Pass "Target identity: signed-in user ($PrincipalId)"
    } else {
        Write-Warn2 'Could not resolve signed-in user object ID. Pass -PrincipalId to enable remediation.'
    }
} else {
    Write-Pass "Target identity: $PrincipalId"
}

# ---------------------------------------------------------------------------
# Resolve App Configuration endpoint
# ---------------------------------------------------------------------------
if (-not $AppConfigEndpoint) {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    $envPath  = Join-Path $repoRoot 'src/ContentProcessorAPI/app/.env'
    if (Test-Path $envPath) {
        $line = Select-String -Path $envPath -Pattern '^\s*APP_CONFIG_ENDPOINT\s*=' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($line) {
            $AppConfigEndpoint = ($line.Line -replace '^\s*APP_CONFIG_ENDPOINT\s*=', '').Trim().Trim('"').Trim("'")
            Write-Info "Read APP_CONFIG_ENDPOINT from $envPath"
        }
    }
}
if (-not $AppConfigEndpoint) {
    Write-Fail 'App Configuration endpoint not provided and not found in the API .env. Pass -AppConfigEndpoint.'
    exit 1
}
$AppConfigEndpoint = $AppConfigEndpoint.TrimEnd('/')
Write-Pass "App Configuration endpoint: $AppConfigEndpoint"

# ---------------------------------------------------------------------------
# 1. Azure App Configuration - data-plane read access (RBAC)
# ---------------------------------------------------------------------------
Write-Header 'Azure App Configuration (read access)'

# Locate the App Configuration resource so we can scope a role assignment to it.
$appConfigId = $null
$acList = Invoke-Az @('appconfig', 'list', '--query', "[?ends_with(endpoint, '$($AppConfigEndpoint -replace '^https://','')')].id", '-o', 'tsv')
if ($acList.Ok -and $acList.Output) { $appConfigId = ($acList.Output -split "`n")[0].Trim() }

function Test-AppConfigRead {
    $r = Invoke-Az @('appconfig', 'kv', 'show', '--endpoint', $AppConfigEndpoint, '--auth-mode', 'login',
        '--key', 'APP_STORAGE_BLOB_URL', '-o', 'json')
    return $r
}

$acRead = Test-AppConfigRead
if ($acRead.Ok) {
    Write-Pass 'Can read settings from App Configuration.'
} else {
    Write-Fail 'Cannot read settings from App Configuration (missing "App Configuration Data Reader"?).'
    if ($PrincipalId -and $appConfigId -and (Confirm-Fix "assign 'App Configuration Data Reader' on $appConfigId")) {
        $ra = Invoke-Az @('role', 'assignment', 'create', '--assignee-object-id', $PrincipalId,
            '--assignee-principal-type', 'User', '--role', $RoleAppConfigDataReader, '--scope', $appConfigId)
        if ($ra.Ok) {
            Write-Fixed "Assigned 'App Configuration Data Reader'. RBAC can take a few minutes to propagate."
            Write-Info 'Waiting up to 90s for propagation...'
            for ($i = 0; $i -lt 9; $i++) {
                Start-Sleep -Seconds 10
                if ((Test-AppConfigRead).Ok) { Write-Pass 'Access confirmed after propagation.'; break }
            }
        } else {
            Write-Fail "Role assignment failed: $($ra.Output)"
        }
    } elseif (-not $appConfigId) {
        Write-Warn2 'Could not locate the App Configuration resource to scope a role assignment.'
    }
}

# We cannot verify Cosmos/Blob without the config values. Try to read them.
$blobUrl = $null; $cosmosConnStr = $null; $cosmosDb = $null
$finalRead = Test-AppConfigRead
if ($finalRead.Ok) {
    $blobUrl = ($finalRead.Output | ConvertFrom-Json).value
    $cs = Invoke-Az @('appconfig', 'kv', 'show', '--endpoint', $AppConfigEndpoint, '--auth-mode', 'login', '--key', 'APP_COSMOS_CONNSTR', '-o', 'json')
    if ($cs.Ok) { $cosmosConnStr = ($cs.Output | ConvertFrom-Json).value }
    $db = Invoke-Az @('appconfig', 'kv', 'show', '--endpoint', $AppConfigEndpoint, '--auth-mode', 'login', '--key', 'APP_COSMOS_DATABASE', '-o', 'json')
    if ($db.Ok) { $cosmosDb = ($db.Output | ConvertFrom-Json).value }
}

# ---------------------------------------------------------------------------
# 2. Azure Blob Storage - data-plane access (RBAC)
# ---------------------------------------------------------------------------
Write-Header 'Azure Blob Storage (read/write access)'

if (-not $blobUrl) {
    Write-Fail 'Blob endpoint unknown (App Configuration is not readable yet). Fix App Configuration access first.'
} else {
    Write-Info "Blob endpoint: $blobUrl"
    # https://<account>.blob.core.windows.net/ -> <account>
    $storageAccount = ([Uri]$blobUrl).Host.Split('.')[0]

    function Test-BlobAccess {
        param([string]$Account)
        return Invoke-Az @('storage', 'container', 'list', '--account-name', $Account,
            '--auth-mode', 'login', '--num-results', '1', '-o', 'json')
    }

    # Resolve the storage account resource id / resource group once (used by both
    # the network and RBAC remediation paths below).
    $saId = $null; $saRg = $null
    $saShow = Invoke-Az @('storage', 'account', 'list', '--query', "[?name=='$storageAccount'].{id:id,rg:resourceGroup}", '-o', 'json')
    if ($saShow.Ok -and $saShow.Output) {
        $saObj = @($saShow.Output | ConvertFrom-Json)
        if ($saObj.Count -gt 0) { $saId = $saObj[0].id; $saRg = $saObj[0].rg }
    }

    # Network pre-check: even with the correct RBAC role, the data plane is
    # unreachable when public network access is disabled or the client IP is not
    # allow-listed. This is a distinct failure mode from RBAC.
    if ($saRg) {
        $pna = (Invoke-Az @('storage', 'account', 'show', '-n', $storageAccount, '-g', $saRg, '--query', 'publicNetworkAccess', '-o', 'tsv')).Output
        if ($pna -eq 'Disabled') {
            Write-Warn2 "Storage account '$storageAccount' has public network access DISABLED (private-endpoint only)."
            $clientIp = Get-ClientIp
            if ($clientIp -and (Confirm-Fix "enable public network access on '$storageAccount' (default-deny) and allow-list your IP $clientIp")) {
                $u1 = Invoke-Az @('storage', 'account', 'update', '-n', $storageAccount, '-g', $saRg, '--public-network-access', 'Enabled', '--default-action', 'Deny')
                $u2 = Invoke-Az @('storage', 'account', 'network-rule', 'add', '-n', $storageAccount, '-g', $saRg, '--ip-address', $clientIp)
                if ($u1.Ok -and $u2.Ok) { Write-Fixed "Enabled public access on '$storageAccount' and allow-listed $clientIp." }
                else { Write-Fail "Failed to update storage network rules: $($u1.Error)$($u2.Error)" }
            } elseif (-not $clientIp) {
                Write-Warn2 'Could not determine your public IP to allow-list. Enable access manually or run from the VNet.'
            }
        }
    }

    $blob = Test-BlobAccess -Account $storageAccount
    if ($blob.Ok) {
        Write-Pass "Can access Blob Storage account '$storageAccount'."
    } else {
        Write-Fail "Cannot access Blob Storage account '$storageAccount' (missing 'Storage Blob Data Contributor' or blocked by network rules?)."
        if ($PrincipalId -and $saId -and (Confirm-Fix "assign 'Storage Blob Data Contributor' on $saId")) {
            $ra = Invoke-Az @('role', 'assignment', 'create', '--assignee-object-id', $PrincipalId,
                '--assignee-principal-type', 'User', '--role', $RoleStorageBlobContrib, '--scope', $saId)
            if ($ra.Ok) {
                Write-Fixed "Assigned 'Storage Blob Data Contributor'. RBAC can take a few minutes to propagate."
                Write-Info 'Waiting up to 90s for propagation...'
                for ($i = 0; $i -lt 9; $i++) {
                    Start-Sleep -Seconds 10
                    if ((Test-BlobAccess -Account $storageAccount).Ok) { Write-Pass 'Access confirmed after propagation.'; break }
                }
            } else {
                Write-Fail "Role assignment failed: $($ra.Output)$($ra.Error)"
            }
        } elseif (-not $saId) {
            Write-Warn2 "Could not locate storage account '$storageAccount' in this subscription to scope a role assignment."
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Azure Cosmos DB (Mongo API) - connection string + reachability
# ---------------------------------------------------------------------------
Write-Header 'Azure Cosmos DB (Mongo API) connectivity'

if (-not $cosmosConnStr) {
    Write-Fail 'Cosmos DB connection string unknown (App Configuration is not readable yet). Fix App Configuration access first.'
} else {
    Write-Pass 'Cosmos DB connection string retrieved from App Configuration.'
    if ($cosmosDb) { Write-Info "Database: $cosmosDb" }

    # Parse host:port from the mongodb connection string.
    $cosmosHost = $null; $cosmosPort = 10255
    if ($cosmosConnStr -match '@([^:/?]+):(\d+)') {
        $cosmosHost = $Matches[1]; $cosmosPort = [int]$Matches[2]
    } elseif ($cosmosConnStr -match '@([^:/?,]+)') {
        $cosmosHost = $Matches[1]
    }

    if (-not $cosmosHost) {
        Write-Warn2 'Could not parse the Cosmos DB host from the connection string; skipping reachability test.'
    } else {
        Write-Info "Testing TCP reachability to ${cosmosHost}:${cosmosPort} ..."
        $tcp = Test-NetConnection -ComputerName $cosmosHost -Port $cosmosPort -WarningAction SilentlyContinue
        if ($tcp.TcpTestSucceeded) {
            Write-Pass "Cosmos DB endpoint is reachable at ${cosmosHost}:${cosmosPort}."
        } else {
            Write-Fail "Cosmos DB endpoint ${cosmosHost}:${cosmosPort} is NOT reachable."
            Write-Info 'Cosmos (Mongo API) uses a key-based connection string, so there is no RBAC role to assign.'
            # Attempt to remediate a network block (disabled public access / IP firewall).
            $cosmosAccount = $cosmosHost.Split('.')[0]
            $cdb = Invoke-Az @('cosmosdb', 'list', '--query', "[?name=='$cosmosAccount'].{rg:resourceGroup}", '-o', 'json')
            $cdbRg = $null
            if ($cdb.Ok -and $cdb.Output) {
                $cdbObj = @($cdb.Output | ConvertFrom-Json)
                if ($cdbObj.Count -gt 0) { $cdbRg = $cdbObj[0].rg }
            }
            if ($cdbRg) {
                $clientIp = Get-ClientIp
                if ($clientIp -and (Confirm-Fix "enable public network access on Cosmos '$cosmosAccount' and allow-list your IP $clientIp (can take 10-20 min)")) {
                    $cu = Invoke-Az @('cosmosdb', 'update', '-n', $cosmosAccount, '-g', $cdbRg, '--public-network-access', 'ENABLED', '--ip-range-filter', $clientIp)
                    if ($cu.Ok) { Write-Fixed "Enabled public access on Cosmos '$cosmosAccount' and allow-listed $clientIp. Re-run to confirm reachability." }
                    else { Write-Fail "Cosmos network update failed: $($cu.Error)" }
                } elseif (-not $clientIp) {
                    Write-Warn2 'Could not determine your public IP to allow-list. Enable access manually or run from the VNet.'
                }
            } else {
                Write-Info 'Likely causes:'
                Write-Info '  - Private endpoint enabled: reachable only from within the VNet. Run from a peered/VPN network.'
                Write-Info '  - Public network access disabled or a firewall rule is blocking your client IP.'
            }
        }

        # Optional definitive auth test using the API virtual environment (pymongo).
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
        $venvPy = Join-Path $repoRoot 'src/ContentProcessorAPI/.venv/Scripts/python.exe'
        if (Test-Path $venvPy) {
            Write-Info 'Running an authenticated ping via pymongo (API virtual environment)...'
            $pyScript = @'
import sys
try:
    import pymongo
    c = pymongo.MongoClient(sys.argv[1], serverSelectionTimeoutMS=8000)
    c.admin.command("ping")
    print("PING_OK")
except Exception as e:
    print("PING_FAIL:" + str(e))
'@
            $tmp = New-TemporaryFile
            Set-Content -Path $tmp -Value $pyScript -Encoding utf8
            try {
                $pingOut = & $venvPy $tmp $cosmosConnStr 2>&1 | Out-String
                if ($pingOut -match 'PING_OK') {
                    Write-Pass 'Authenticated Cosmos DB (Mongo) ping succeeded.'
                } else {
                    Write-Fail "Authenticated Cosmos DB ping failed: $($pingOut.Trim())"
                }
            } finally {
                Remove-Item $tmp -ErrorAction SilentlyContinue
            }
        } else {
            Write-Info 'API virtual environment not found; skipped the authenticated pymongo ping (TCP test only).'
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Header 'Summary'
if ($script:fixes -gt 0) { Write-Host "  Remediations applied: $($script:fixes)" -ForegroundColor Green }
if ($script:failures -eq 0) {
    Write-Host "  All access checks passed. The frontend/API can reach Cosmos DB and Blob Storage." -ForegroundColor Green
    exit 0
} else {
    Write-Host "  $($script:failures) check(s) still failing. Review the messages above." -ForegroundColor Red
    if ($CheckOnly) { Write-Info 'Run again without -CheckOnly to enable access automatically.' }
    exit 2
}

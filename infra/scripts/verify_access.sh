#!/usr/bin/env bash
#
# verify_access.sh
#
# Verifies that the Content Processing frontend/API can reach Azure Cosmos DB
# and Azure Blob Storage, and (optionally) enables access when it can't.
#
# The API/back-end reaches its data stores using the SAME Azure identity you are
# logged in with locally (DefaultAzureCredential -> Azure CLI credential). This
# script exercises each of those access paths and reports PASS / FAIL:
#
#   1. Azure App Configuration  - AAD/RBAC ("App Configuration Data Reader").
#                                 All other endpoints are read from here.
#   2. Azure Blob Storage       - AAD/RBAC ("Storage Blob Data Contributor").
#   3. Azure Cosmos DB (Mongo)  - key-based connection string stored in App
#                                 Configuration + network reachability.
#
# When a check fails and remediation is possible (RBAC), the script assigns the
# required role to the signed-in user (or --principal-id). Cosmos DB uses a
# key-based connection string, so there is no role to assign - the script
# validates connectivity and the connection string instead.
#
# Usage:
#   ./verify_access.sh [options]
#
# Options:
#   --app-config-endpoint <url>  App Configuration endpoint. Defaults to the
#                                APP_CONFIG_ENDPOINT read from
#                                src/ContentProcessorAPI/app/.env.
#   --principal-id <object-id>   Identity to grant access to. Defaults to the
#                                signed-in user.
#   --check-only                 Only verify. Never change anything.
#   --force                      Skip the confirmation prompt before assigning roles.
#   -h, --help                   Show this help.
#
# Exit codes: 0 = all checks passed, 2 = failures remain, 1 = preflight error.

set -uo pipefail

# Well-known role definition IDs (stable across tenants).
ROLE_APPCONFIG_DATA_READER='516239f1-63e1-4d78-a4de-a74fb236a071'  # App Configuration Data Reader
ROLE_STORAGE_BLOB_CONTRIB='ba92f5b4-2d11-453d-a403-e96b0029c9fe'   # Storage Blob Data Contributor

APP_CONFIG_ENDPOINT=""
PRINCIPAL_ID=""
CHECK_ONLY=false
FORCE=false

FAILURES=0
FIXES=0

# ---------------------------------------------------------------------------
# Colors / output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_RED='\033[0;31m'
    C_YELLOW='\033[0;33m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
else
    C_CYAN=''; C_GREEN=''; C_RED=''; C_YELLOW=''; C_GRAY=''; C_RESET=''
fi

header() { printf "\n${C_CYAN}=== %s ===${C_RESET}\n" "$1"; }
pass()   { printf "  ${C_GREEN}[PASS] %s${C_RESET}\n" "$1"; }
fail()   { printf "  ${C_RED}[FAIL] %s${C_RESET}\n" "$1"; FAILURES=$((FAILURES + 1)); }
fixed()  { printf "  ${C_GREEN}[FIXED] %s${C_RESET}\n" "$1"; FIXES=$((FIXES + 1)); }
info()   { printf "  ${C_GRAY}%s${C_RESET}\n" "$1"; }
warn2()  { printf "  ${C_YELLOW}[WARN] %s${C_RESET}\n" "$1"; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

confirm_fix() {
    # $1 = action description. Returns 0 (yes) / 1 (no).
    $CHECK_ONLY && return 1
    $FORCE && return 0
    printf "  ${C_YELLOW}About to: %s${C_RESET}\n" "$1"
    read -r -p "  Proceed? (y/N) " ans
    [[ "$ans" =~ ^([yY]|[yY][eE][sS])$ ]]
}

# Best-effort public IP of this client, used to allow-list the machine on a
# resource firewall when public network access has to be (re-)enabled.
get_client_ip() {
    local ip=""
    for u in 'https://api.ipify.org' 'https://ifconfig.me/ip' 'https://icanhazip.com'; do
        ip=$(curl -fsS --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then echo "$ip"; return 0; fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-config-endpoint) APP_CONFIG_ENDPOINT="$2"; shift 2 ;;
        --principal-id)        PRINCIPAL_ID="$2"; shift 2 ;;
        --check-only)          CHECK_ONLY=true; shift ;;
        --force)               FORCE=true; shift ;;
        -h|--help)             usage ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# 0. Preflight - Azure CLI present and logged in
# ---------------------------------------------------------------------------
header 'Preflight'

if ! command -v az >/dev/null 2>&1; then
    fail 'Azure CLI (az) is not installed or not on PATH. Install it first.'
    exit 1
fi

if ! az account show -o none 2>/dev/null; then
    fail 'Not logged in to Azure CLI. Run: az login'
    exit 1
fi
sub_name=$(az account show --query name -o tsv 2>/dev/null)
pass "Azure CLI logged in (subscription: ${sub_name})"

# Resolve the principal (signed-in user by default).
if [[ -z "$PRINCIPAL_ID" ]]; then
    if PRINCIPAL_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null) && [[ -n "$PRINCIPAL_ID" ]]; then
        pass "Target identity: signed-in user (${PRINCIPAL_ID})"
    else
        warn2 'Could not resolve signed-in user object ID. Pass --principal-id to enable remediation.'
        PRINCIPAL_ID=""
    fi
else
    pass "Target identity: ${PRINCIPAL_ID}"
fi

# ---------------------------------------------------------------------------
# Resolve App Configuration endpoint
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ -z "$APP_CONFIG_ENDPOINT" ]]; then
    env_path="$REPO_ROOT/src/ContentProcessorAPI/app/.env"
    if [[ -f "$env_path" ]]; then
        line=$(grep -E '^\s*APP_CONFIG_ENDPOINT\s*=' "$env_path" | head -1 || true)
        if [[ -n "$line" ]]; then
            APP_CONFIG_ENDPOINT="${line#*=}"
            APP_CONFIG_ENDPOINT="$(echo "$APP_CONFIG_ENDPOINT" | tr -d '"'"'"' ' | xargs)"
            info "Read APP_CONFIG_ENDPOINT from $env_path"
        fi
    fi
fi
if [[ -z "$APP_CONFIG_ENDPOINT" ]]; then
    fail 'App Configuration endpoint not provided and not found in the API .env. Pass --app-config-endpoint.'
    exit 1
fi
APP_CONFIG_ENDPOINT="${APP_CONFIG_ENDPOINT%/}"
pass "App Configuration endpoint: ${APP_CONFIG_ENDPOINT}"

# ---------------------------------------------------------------------------
# 1. Azure App Configuration - data-plane read access (RBAC)
# ---------------------------------------------------------------------------
header 'Azure App Configuration (read access)'

# Locate the App Configuration resource so we can scope a role assignment to it.
ac_host="${APP_CONFIG_ENDPOINT#https://}"
app_config_id=$(az appconfig list --query "[?ends_with(endpoint, '${ac_host}')].id" -o tsv 2>/dev/null | head -1)

test_appconfig_read() {
    az appconfig kv show --endpoint "$APP_CONFIG_ENDPOINT" --auth-mode login \
        --key 'APP_STORAGE_BLOB_URL' -o json 2>/dev/null
}

if test_appconfig_read >/dev/null; then
    pass 'Can read settings from App Configuration.'
else
    fail 'Cannot read settings from App Configuration (missing "App Configuration Data Reader"?).'
    if [[ -n "$PRINCIPAL_ID" && -n "$app_config_id" ]] && \
        confirm_fix "assign 'App Configuration Data Reader' on $app_config_id"; then
        if az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
            --assignee-principal-type User --role "$ROLE_APPCONFIG_DATA_READER" \
            --scope "$app_config_id" >/dev/null 2>&1; then
            fixed "Assigned 'App Configuration Data Reader'. RBAC can take a few minutes to propagate."
            info 'Waiting up to 90s for propagation...'
            for _ in $(seq 1 9); do
                sleep 10
                if test_appconfig_read >/dev/null; then pass 'Access confirmed after propagation.'; break; fi
            done
        else
            fail 'Role assignment failed (check your permission to grant roles).'
        fi
    elif [[ -z "$app_config_id" ]]; then
        warn2 'Could not locate the App Configuration resource to scope a role assignment.'
    fi
fi

# Try to read the values we need for the Cosmos/Blob checks.
BLOB_URL=""; COSMOS_CONNSTR=""; COSMOS_DB=""
get_kv() {
    az appconfig kv show --endpoint "$APP_CONFIG_ENDPOINT" --auth-mode login \
        --key "$1" --query value -o tsv 2>/dev/null
}
BLOB_URL=$(get_kv 'APP_STORAGE_BLOB_URL')
COSMOS_CONNSTR=$(get_kv 'APP_COSMOS_CONNSTR')
COSMOS_DB=$(get_kv 'APP_COSMOS_DATABASE')

# ---------------------------------------------------------------------------
# 2. Azure Blob Storage - data-plane access (RBAC)
# ---------------------------------------------------------------------------
header 'Azure Blob Storage (read/write access)'

if [[ -z "$BLOB_URL" ]]; then
    fail 'Blob endpoint unknown (App Configuration is not readable yet). Fix App Configuration access first.'
else
    info "Blob endpoint: $BLOB_URL"
    # https://<account>.blob.core.windows.net/ -> <account>
    storage_host="${BLOB_URL#https://}"; storage_host="${storage_host%%/*}"
    storage_account="${storage_host%%.*}"

    test_blob_access() {
        az storage container list --account-name "$storage_account" \
            --auth-mode login --num-results 1 -o json >/dev/null 2>&1
    }

    # Resolve the storage account resource id / resource group once.
    sa_id=$(az storage account list --query "[?name=='${storage_account}'].id" -o tsv 2>/dev/null | head -1)
    sa_rg=$(az storage account list --query "[?name=='${storage_account}'].resourceGroup" -o tsv 2>/dev/null | head -1)

    # Network pre-check: even with the correct RBAC role, the data plane is
    # unreachable when public network access is disabled or the client IP is
    # not allow-listed. This is a distinct failure mode from RBAC.
    if [[ -n "$sa_rg" ]]; then
        sa_pna=$(az storage account show -n "$storage_account" -g "$sa_rg" --query publicNetworkAccess -o tsv 2>/dev/null)
        if [[ "$sa_pna" == 'Disabled' ]]; then
            warn2 "Storage account '$storage_account' has public network access DISABLED (private-endpoint only)."
            client_ip=$(get_client_ip || true)
            if [[ -n "$client_ip" ]] && confirm_fix "enable public network access on '$storage_account' (default-deny) and allow-list your IP $client_ip"; then
                if az storage account update -n "$storage_account" -g "$sa_rg" --public-network-access Enabled --default-action Deny >/dev/null 2>&1 && \
                   az storage account network-rule add -n "$storage_account" -g "$sa_rg" --ip-address "$client_ip" >/dev/null 2>&1; then
                    fixed "Enabled public access on '$storage_account' and allow-listed $client_ip."
                else
                    fail 'Failed to update storage network rules.'
                fi
            elif [[ -z "$client_ip" ]]; then
                warn2 'Could not determine your public IP to allow-list. Enable access manually or run from the VNet.'
            fi
        fi
    fi

    if test_blob_access; then
        pass "Can access Blob Storage account '$storage_account'."
    else
        fail "Cannot access Blob Storage account '$storage_account' (missing 'Storage Blob Data Contributor' or blocked by network rules?)."
        if [[ -n "$PRINCIPAL_ID" && -n "$sa_id" ]] && \
            confirm_fix "assign 'Storage Blob Data Contributor' on $sa_id"; then
            if az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
                --assignee-principal-type User --role "$ROLE_STORAGE_BLOB_CONTRIB" \
                --scope "$sa_id" >/dev/null 2>&1; then
                fixed "Assigned 'Storage Blob Data Contributor'. RBAC can take a few minutes to propagate."
                info 'Waiting up to 90s for propagation...'
                for _ in $(seq 1 9); do
                    sleep 10
                    if test_blob_access; then pass 'Access confirmed after propagation.'; break; fi
                done
            else
                fail 'Role assignment failed (check your permission to grant roles).'
            fi
        elif [[ -z "$sa_id" ]]; then
            warn2 "Could not locate storage account '$storage_account' in this subscription to scope a role assignment."
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 3. Azure Cosmos DB (Mongo API) - connection string + reachability
# ---------------------------------------------------------------------------
header 'Azure Cosmos DB (Mongo API) connectivity'

if [[ -z "$COSMOS_CONNSTR" ]]; then
    fail 'Cosmos DB connection string unknown (App Configuration is not readable yet). Fix App Configuration access first.'
else
    pass 'Cosmos DB connection string retrieved from App Configuration.'
    [[ -n "$COSMOS_DB" ]] && info "Database: $COSMOS_DB"

    # Parse host:port from the mongodb connection string.
    cosmos_host=""; cosmos_port=10255
    if [[ "$COSMOS_CONNSTR" =~ @([^:/?]+):([0-9]+) ]]; then
        cosmos_host="${BASH_REMATCH[1]}"; cosmos_port="${BASH_REMATCH[2]}"
    elif [[ "$COSMOS_CONNSTR" =~ @([^:/?,]+) ]]; then
        cosmos_host="${BASH_REMATCH[1]}"
    fi

    if [[ -z "$cosmos_host" ]]; then
        warn2 'Could not parse the Cosmos DB host from the connection string; skipping reachability test.'
    else
        info "Testing TCP reachability to ${cosmos_host}:${cosmos_port} ..."
        reachable=false
        if command -v nc >/dev/null 2>&1; then
            nc -z -w 8 "$cosmos_host" "$cosmos_port" >/dev/null 2>&1 && reachable=true
        else
            # Fallback using bash /dev/tcp.
            (exec 3<>"/dev/tcp/${cosmos_host}/${cosmos_port}") >/dev/null 2>&1 && { reachable=true; exec 3>&- 3<&- 2>/dev/null; }
        fi

        if $reachable; then
            pass "Cosmos DB endpoint is reachable at ${cosmos_host}:${cosmos_port}."
        else
            fail "Cosmos DB endpoint ${cosmos_host}:${cosmos_port} is NOT reachable."
            info 'Cosmos (Mongo API) uses a key-based connection string, so there is no RBAC role to assign.'
            # Attempt to remediate a network block (disabled public access / IP firewall).
            cosmos_account="${cosmos_host%%.*}"
            cdb_rg=$(az cosmosdb list --query "[?name=='${cosmos_account}'].resourceGroup" -o tsv 2>/dev/null | head -1)
            if [[ -n "$cdb_rg" ]]; then
                client_ip=$(get_client_ip || true)
                if [[ -n "$client_ip" ]] && confirm_fix "enable public network access on Cosmos '$cosmos_account' and allow-list your IP $client_ip (can take 10-20 min)"; then
                    if az cosmosdb update -n "$cosmos_account" -g "$cdb_rg" --public-network-access ENABLED --ip-range-filter "$client_ip" >/dev/null 2>&1; then
                        fixed "Enabled public access on Cosmos '$cosmos_account' and allow-listed $client_ip. Re-run to confirm reachability."
                    else
                        fail 'Cosmos network update failed.'
                    fi
                elif [[ -z "$client_ip" ]]; then
                    warn2 'Could not determine your public IP to allow-list. Enable access manually or run from the VNet.'
                fi
            else
                info 'Likely causes:'
                info '  - Private endpoint enabled: reachable only from within the VNet. Run from a peered/VPN network.'
                info '  - Public network access disabled or a firewall rule is blocking your client IP.'
            fi
        fi

        # Optional definitive auth test using the API virtual environment (pymongo).
        venv_py="$REPO_ROOT/src/ContentProcessorAPI/.venv/bin/python"
        if [[ -x "$venv_py" ]]; then
            info 'Running an authenticated ping via pymongo (API virtual environment)...'
            ping_out=$("$venv_py" - "$COSMOS_CONNSTR" <<'PYEOF' 2>&1
import sys
try:
    import pymongo
    c = pymongo.MongoClient(sys.argv[1], serverSelectionTimeoutMS=8000)
    c.admin.command("ping")
    print("PING_OK")
except Exception as e:
    print("PING_FAIL:" + str(e))
PYEOF
)
            if [[ "$ping_out" == *PING_OK* ]]; then
                pass 'Authenticated Cosmos DB (Mongo) ping succeeded.'
            else
                fail "Authenticated Cosmos DB ping failed: ${ping_out}"
            fi
        else
            info 'API virtual environment not found; skipped the authenticated pymongo ping (TCP test only).'
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header 'Summary'
[[ $FIXES -gt 0 ]] && printf "  ${C_GREEN}Remediations applied: %s${C_RESET}\n" "$FIXES"
if [[ $FAILURES -eq 0 ]]; then
    printf "  ${C_GREEN}All access checks passed. The frontend/API can reach Cosmos DB and Blob Storage.${C_RESET}\n"
    exit 0
else
    printf "  ${C_RED}%s check(s) still failing. Review the messages above.${C_RESET}\n" "$FAILURES"
    $CHECK_ONLY && info 'Run again without --check-only to enable access automatically.'
    exit 2
fi

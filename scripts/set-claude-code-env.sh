#!/usr/bin/env bash
# Configures the current shell so Claude Code talks to Claude models in
# Microsoft Foundry, either directly or through the API Management AI gateway.
#
# MUST BE SOURCED so the variables persist:
#
#   source ./scripts/set-claude-code-env.sh direct  entra
#   source ./scripts/set-claude-code-env.sh gateway key
#
# Arguments:
#   $1  mode  : direct | gateway   (default: direct)
#   $2  auth  : entra  | key       (default: entra)
#
# Requires jq, the Azure CLI, and .deployment-outputs.json from ./scripts/deploy.ps1
# (or `az deployment sub show -n <name> --query properties.outputs`).

MODE="${1:-direct}"
AUTH="${2:-entra}"

_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_outputs="${CLAUDE_FOUNDRY_OUTPUTS:-$_repo_root/.deployment-outputs.json}"

if [ ! -f "$_outputs" ]; then
  echo "Deployment outputs not found at $_outputs" >&2
  return 1 2>/dev/null || exit 1
fi

_get() { jq -r --arg k "$1" '.[$k] // empty' "$_outputs"; }

# ANTHROPIC_FOUNDRY_RESOURCE and ANTHROPIC_FOUNDRY_BASE_URL are mutually
# exclusive, and a stale key silently wins over the default credential chain.
unset ANTHROPIC_FOUNDRY_RESOURCE ANTHROPIC_FOUNDRY_BASE_URL \
      ANTHROPIC_FOUNDRY_API_KEY ANTHROPIC_FOUNDRY_AUTH_TOKEN \
      ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL

export CLAUDE_CODE_USE_FOUNDRY=1

_rg="$(_get resourceGroupName)"
_account="$(_get foundryAccountName)"

case "$MODE" in
  direct)
    export ANTHROPIC_FOUNDRY_RESOURCE="$_account"
    _endpoint="$(_get foundryAnthropicBaseUrl)"
    ;;
  gateway)
    _endpoint="$(_get gatewayAnthropicBaseUrl)"
    if [ -z "$_endpoint" ]; then
      echo "gatewayAnthropicBaseUrl is empty. Redeploy with deployGateway = true." >&2
      return 1 2>/dev/null || exit 1
    fi
    # Claude Code only appends /anthropic for ANTHROPIC_FOUNDRY_RESOURCE, so
    # the gateway base URL must already contain the API path.
    export ANTHROPIC_FOUNDRY_BASE_URL="$_endpoint"
    ;;
  *)
    echo "Unknown mode '$MODE'. Use 'direct' or 'gateway'." >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

case "$AUTH" in
  entra)
    # Claude Code falls back to the Azure SDK default credential chain when no
    # key or token variable is set. Nothing to export beyond `az login`.
    _cred="Microsoft Entra ID (default credential chain)"
    ;;
  token)
    ANTHROPIC_FOUNDRY_AUTH_TOKEN="$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)"
    export ANTHROPIC_FOUNDRY_AUTH_TOKEN
    _cred="Microsoft Entra ID (static bearer token, expires in ~1 hour)"
    ;;
  key)
    if [ "$MODE" = "direct" ]; then
      ANTHROPIC_FOUNDRY_API_KEY="$(az cognitiveservices account keys list \
        --name "$_account" --resource-group "$_rg" --query key1 -o tsv)"
      _cred="Foundry account API key"
    else
      _sub="$(az account show --query id -o tsv)"
      _uri="/subscriptions/$_sub/resourceGroups/$_rg/providers/Microsoft.ApiManagement/service/$(_get apimName)/subscriptions/$(_get gatewaySubscriptionName)/listSecrets?api-version=2024-05-01"
      ANTHROPIC_FOUNDRY_API_KEY="$(az rest --method post --uri "$_uri" --query primaryKey -o tsv)"
      _cred="API Management subscription key"
    fi
    export ANTHROPIC_FOUNDRY_API_KEY
    ;;
  *)
    echo "Unknown auth '$AUTH'. Use 'entra', 'token' or 'key'." >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

# Aliases such as 'sonnet' resolve to Claude Code's built-in Foundry defaults,
# which may not exist in this account. Always pin to real deployment names.
[ -n "$(_get sonnetDeploymentName)" ] && export ANTHROPIC_DEFAULT_SONNET_MODEL="$(_get sonnetDeploymentName)"
[ -n "$(_get haikuDeploymentName)"  ] && export ANTHROPIC_DEFAULT_HAIKU_MODEL="$(_get haikuDeploymentName)"
[ -n "$(_get opusDeploymentName)"   ] && export ANTHROPIC_DEFAULT_OPUS_MODEL="$(_get opusDeploymentName)"

echo
echo "Claude Code configured"
printf '%-14s %s\n' "Mode:"       "$MODE"
printf '%-14s %s\n' "Endpoint:"   "$_endpoint"
printf '%-14s %s\n' "Credential:" "$_cred"
printf '%-14s %s\n' "Sonnet:"     "${ANTHROPIC_DEFAULT_SONNET_MODEL:-<unset>}"
printf '%-14s %s\n' "Haiku:"      "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-<unset>}"
echo
echo "Run 'claude' then '/status' to confirm the API provider shows Microsoft Foundry."

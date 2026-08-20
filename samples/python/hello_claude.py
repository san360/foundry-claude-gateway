"""
Claude on Microsoft Foundry - minimal SDK sample.

Demonstrates all four combinations the demo cares about:

    path        credential
    --------    ----------------------------------------------------
    direct      Microsoft Entra ID (DefaultAzureCredential)
    direct      Foundry account API key
    gateway     Microsoft Entra ID (token validated by API Management)
    gateway     API Management subscription key

Usage:
    pip install -r requirements.txt
    python hello_claude.py --path direct  --auth entra
    python hello_claude.py --path gateway --auth key --prompt "Say hi"

Configuration is read from .deployment-outputs.json (written by
scripts/deploy.ps1) and can be overridden with environment variables or flags.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from anthropic import AnthropicFoundry

# Foundry's Anthropic surface issues Entra tokens for this resource. Note this
# differs from the generic Foundry model-inference scope
# (https://cognitiveservices.azure.com/.default).
FOUNDRY_TOKEN_SCOPE = "https://ai.azure.com/.default"

REPO_ROOT = Path(__file__).resolve().parents[2]
OUTPUTS_FILE = Path(
    os.environ.get("CLAUDE_FOUNDRY_OUTPUTS", REPO_ROOT / ".deployment-outputs.json")
)


def load_outputs() -> dict:
    if not OUTPUTS_FILE.exists():
        return {}
    return json.loads(OUTPUTS_FILE.read_text(encoding="utf-8-sig"))


def entra_token_provider():
    """Returns a callable that mints a fresh Foundry access token on demand.

    The SDK invokes this per request, so token refresh is handled for us. In
    gateway mode the same token is what the validate-azure-ad-token policy
    inspects, which is why the audience must match {{entra-audience}}.
    """
    from azure.identity import DefaultAzureCredential, get_bearer_token_provider

    return get_bearer_token_provider(DefaultAzureCredential(), FOUNDRY_TOKEN_SCOPE)


def resolve_api_key(path: str, outputs: dict) -> str:
    """Reads the appropriate key via the Azure CLI so nothing is stored on disk."""
    import subprocess

    if key := os.environ.get("ANTHROPIC_FOUNDRY_API_KEY"):
        return key

    if path == "direct":
        cmd = [
            "az", "cognitiveservices", "account", "keys", "list",
            "--name", outputs["foundryAccountName"],
            "--resource-group", outputs["resourceGroupName"],
            "--query", "key1", "-o", "tsv",
        ]
    else:
        sub = subprocess.run(
            ["az", "account", "show", "--query", "id", "-o", "tsv"],
            capture_output=True, text=True, check=True, shell=os.name == "nt",
        ).stdout.strip()
        uri = (
            f"/subscriptions/{sub}/resourceGroups/{outputs['resourceGroupName']}"
            f"/providers/Microsoft.ApiManagement/service/{outputs['apimName']}"
            f"/subscriptions/{outputs['gatewaySubscriptionName']}"
            "/listSecrets?api-version=2024-05-01"
        )
        cmd = ["az", "rest", "--method", "post", "--uri", uri,
               "--query", "primaryKey", "-o", "tsv"]

    result = subprocess.run(
        cmd, capture_output=True, text=True, check=True, shell=os.name == "nt"
    )
    return result.stdout.strip()


def build_client(path: str, auth: str, outputs: dict) -> AnthropicFoundry:
    if path == "direct":
        base_url = os.environ.get("ANTHROPIC_FOUNDRY_BASE_URL") or outputs.get(
            "foundryAnthropicBaseUrl"
        )
    else:
        base_url = os.environ.get("ANTHROPIC_FOUNDRY_BASE_URL") or outputs.get(
            "gatewayAnthropicBaseUrl"
        )

    if not base_url:
        sys.exit(
            f"No base URL for path '{path}'. Run scripts/deploy.ps1 or set "
            "ANTHROPIC_FOUNDRY_BASE_URL."
        )

    if auth == "entra":
        # Works identically for both paths: direct, Foundry validates the token;
        # via the gateway, API Management validates it first and then either
        # forwards it or swaps it for its own managed identity token.
        return AnthropicFoundry(
            base_url=base_url,
            azure_ad_token_provider=entra_token_provider(),
        )

    key = resolve_api_key(path, outputs)
    # For the gateway this is the API Management subscription key; the API is
    # configured to accept it on the same 'api-key' header Foundry uses, so the
    # client code is byte-for-byte identical across both paths.
    return AnthropicFoundry(base_url=base_url, api_key=key)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path", choices=["direct", "gateway"], default="direct")
    parser.add_argument("--auth", choices=["entra", "key"], default="entra")
    parser.add_argument("--model", help="Foundry DEPLOYMENT name (not the model ID)")
    parser.add_argument("--stream", action="store_true", help="Stream the response")
    parser.add_argument(
        "--prompt",
        default="In one sentence, confirm you are Claude served from Microsoft Foundry.",
    )
    args = parser.parse_args()

    outputs = load_outputs()
    model = (
        args.model
        or os.environ.get("ANTHROPIC_DEFAULT_SONNET_MODEL")
        or outputs.get("sonnetDeploymentName")
        or outputs.get("haikuDeploymentName")
    )
    if not model:
        sys.exit("No model deployment found. Pass --model <deployment-name>.")

    client = build_client(args.path, args.auth, outputs)

    print(f"path={args.path}  auth={args.auth}  model={model}")
    print(f"base_url={client.base_url}\n")

    if args.stream:
        with client.messages.stream(
            model=model,
            max_tokens=512,
            messages=[{"role": "user", "content": args.prompt}],
        ) as stream:
            for text in stream.text_stream:
                print(text, end="", flush=True)
            print("\n")
            usage = stream.get_final_message().usage
    else:
        message = client.messages.create(
            model=model,
            max_tokens=512,
            messages=[{"role": "user", "content": args.prompt}],
        )
        print("".join(b.text for b in message.content if b.type == "text"), "\n")
        usage = message.usage

    print(f"input_tokens={usage.input_tokens}  output_tokens={usage.output_tokens}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

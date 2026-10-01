#!/usr/bin/env bash
# ==============================================================================
# `cleanup_resources.sh` — Step-by-Step Reverse-Dependency Deletion Script
#
# Deletes Agent Gateway resources in the EXACT required reverse-dependency order:
#   Step 1: Unbind or Delete ReasoningEngine Agents (if `--include-agents` is passed)
#   Step 2: Delete Network Security AuthzPolicies FIRST (both UI-named & CLI-named)
#   Step 3: Delete Network Services AuthzExtensions (Service Extensions)
#   Step 4: Delete Agent Gateways (`agw-study-ingress`, `agw-study-egress`)
#   Step 5: Delete Model Armor Template & IAM Unified Access Policy (UAP) Binding/Policy
#   Step 6: Delete Custom Agent Registry Services (`check-gcp-subnet-ips-agw`, `core-gapi-services`)
#
# Usage:
#   # Delete only the AuthzPolicies & Service Extensions so you can delete the Gateways from the UI:
#   ./cleanup_resources.sh --policies-only
#
#   # Delete all Agent Gateway, AuthzPolicy, Service Extension, Model Armor, UAP, and Registry resources:
#   ./cleanup_resources.sh
#
#   # Delete EVERYTHING including the deployed ReasoningEngine Agents and Cloud Run service:
#   ./cleanup_resources.sh --include-agents
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/cfg/env.sh"

MODE="${1:-all}"

echo "=============================================================================="
echo "Cleaning up Agent Gateway resources in PROJECT_ID=${PROJECT_ID} (REGION=${REGION})"
echo "Mode: ${MODE}"
echo "=============================================================================="

if [[ "${MODE}" == "--include-agents" ]]; then
  echo ""
  echo ">>> [Step 1/6] Deleting ReasoningEngine Agents (${REGION}) & Cloud Run Service (${CLOUD_RUN_REGION})..."
  if [[ -n "${SUBNET_ENGINE_ID:-}" ]]; then
    gcloud alpha ai reasoning-engines delete "${SUBNET_ENGINE_ID}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet || true
  fi
  if [[ -n "${NETWORK_ENGINE_ID:-}" ]]; then
    gcloud alpha ai reasoning-engines delete "${NETWORK_ENGINE_ID}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet || true
  fi
  gcloud run services delete network-agent-agw \
    --region="${CLOUD_RUN_REGION}" --project="${PROJECT_ID}" --quiet || true
else
  echo ""
  echo ">>> [Step 1/6] Skipping ReasoningEngine & Cloud Run deletion (pass --include-agents to delete them)."
  echo "    Unbinding Ingress Agent Gateway from check-gcp-subnet-ips-agw (${SUBNET_ENGINE_ID}) so Gateway can be deleted..."
  TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
  if [[ -n "${TOKEN}" && -n "${SUBNET_ENGINE_ID:-}" ]]; then
    curl -s -X PATCH \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${SUBNET_ENGINE_ID}?updateMask=spec.deploymentSpec.agentGatewayConfig" \
      -d '{"spec":{"identityType":"AGENT_IDENTITY","deploymentSpec":{"agentGatewayConfig":{}}}}' >/dev/null || true
  fi
fi

echo ""
echo ">>> [Step 2/6] Deleting Network Security AuthzPolicies (MUST be deleted BEFORE Gateways & Service Extensions!)..."
for POLICY in \
  "${AGW_INGRESS_POLICY_NAME}" \
  "${AGW_INGRESS_NAME}-aisecurity-authzpolicy" \
  "${AGW_INGRESS_NAME}-authz-policy-modar" \
  "${AGW_EGRESS_POLICY_NAME}" \
  "${AGW_EGRESS_NAME}-iap-authzpolicy" \
  "${AGW_EGRESS_NAME}-authz-policy-iap"; do
  gcloud beta network-security authz-policies delete "${POLICY}" \
    --location="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true
done

echo ""
echo ">>> [Step 3/6] Deleting Service Extensions (AuthzExtensions)..."
for EXT in \
  "${AGW_INGRESS_EXT_NAME}" \
  "${AGW_INGRESS_NAME}-aisecurity-authzextension" \
  "${AGW_INGRESS_NAME}-svc-ext-modar" \
  "${AGW_EGRESS_EXT_NAME}" \
  "${AGW_EGRESS_NAME}-iap-authzextension" \
  "${AGW_EGRESS_NAME}-svc-ext-iap"; do
  gcloud beta service-extensions authz-extensions delete "${EXT}" \
    --location="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true
done

if [[ "${MODE}" == "--policies-only" ]]; then
  echo ""
  echo "DONE (--policies-only): AuthzPolicies and Service Extensions have been removed!"
  echo "You can now refresh the Google Cloud Console UI (Agent Platform -> Govern -> Gateways)"
  echo "and click the 'Delete' button on ${AGW_INGRESS_NAME} and ${AGW_EGRESS_NAME}."
  exit 0
fi

echo ""
echo ">>> [Step 4/6] Deleting Agent Gateways (${AGW_INGRESS_NAME}, ${AGW_EGRESS_NAME})..."
gcloud alpha network-services agent-gateways delete "${AGW_INGRESS_NAME}" \
  --location="${REGION}" --project="${PROJECT_ID}" --quiet || true
gcloud alpha network-services agent-gateways delete "${AGW_EGRESS_NAME}" \
  --location="${REGION}" --project="${PROJECT_ID}" --quiet || true

echo ""
echo ">>> [Step 5/6] Deleting Model Armor Template & IAM Unified Access Policy (UAP) Binding/Policy..."
gcloud model-armor templates delete "${MODEL_ARMOR_TEMPLATE_ID}" \
  --location="${REGION}" --project="${PROJECT_ID}" --quiet || true
gcloud iam policy-bindings delete "${UAP_BINDING_NAME}" \
  --location=global --project="${PROJECT_ID}" --quiet || true
gcloud iam access-policies delete "${UAP_POLICY_NAME}" \
  --location=global --project="${PROJECT_ID}" --quiet || true

echo ""
echo ">>> [Step 6/6] Deleting Custom Agent Registry Services (check-gcp-subnet-ips-agw, core-gapi-services)..."
gcloud alpha agent-registry services delete check-gcp-subnet-ips-agw \
  --location="${REGION}" --project="${PROJECT_ID}" --quiet || true
gcloud alpha agent-registry services delete core-gapi-services \
  --location="${REGION}" --project="${PROJECT_ID}" --quiet || true

echo ""
echo "=============================================================================="
echo "Cleanup complete!"
echo "=============================================================================="

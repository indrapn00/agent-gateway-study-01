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
  TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
  if [[ -n "${TOKEN}" ]]; then
    for ENGINE_ID in "${SUBNET_ENGINE_ID:-}" "${NETWORK_ENGINE_ID:-}"; do
      if [[ -n "${ENGINE_ID}" ]]; then
        echo "    Deleting reasoningEngine/${ENGINE_ID}..."
        curl -s -X DELETE \
          -H "Authorization: Bearer ${TOKEN}" \
          "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${ENGINE_ID}?force=true" >/dev/null || true
      fi
    done
  fi
  gcloud run services delete network-agent-agw \
    --region="${CLOUD_RUN_REGION}" --project="${PROJECT_ID}" --quiet || true
else
  echo ""
  echo ">>> [Step 1/6] Unbinding Agent Gateways from ReasoningEngine Agents (${SUBNET_ENGINE_ID}, ${NETWORK_ENGINE_ID}) so Gateways can be deleted without deleting the Agents..."
  TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
  if [[ -n "${TOKEN}" ]]; then
    for ENGINE_ID in "${SUBNET_ENGINE_ID:-}" "${NETWORK_ENGINE_ID:-}"; do
      if [[ -n "${ENGINE_ID}" ]]; then
        HasGW=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
          "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${ENGINE_ID}" \
          | python3 -c "import sys, json; d=json.load(sys.stdin); cfg=d.get('spec',{}).get('deploymentSpec',{}).get('agentGatewayConfig',{}); print('yes' if cfg else 'no')" 2>/dev/null || echo "no")
        if [[ "${HasGW}" == "yes" ]]; then
          echo "    Unbinding AgentGatewayConfig from reasoningEngine/${ENGINE_ID}..."
          OP_JSON=$(curl -s -X PATCH \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${ENGINE_ID}?updateMask=spec.deployment_spec.agent_gateway_config" \
            -d '{"spec":{"deploymentSpec":{"agentGatewayConfig":{}}}}')
          OP_NAME=$(echo "${OP_JSON}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('name', ''))" 2>/dev/null || true)
          if [[ -n "${OP_NAME}" ]]; then
            echo "    Waiting for unbind operation (${OP_NAME}) to complete..."
            for _ in {1..40}; do
              DONE=$(curl -s -H "Authorization: Bearer ${TOKEN}" "https://${REGION}-aiplatform.googleapis.com/v1beta1/${OP_NAME}" \
                | python3 -c "import sys, json; print(json.load(sys.stdin).get('done', False))" 2>/dev/null || echo "False")
              [[ "${DONE}" == "True" ]] && break
              sleep 5
            done
          fi
        fi
      fi
    done
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
  echo "DONE (--policies-only): ReasoningEngines unbound, and AuthzPolicies + Service Extensions removed!"
  echo "You can now refresh the Google Cloud Console UI (Agent Platform -> Agents -> Gateways)"
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

#!/usr/bin/env bash
# ==============================================================================
# `cleanup_resources.sh` — Complete Reverse-Dependency Deletion Script
#
# Deletes ALL Agent Gateway Study lab resources in the exact required order:
#   Step 1: Unbind & Delete ReasoningEngine Agents (`check-gcp-subnet-ips-agw`,
#           `network-agent-agw` in `${REGION}`) + Cloud Run (`network-agent-agw`
#           in `${CLOUD_RUN_REGION}`).
#           (Pass `--keep-agents` or `--policies-only` to only unbind without deleting agents.)
#   Step 2: Delete Network Security AuthzPolicies FIRST (both UI-named & CLI-named)
#   Step 3: Delete Network Services AuthzExtensions (Service Extensions)
#   Step 4: Delete Agent Gateways (`agw-study-ingress`, `agw-study-egress`)
#   Step 5: Delete Model Armor Template (via regional REP endpoint) & IAM UAP Binding/Policy
#   Step 6: Delete Custom Agent Registry Services (`check-gcp-subnet-ips-agw`, `core-gapi-services`)
#
# Usage:
#   # [DEFAULT] Delete EVERYTHING (Agents, Cloud Run, AuthzPolicies, Extensions,
#   # Gateways, Model Armor Template, UAP Policy/Binding, and Agent Registry Services):
#   ./cleanup_resources.sh
#
#   # Keep the 3 deployed Agents running, but delete Gateways, Policies, Model Armor, UAP, and Registry:
#   ./cleanup_resources.sh --keep-agents
#
#   # Unbind Agents and delete only AuthzPolicies & Service Extensions so you can
#   # click "Delete" on the Gateways from the Google Cloud Console UI:
#   ./cleanup_resources.sh --policies-only
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/cfg/env.sh"

MODE="${1:---all}"

echo "=============================================================================="
echo "Cleaning up Agent Gateway Study resources in PROJECT_ID=${PROJECT_ID}"
echo "  Agent/Gateway Region : ${REGION}"
echo "  Cloud Run Region     : ${CLOUD_RUN_REGION}"
echo "  Cleanup Mode         : ${MODE}"
echo "=============================================================================="

TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)

# Discover ALL live ReasoningEngine IDs for `check-gcp-subnet-ips-agw` and `network-agent-agw`
# in ${REGION} (in addition to SUBNET_ENGINE_ID and NETWORK_ENGINE_ID from cfg/env.sh)
DISCOVERED_ENGINES=""
if [[ -n "${TOKEN}" ]]; then
  DISCOVERED_ENGINES=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines" \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    ids = []
    for r in d.get('reasoningEngines', []):
        if r.get('displayName') in ('check-gcp-subnet-ips-agw', 'network-agent-agw'):
            ids.append(r.get('name', '').split('/')[-1])
    print(' '.join(ids))
except Exception:
    pass
" 2>/dev/null || true)
fi

ALL_ENGINE_IDS=$(echo "${DISCOVERED_ENGINES} ${SUBNET_ENGINE_ID:-} ${NETWORK_ENGINE_ID:-}" | tr ' ' '\n' | awk 'NF && !seen[$0]++')

echo ""
echo ">>> [Step 1/6] Unbinding Agent Gateways from ReasoningEngine Agents in ${REGION}..."
if [[ -n "${TOKEN}" && -n "${ALL_ENGINE_IDS}" ]]; then
  for ENGINE_ID in ${ALL_ENGINE_IDS}; do
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
  done
fi

if [[ "${MODE}" != "--keep-agents" && "${MODE}" != "--policies-only" ]]; then
  echo ""
  echo ">>> [Step 1b/6] Deleting ReasoningEngine Agents (${REGION}) & Cloud Run Service (${CLOUD_RUN_REGION})..."
  if [[ -n "${TOKEN}" && -n "${ALL_ENGINE_IDS}" ]]; then
    for ENGINE_ID in ${ALL_ENGINE_IDS}; do
      EXISTS=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
        "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${ENGINE_ID}" \
        | python3 -c "import sys, json; d=json.load(sys.stdin); print('yes' if 'name' in d else 'no')" 2>/dev/null || echo "no")
      if [[ "${EXISTS}" == "yes" ]]; then
        echo "    Deleting reasoningEngine/${ENGINE_ID} in ${REGION}..."
        DEL_JSON=$(curl -s -X DELETE \
          -H "Authorization: Bearer ${TOKEN}" \
          "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${ENGINE_ID}?force=true")
        DEL_OP=$(echo "${DEL_JSON}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('name', ''))" 2>/dev/null || true)
        if [[ -n "${DEL_OP}" ]]; then
          echo "    Waiting for reasoningEngine/${ENGINE_ID} deletion (${DEL_OP}) to complete..."
          for _ in {1..40}; do
            DONE=$(curl -s -H "Authorization: Bearer ${TOKEN}" "https://${REGION}-aiplatform.googleapis.com/v1beta1/${DEL_OP}" \
              | python3 -c "import sys, json; print(json.load(sys.stdin).get('done', False))" 2>/dev/null || echo "False")
            [[ "${DONE}" == "True" ]] && break
            sleep 3
          done
        fi
      fi
    done
  fi
  echo "    Deleting Cloud Run service network-agent-agw in ${CLOUD_RUN_REGION}..."
  gcloud run services delete network-agent-agw \
    --region="${CLOUD_RUN_REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true
  if [[ "${REGION}" != "${CLOUD_RUN_REGION}" ]]; then
    gcloud run services delete network-agent-agw \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true
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
echo ">>> [Step 5/6] Deleting Model Armor Template (${MODEL_ARMOR_TEMPLATE_ID} in ${REGION}) & IAM Unified Access Policy (UAP)..."
if [[ -n "${TOKEN}" ]]; then
  curl -s -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" \
    "https://modelarmor.${REGION}.rep.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/templates/${MODEL_ARMOR_TEMPLATE_ID}" >/dev/null || true
fi
CLOUDSDK_API_ENDPOINT_OVERRIDES_MODELARMOR="https://modelarmor.${REGION}.rep.googleapis.com/" \
  gcloud model-armor templates delete "${MODEL_ARMOR_TEMPLATE_ID}" \
  --location="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true

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

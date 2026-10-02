#!/usr/bin/env bash
# ==============================================================================
# `render_configs.sh` — Renders all Agent Gateway YAML & JSON files in `cfg/`
# from the central variable definitions in `cfg/env.sh`.
#
# Usage:
#   1. Edit `cfg/env.sh` (or export variables like PROJECT_ID, SUBNET_ENGINE_ID)
#      and run:
#        ./render_configs.sh
#
#   2. Or auto-discover Project Number, Org ID, ReasoningEngine IDs, and
#      Agent Registry UUIDs directly from your active GCP project via `gcloud`:
#        ./render_configs.sh --auto-discover
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/cfg/env.sh"

if [[ "${1:-}" == "--auto-discover" ]]; then
  echo "Auto-discovering variables for PROJECT_ID=${PROJECT_ID} in REGION=${REGION}..."
  DISCOVERED_PROJ_NO=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)" 2>/dev/null || true)
  [[ -n "${DISCOVERED_PROJ_NO}" ]] && export PROJECT_NUMBER="${DISCOVERED_PROJ_NO}"

  DISCOVERED_ORG_ID=$(gcloud projects get-ancestors "${PROJECT_ID}" --format="value(id)" 2>/dev/null | tail -n 1 || true)
  [[ -n "${DISCOVERED_ORG_ID}" ]] && export ORG_ID="${DISCOVERED_ORG_ID}"

  # Discover ReasoningEngine IDs via Vertex AI REST API (sorted newest-first by createTime)
  TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
  if [[ -n "${TOKEN}" ]]; then
    RE_JSON=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
      "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines" 2>/dev/null || echo "{}")

    DISCOVERED_SUBNET_ID=$(echo "${RE_JSON}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
engines = [e for e in data.get('reasoningEngines', []) if e.get('displayName') == 'check-gcp-subnet-ips-agw']
engines.sort(key=lambda e: e.get('createTime', ''), reverse=True)
if engines:
    print(engines[0]['name'].split('/')[-1])
" 2>/dev/null || true)
    [[ -n "${DISCOVERED_SUBNET_ID}" ]] && export SUBNET_ENGINE_ID="${DISCOVERED_SUBNET_ID}"

    DISCOVERED_NET_ID=$(echo "${RE_JSON}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
engines = [e for e in data.get('reasoningEngines', []) if e.get('displayName') == 'network-agent-agw']
engines.sort(key=lambda e: e.get('createTime', ''), reverse=True)
if engines:
    print(engines[0]['name'].split('/')[-1])
" 2>/dev/null || true)
    [[ -n "${DISCOVERED_NET_ID}" ]] && export NETWORK_ENGINE_ID="${DISCOVERED_NET_ID}"
  fi

  DISCOVERED_CORE_EP=$(gcloud alpha agent-registry services describe core-gapi-services \
    --location="${REGION}" --project="${PROJECT_ID}" --format="value(registryResource)" 2>/dev/null | awk -F'/' '{print $NF}' || true)
  [[ -n "${DISCOVERED_CORE_EP}" ]] && export CORE_GAPI_ENDPOINT_ID="${DISCOVERED_CORE_EP}"

  DISCOVERED_AUTO_REG=$(gcloud alpha agent-registry agents list \
    --location="${REGION}" --project="${PROJECT_ID}" --filter="displayName=check-gcp-subnet-ips-agw AND agentId:reasoningEngines" \
    --format="value(name)" 2>/dev/null | head -n 1 | awk -F'/' '{print $NF}' || true)
  [[ -n "${DISCOVERED_AUTO_REG}" ]] && export SUBNET_AGENT_AUTO_REG_ID="${DISCOVERED_AUTO_REG}"

  DISCOVERED_NET_AUTO_REG=$(gcloud alpha agent-registry agents list \
    --location="${REGION}" --project="${PROJECT_ID}" --filter="displayName=network-agent-agw" \
    --format="value(name)" 2>/dev/null | head -n 1 | awk -F'/' '{print $NF}' || true)

  DISCOVERED_CUSTOM_REG=$(gcloud alpha agent-registry services describe check-gcp-subnet-ips-agw \
    --location="${REGION}" --project="${PROJECT_ID}" --format="value(registryResource)" 2>/dev/null | awk -F'/' '{print $NF}' || true)
  if [[ -n "${DISCOVERED_CUSTOM_REG}" ]]; then
    export SUBNET_AGENT_CUSTOM_REG_ID="${DISCOVERED_CUSTOM_REG}"
  elif [[ -n "${DISCOVERED_AUTO_REG}" ]]; then
    # Before Step 3b (custom service creation) is run in a new region, default to SUBNET_AGENT_AUTO_REG_ID
    # so it never shows a stale UUID from a previous region!
    export SUBNET_AGENT_CUSTOM_REG_ID="${DISCOVERED_AUTO_REG}"
  fi

  # Persist discovered values back into cfg/env.sh so subsequent `source cfg/env.sh` loads them!
  python3 - "${SCRIPT_DIR}/cfg/env.sh" << PYEOF
import re, sys, os
env_path = sys.argv[1]
with open(env_path, "r") as f:
    content = f.read()

updates = {
    "PROJECT_NUMBER": os.environ.get("PROJECT_NUMBER", ""),
    "ORG_ID": os.environ.get("ORG_ID", ""),
    "SUBNET_ENGINE_ID": os.environ.get("SUBNET_ENGINE_ID", ""),
    "NETWORK_ENGINE_ID": os.environ.get("NETWORK_ENGINE_ID", ""),
    "CORE_GAPI_ENDPOINT_ID": os.environ.get("CORE_GAPI_ENDPOINT_ID", ""),
    "SUBNET_AGENT_AUTO_REG_ID": os.environ.get("SUBNET_AGENT_AUTO_REG_ID", ""),
    "SUBNET_AGENT_CUSTOM_REG_ID": os.environ.get("SUBNET_AGENT_CUSTOM_REG_ID", ""),
}

for k, v in updates.items():
    if v:
        content = re.sub(
            rf'^export {k}=.*$',
            f'export {k}="{v}"',
            content,
            flags=re.MULTILINE,
        )

with open(env_path, "w") as f:
    f.write(content)
PYEOF
  echo "Updated cfg/env.sh in-place with auto-discovered IDs."
fi

echo "=============================================================================="
echo "Rendering cfg/ files with the following values:"
echo "  PROJECT_ID                 = ${PROJECT_ID}"
echo "  PROJECT_NUMBER             = ${PROJECT_NUMBER}"
echo "  ORG_ID                     = ${ORG_ID}"
echo "  REGION                     = ${REGION}"
echo "  CLOUD_RUN_REGION           = ${CLOUD_RUN_REGION}"
echo "  ----------------------------------------------------------------------------"
echo "  [Target Specialist Agent: check-gcp-subnet-ips-agw (Destination in UAP Rule 2)]"
echo "  SUBNET_ENGINE_ID           = ${SUBNET_ENGINE_ID}"
echo "  SUBNET_AGENT_AUTO_REG_ID   = ${SUBNET_AGENT_AUTO_REG_ID} (auto-registered in Step 1a)"
echo "  SUBNET_AGENT_CUSTOM_REG_ID = ${SUBNET_AGENT_CUSTOM_REG_ID} (custom service registered in Step 3b)"
echo "  ----------------------------------------------------------------------------"
echo "  [Caller Orchestrator Agent: network-agent-agw (Source SPIFFE Principal in UAP Rule 2)]"
echo "  NETWORK_ENGINE_ID          = ${NETWORK_ENGINE_ID} (used in SPIFFE ID principal)"
if [[ -n "${DISCOVERED_NET_AUTO_REG:-}" ]]; then
  echo "  (Info) network-agent-agw Registry UUID = ${DISCOVERED_NET_AUTO_REG} (not used in UAP rules; caller uses SPIFFE ID)"
fi
echo "  ----------------------------------------------------------------------------"
echo "  [Core Google APIs Endpoint (Destination in UAP Rule 1 - registered in Step 3b)]"
echo "  CORE_GAPI_ENDPOINT_ID      = ${CORE_GAPI_ENDPOINT_ID}"
echo "=============================================================================="

# 1. cfg/agw-study-egress.yaml
cat > "${SCRIPT_DIR}/cfg/agw-study-egress.yaml" << EOF
# ==============================================================================
# Egress Agent Gateway Definition (AGENT_TO_ANYWHERE)
# Generated from \`cfg/env.sh\` via \`./render_configs.sh\`
#
# VARIABLES TO CHANGE WHEN RE-DEPLOYING TO A NEW PROJECT / REGION:
#   1. \`name\`: Egress Agent Gateway name (\`AGW_EGRESS_NAME\`).
#      - Example: "agw-study-egress"
#   2. \`registries\`: Replace PROJECT_ID ("${PROJECT_ID}") and REGION ("${REGION}")
#      with your target GCP Project ID and Agent Gateway Region.
#      - Example regional registry: "//agentregistry.googleapis.com/projects/gcp-demo-02-307713/locations/us-central1"
#      - Example global registry:   "//agentregistry.googleapis.com/projects/gcp-demo-02-307713/locations/global"
# ==============================================================================
name: ${AGW_EGRESS_NAME}
protocols:
- MCP
googleManaged:
  governedAccessPath: AGENT_TO_ANYWHERE
registries:
- "//agentregistry.googleapis.com/projects/${PROJECT_ID}/locations/${REGION}"
- "//agentregistry.googleapis.com/projects/${PROJECT_ID}/locations/global"
EOF

# 2. cfg/agw-study-egress-svc-ext-iap.yaml
cat > "${SCRIPT_DIR}/cfg/agw-study-egress-svc-ext-iap.yaml" << EOF
# ==============================================================================
# Egress IAP v2 AuthzExtension Definition
# Generated from \`cfg/env.sh\` via \`./render_configs.sh\`
#
# VARIABLES TO CHANGE WHEN RE-DEPLOYING:
#   1. \`name\`: AuthzExtension resource name (\`AGW_EGRESS_EXT_NAME\`).
#      - Example: "agw-study-egress-iap-authzextension"
#   Note: \`service: iap.googleapis.com\` is global and does NOT change across regions/projects.
# ==============================================================================
name: ${AGW_EGRESS_EXT_NAME}
service: iap.googleapis.com
failOpen: false
timeout: 1s
metadata:
  iapPolicyVersion: "V2"
EOF

# 3. cfg/agw-study-egress-authz-policy-iap.yaml
cat > "${SCRIPT_DIR}/cfg/agw-study-egress-authz-policy-iap.yaml" << EOF
# ==============================================================================
# Egress Request AuthzPolicy (Binds IAP v2 AuthzExtension to Egress Gateway)
# Generated from \`cfg/env.sh\` via \`./render_configs.sh\`
#
# VARIABLES TO CHANGE WHEN RE-DEPLOYING TO A NEW PROJECT / REGION:
#   1. \`target.resources[0]\`: Replace PROJECT_ID ("${PROJECT_ID}"), REGION ("${REGION}"),
#      and AGW_EGRESS_NAME ("${AGW_EGRESS_NAME}").
#      - Example: "projects/gcp-demo-02-307713/locations/us-central1/agentGateways/agw-study-egress"
#   2. \`customProvider.authzExtension.resources[0]\`: Replace PROJECT_ID ("${PROJECT_ID}"),
#      REGION ("${REGION}"), and AGW_EGRESS_EXT_NAME ("${AGW_EGRESS_EXT_NAME}").
#      - Example: "projects/gcp-demo-02-307713/locations/us-central1/authzExtensions/agw-study-egress-iap-authzextension"
# ==============================================================================
name: ${AGW_EGRESS_POLICY_NAME}
target:
  resources:
  - "projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${AGW_EGRESS_NAME}"
policyProfile: REQUEST_AUTHZ
action: CUSTOM
customProvider:
  authzExtension:
    resources:
    - "projects/${PROJECT_ID}/locations/${REGION}/authzExtensions/${AGW_EGRESS_EXT_NAME}"
EOF

# 4. cfg/agw-study-ingress.yaml
cat > "${SCRIPT_DIR}/cfg/agw-study-ingress.yaml" << EOF
# ==============================================================================
# Ingress Agent Gateway Definition (CLIENT_TO_AGENT)
# Generated from \`cfg/env.sh\` via \`./render_configs.sh\`
#
# VARIABLES TO CHANGE WHEN RE-DEPLOYING:
#   1. \`name\`: Ingress Agent Gateway name (\`AGW_INGRESS_NAME\`).
#      - Example: "agw-study-ingress"
#   Note: No Project ID or Region is hardcoded inside this file (you pass
#   \`--location=\${REGION} --project=\${PROJECT_ID}\` on the \`gcloud\` CLI).
# ==============================================================================
name: ${AGW_INGRESS_NAME}
protocols:
- MCP
googleManaged:
  governedAccessPath: CLIENT_TO_AGENT
EOF

# 5. cfg/agw-study-ingress-svc-ext-modar.yaml
cat > "${SCRIPT_DIR}/cfg/agw-study-ingress-svc-ext-modar.yaml" << EOF
# ==============================================================================
# Ingress Model Armor AuthzExtension Definition
# Generated from \`cfg/env.sh\` via \`./render_configs.sh\`
#
# VARIABLES TO CHANGE WHEN RE-DEPLOYING TO A NEW PROJECT / REGION:
#   1. \`service\` (HIDDEN REGIONAL HOSTNAME!): Model Armor uses a Regional Endpoint
#      (REP) hostname: \`modelarmor.<REGION>.rep.googleapis.com\`.
#      - Example (us-central1):     "modelarmor.us-central1.rep.googleapis.com"
#      - Example (asia-southeast1): "modelarmor.asia-southeast1.rep.googleapis.com"
#   2. \`request_template_id\` & \`response_template_id\`: Replace PROJECT_ID ("${PROJECT_ID}"),
#      REGION ("${REGION}"), and MODEL_ARMOR_TEMPLATE_ID ("${MODEL_ARMOR_TEMPLATE_ID}").
#      - Example: "projects/gcp-demo-02-307713/locations/us-central1/templates/agw-study-ingress-modar-req-template"
#   3. IAM Requirement in New Project: Grant \`roles/modelarmor.user\` to your project's
#      Service Extensions P4SA: \`service-<PROJECT_NUMBER>@gcp-sa-dep.iam.gserviceaccount.com\`.
# ==============================================================================
name: ${AGW_INGRESS_EXT_NAME}
service: modelarmor.${REGION}.rep.googleapis.com
forwardHeaders:
- authorization
metadata:
  model_armor_settings: '[
    {
      "request_template_id": "projects/${PROJECT_ID}/locations/${REGION}/templates/${MODEL_ARMOR_TEMPLATE_ID}",
      "response_template_id": "projects/${PROJECT_ID}/locations/${REGION}/templates/${MODEL_ARMOR_TEMPLATE_ID}"
    }
  ]'
failOpen: false
timeout: 5s
EOF

# 6. cfg/agw-study-ingress-authz-policy-modar.yaml
cat > "${SCRIPT_DIR}/cfg/agw-study-ingress-authz-policy-modar.yaml" << EOF
# ==============================================================================
# Ingress Content AuthzPolicy (Binds Model Armor Extension to Ingress Gateway)
# Generated from \`cfg/env.sh\` via \`./render_configs.sh\`
#
# VARIABLES TO CHANGE WHEN RE-DEPLOYING TO A NEW PROJECT / REGION:
#   1. \`target.resources[0]\`: Replace PROJECT_ID ("${PROJECT_ID}"), REGION ("${REGION}"),
#      and AGW_INGRESS_NAME ("${AGW_INGRESS_NAME}").
#      - Example: "projects/gcp-demo-02-307713/locations/us-central1/agentGateways/agw-study-ingress"
#   2. \`customProvider.authzExtension.resources[0]\`: Replace PROJECT_ID ("${PROJECT_ID}"),
#      REGION ("${REGION}"), and AGW_INGRESS_EXT_NAME ("${AGW_INGRESS_EXT_NAME}").
#      - Example: "projects/gcp-demo-02-307713/locations/us-central1/authzExtensions/agw-study-ingress-aisecurity-authzextension"
# ==============================================================================
name: ${AGW_INGRESS_POLICY_NAME}
target:
  resources:
  - "projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${AGW_INGRESS_NAME}"
policyProfile: CONTENT_AUTHZ
action: CUSTOM
customProvider:
  authzExtension:
    resources:
    - "projects/${PROJECT_ID}/locations/${REGION}/authzExtensions/${AGW_INGRESS_EXT_NAME}"
EOF

# 7. cfg/uap-rules.json (Rule 1 only: Default Deny for sub-agent calls)
# Note: IAM v3 AccessPolicies enforces a strict <= 256 character limit on each rule's "description" field!
cat > "${SCRIPT_DIR}/cfg/uap-rules.json" << EOF
[
  {
    "description": "Rule 1: Allow Agent Platform runtimes in project ${PROJECT_NUMBER} to reach Core Google APIs (${CORE_GAPI_ENDPOINT_ID})",
    "effect": "ALLOW",
    "principals": [
      "principalSet://agents.global.org-${ORG_ID}.system.id.goog/attribute.platformContainer/aiplatform/projects/${PROJECT_NUMBER}"
    ],
    "operation": {
      "permissions": [
        "iap.googleapis.com/resources.egressViaIAP"
      ]
    },
    "conditions": {
      "iap.googleapis.com": {
        "expression": "destination.is_registered == true && destination.agent_registry.resource_type == 'ENDPOINT' && (destination.agent_registry.endpoint.name == 'projects/${PROJECT_ID}/locations/${REGION}/endpoints/core-gapi-services' || destination.agent_registry.endpoint.name == 'projects/${PROJECT_ID}/locations/${REGION}/endpoints/${CORE_GAPI_ENDPOINT_ID}' || destination.agent_registry.endpoint.name == 'projects/${PROJECT_NUMBER}/locations/${REGION}/endpoints/${CORE_GAPI_ENDPOINT_ID}')"
      }
    }
  }
]
EOF

# 8. cfg/uap-rules-allow-subnet.json (Rule 1 + Rule 2: Explicit Allow for network-agent-agw SPIFFE ID)
# Note: IAM v3 AccessPolicies enforces a strict <= 256 character limit on each rule's "description" field!
cat > "${SCRIPT_DIR}/cfg/uap-rules-allow-subnet.json" << EOF
[
  {
    "description": "Rule 1: Allow Agent Platform runtimes in project ${PROJECT_NUMBER} to reach Core Google APIs (${CORE_GAPI_ENDPOINT_ID})",
    "effect": "ALLOW",
    "principals": [
      "principalSet://agents.global.org-${ORG_ID}.system.id.goog/attribute.platformContainer/aiplatform/projects/${PROJECT_NUMBER}"
    ],
    "operation": {
      "permissions": [
        "iap.googleapis.com/resources.egressViaIAP"
      ]
    },
    "conditions": {
      "iap.googleapis.com": {
        "expression": "destination.is_registered == true && destination.agent_registry.resource_type == 'ENDPOINT' && (destination.agent_registry.endpoint.name == 'projects/${PROJECT_ID}/locations/${REGION}/endpoints/core-gapi-services' || destination.agent_registry.endpoint.name == 'projects/${PROJECT_ID}/locations/${REGION}/endpoints/${CORE_GAPI_ENDPOINT_ID}' || destination.agent_registry.endpoint.name == 'projects/${PROJECT_NUMBER}/locations/${REGION}/endpoints/${CORE_GAPI_ENDPOINT_ID}')"
      }
    }
  },
  {
    "description": "Rule 2: Allow ONLY network-agent-agw (${NETWORK_ENGINE_ID}) SPIFFE ID to call check-gcp-subnet-ips-agw",
    "effect": "ALLOW",
    "principals": [
      "principal://agents.global.org-${ORG_ID}.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${NETWORK_ENGINE_ID}"
    ],
    "operation": {
      "permissions": [
        "iap.googleapis.com/resources.egressViaIAP"
      ]
    },
    "conditions": {
      "iap.googleapis.com": {
        "expression": "destination.is_registered == true && destination.agent_registry.resource_type == 'AGENT' && (destination.agent_registry.agent.name == 'projects/${PROJECT_ID}/locations/${REGION}/agents/check-gcp-subnet-ips-agw' || destination.agent_registry.agent.name == 'projects/${PROJECT_ID}/locations/${REGION}/agents/${SUBNET_AGENT_AUTO_REG_ID}' || destination.agent_registry.agent.name == 'projects/${PROJECT_NUMBER}/locations/${REGION}/agents/${SUBNET_AGENT_AUTO_REG_ID}' || destination.agent_registry.agent.name == 'projects/${PROJECT_ID}/locations/${REGION}/agents/${SUBNET_AGENT_CUSTOM_REG_ID}' || destination.agent_registry.agent.name == 'projects/${PROJECT_NUMBER}/locations/${REGION}/agents/${SUBNET_AGENT_CUSTOM_REG_ID}')"
      }
    }
  }
]
EOF

echo "Successfully rendered all 8 files in cfg/!"

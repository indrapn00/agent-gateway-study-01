#!/usr/bin/env bash
# ==============================================================================
# CENTRAL ENVIRONMENT CONFIGURATION FOR AGENT GATEWAY STUDY (`cfg/env.sh`)
# ==============================================================================
# When re-deploying to a DIFFERENT GCP Project, Organization, Region, or after
# deploying new Reasoning Engines (which get new random numeric IDs and new
# random Agent Registry UUIDs), update the variables below and run:
#
#   ./render_configs.sh
#
# Or run with `--auto-discover` to let `gcloud` automatically look up your
# Project Number, Organization ID, ReasoningEngine IDs, and Agent Registry UUIDs:
#
#   ./render_configs.sh --auto-discover
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. CORE GCP PROJECT, NUMBER & ORGANIZATION VARIABLES
# ------------------------------------------------------------------------------

# [CHANGE ME]: Your Google Cloud Project ID (string).
#   - Example: "gcp-demo-02-307713"
#   - How to check: gcloud config get-value project
export PROJECT_ID="gcp-demo-02-307713"

# [CHANGE ME]: Your numeric Google Cloud Project Number.
#   - Used in: ReasoningEngine resource paths, SPIFFE IDs, UAP rules, and P4SA IAM bindings.
#   - Example: "66063681189"
#   - How to find: gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)"
export PROJECT_NUMBER="66063681189"

# [CHANGE ME]: Your numeric Google Cloud Organization ID.
#   - Used in: SPIFFE Agent Identity URIs inside `cfg/uap-rules*.json`
#     (`principal://agents.global.org-${ORG_ID}.system.id.goog/...`).
#   - Example: "304553879287"
#   - How to find: gcloud projects get-ancestors "${PROJECT_ID}" --format="value(id)" | tail -n 1
export ORG_ID="304553879287"

# ------------------------------------------------------------------------------
# 2. REGION VARIABLES
# ------------------------------------------------------------------------------

# [CHANGE ME]: Region for Agent Gateway, Model Armor, Agent Registry, and Agent Platform.
#   - IMPORTANT: Must be a region that supports ALL 4 APIs: `ReasoningEngine`,
#     `agentGateways`, `modelarmor`, and `agentregistry`.
#   - Verified Supported Regions:
#       * "asia-southeast1" (Singapore - Recommended clean region if us-central1 hit BKI #16)
#       * "asia-northeast1" (Tokyo)
#       * "us-central1"     (Iowa - Default)
#       * "us-east1"        (South Carolina)
#       * "us-west1"        (Oregon)
#       * "europe-west1"    (Belgium)
#       * "europe-west4"    (Netherlands)
#     (Note: "asia-southeast2" is only used for CLOUD_RUN_REGION below.)
#   - After changing REGION below, run:
#       ./render_configs.sh && source cfg/env.sh
export REGION="asia-southeast1"

# [CHANGE ME]: Region for Cloud Run deployments (Mode 1 & Mode 3 Web UI).
#   - Can be in "asia-southeast2" even when Agent Gateway is in "us-central1" or "asia-southeast1".
#   - Example: "asia-southeast2"
export CLOUD_RUN_REGION="asia-southeast2"

# ------------------------------------------------------------------------------
# 3. AGENT PLATFORM REASONING ENGINE IDs (RANDOM NUMERIC IDs GENERATED AT DEPLOY TIME)
# ------------------------------------------------------------------------------

# [AUTO-UPDATED BY `./render_configs.sh --auto-discover` AFTER DEPLOYING `check_gcp_subnet_ips`]:
#   - The random numeric ReasoningEngine ID assigned when you deploy `check-gcp-subnet-ips-agw`
#     to Vertex AI Agent Engine (`deploy_agent.py --src-dir ./check_gcp_subnet_ips ...`).
#   - Example: "1020302260355203072"
#   - How to find automatically: ./render_configs.sh --auto-discover
export SUBNET_ENGINE_ID="4790607346592120832"

# [AUTO-UPDATED BY `./render_configs.sh --auto-discover` AFTER DEPLOYING `network_agent`]:
#   - The random numeric ReasoningEngine ID assigned when you deploy `network-agent-agw`
#     to Vertex AI Agent Engine (`deploy_agent.py --src-dir ./network_agent ...`).
#   - Used in: `cfg/uap-rules-allow-subnet.json` Rule 2 SPIFFE Principal:
#     `principal://agents.global.org-${ORG_ID}.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${NETWORK_ENGINE_ID}`
#   - Example: "1179054147220013056"
#   - How to find automatically: ./render_configs.sh --auto-discover
export NETWORK_ENGINE_ID="8958688801723514880"

# ------------------------------------------------------------------------------
# 4. AGENT REGISTRY AUTO-GENERATED UUIDs (HIDDEN STATIC VALUES IN UAP CEL RULES!)
# ------------------------------------------------------------------------------
# WHY THIS MATTERS:
# Whenever you register a service in Agent Registry or deploy a ReasoningEngine in a
# new project, Agent Registry generates a random UUID (`agentregistry-00000000-...`).
# IAP v2 evaluates `destination.agent_registry.endpoint.name` and `.agent.name` against
# these internal UUIDs in `cfg/uap-rules.json` and `cfg/uap-rules-allow-subnet.json`!

# [AUTO-UPDATED BY `./render_configs.sh --auto-discover` AFTER REGISTERING `core-gapi-services`]:
#   - The internal Endpoint ID generated for `core-gapi-services` in Agent Registry.
#   - Example: "agentregistry-00000000-0000-0000-444f-0dd5654527c5"
#   - How to find:
#       gcloud alpha agent-registry services describe core-gapi-services \
#         --location="${REGION}" --project="${PROJECT_ID}" \
#         --format="value(registryResource)" | awk -F'/' '{print $NF}'
export CORE_GAPI_ENDPOINT_ID="agentregistry-00000000-0000-0000-6fe9-88643c98b8ce"

# [AUTO-UPDATED BY `./render_configs.sh --auto-discover` AFTER DEPLOYING `check-gcp-subnet-ips-agw`]:
#   - The auto-discovered Agent ID created in Agent Registry when `check-gcp-subnet-ips-agw`
#     is deployed on Vertex AI Agent Engine.
#   - Example: "agentregistry-00000000-0000-0000-bf2d-ca1285f7103b"
#   - How to find:
#       gcloud alpha agent-registry agents list \
#         --location="${REGION}" --project="${PROJECT_ID}" \
#         --filter="displayName=check-gcp-subnet-ips-agw" \
#         --format="value(name)" | head -n 1 | awk -F'/' '{print $NF}'
export SUBNET_AGENT_AUTO_REG_ID="agentregistry-00000000-0000-0000-8826-0cf929f1d97b"

# [AUTO-UPDATED BY `./render_configs.sh --auto-discover` AFTER REGISTERING CUSTOM SERVICE `check-gcp-subnet-ips-agw`]:
#   - The internal Agent ID generated when registering the custom `.mtls.` service
#     `check-gcp-subnet-ips-agw` in Agent Registry (`gcloud alpha agent-registry services create`).
#   - Example: "agentregistry-00000000-0000-0000-f25b-29d92d70d0d5"
#   - How to find:
#       gcloud alpha agent-registry services describe check-gcp-subnet-ips-agw \
#         --location="${REGION}" --project="${PROJECT_ID}" \
#         --format="value(registryResource)" | awk -F'/' '{print $NF}'
export SUBNET_AGENT_CUSTOM_REG_ID="agentregistry-00000000-0000-0000-cdae-d115a97d6c0c"

# ------------------------------------------------------------------------------
# 5. RESOURCE NAMING VARIABLES (OPTIONAL — CAN KEEP DEFAULTS ACROSS PROJECTS)
# ------------------------------------------------------------------------------

# Egress Agent Gateway resource name (`AGENT_TO_ANYWHERE`)
#   - Example: "agw-study-egress"
export AGW_EGRESS_NAME="agw-study-egress"

# Egress IAP v2 AuthzExtension & AuthzPolicy names
#   - IMPORTANT UI COMPATIBILITY RULE:
#     The Google Cloud Console UI (`Agent Platform -> Agents -> Gateways`) ONLY
#     displays the "Access authorization" card and its UI "Remove" button if the
#     AuthzPolicy is named `<AGW_EGRESS_NAME>-iap-authzpolicy` (and Extension is
#     `<AGW_EGRESS_NAME>-iap-authzextension`).
export AGW_EGRESS_EXT_NAME="${AGW_EGRESS_NAME}-iap-authzextension"
export AGW_EGRESS_POLICY_NAME="${AGW_EGRESS_NAME}-iap-authzpolicy"

# Unified Access Policy (UAP) and PolicyBinding names
#   - Example: "uap-policy-agw-study-egress", "uap-binding-agw-study-egress"
export UAP_POLICY_NAME="uap-policy-${AGW_EGRESS_NAME}"
export UAP_BINDING_NAME="uap-binding-${AGW_EGRESS_NAME}"

# Ingress Agent Gateway resource name (`CLIENT_TO_AGENT`)
#   - Example: "agw-study-ingress"
export AGW_INGRESS_NAME="agw-study-ingress"

# Ingress Model Armor Template, AuthzExtension & AuthzPolicy names
#   - IMPORTANT UI COMPATIBILITY RULE:
#     The Google Cloud Console UI (`Agent Platform -> Agents -> Gateways`) ONLY
#     displays the "AI Security" card and its UI "Remove" button if the
#     AuthzPolicy is named `<AGW_INGRESS_NAME>-aisecurity-authzpolicy` (and Extension is
#     `<AGW_INGRESS_NAME>-aisecurity-authzextension`).
export MODEL_ARMOR_TEMPLATE_ID="${AGW_INGRESS_NAME}-modar-req-template"
# Ensure `gcloud model-armor` CLI targets the regional REP endpoint for ${REGION}
# (Without this, `gcloud model-armor` defaults to `https://modelarmor.us.rep.googleapis.com/`
#  and fails with 403 PERMISSION_DENIED when REGION is outside the US, e.g. asia-southeast1)
export CLOUDSDK_API_ENDPOINT_OVERRIDES_MODELARMOR="https://modelarmor.${REGION}.rep.googleapis.com/"
export AGW_INGRESS_EXT_NAME="${AGW_INGRESS_NAME}-aisecurity-authzextension"
export AGW_INGRESS_POLICY_NAME="${AGW_INGRESS_NAME}-aisecurity-authzpolicy"

# Cloud Run Base URLs (Used in Mode 1 & Mode 3)
#   - Example: "https://check-gcp-subnet-ips-66063681189.asia-southeast2.run.app"
export CHECK_GCP_SUBNET_IPS_BASE_URL="https://check-gcp-subnet-ips-${PROJECT_NUMBER}.${CLOUD_RUN_REGION}.run.app"
export NETWORK_AGENT_BASE_URL="https://network-agent-agw-${PROJECT_NUMBER}.${CLOUD_RUN_REGION}.run.app"

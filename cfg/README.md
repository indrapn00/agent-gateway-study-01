# `cfg/` — Parameterized Agent Gateway Configuration Guide

When you re-deploy this Agent Gateway architecture to a **different Google Cloud Project**, **different Organization**, **different Region**, or re-create the agents on Vertex AI Agent Engine (which assigns new random **`ReasoningEngine` IDs** and new random **`agentregistry-...` UUIDs**), several values across `cfg/*.yaml`, `cfg/*.json`, and `network_agent/agent.py` must be updated.

Instead of hunting through 8 different YAML/JSON files by hand, we centralized every single configurable variable in **[`cfg/env.sh`](./env.sh)** and created **[`../render_configs.sh`](../render_configs.sh)** to re-generate all `cfg/` files in one command.

---

## 1. Two Ways to Update `cfg/` When Re-Deploying

### Option A: Automatic Discovery via `gcloud` (`--auto-discover`)
After you set your new `PROJECT_ID` and `REGION` in [`cfg/env.sh`](./env.sh) (and after you register your services/agents), run:
```bash
./render_configs.sh --auto-discover
```
`render_configs.sh --auto-discover` automatically queries GCP via `gcloud` to look up your:
- `PROJECT_NUMBER`
- `ORG_ID`
- `SUBNET_ENGINE_ID` (`check-gcp-subnet-ips-agw` ReasoningEngine ID)
- `NETWORK_ENGINE_ID` (`network-agent-agw` ReasoningEngine ID)
- `CORE_GAPI_ENDPOINT_ID` (`agentregistry-...` UUID for `core-gapi-services`)
- `SUBNET_AGENT_AUTO_REG_ID` (`agentregistry-...` UUID for auto-discovered `check-gcp-subnet-ips-agw`)
- `SUBNET_AGENT_CUSTOM_REG_ID` (`agentregistry-...` UUID for custom `.mtls.` service `check-gcp-subnet-ips-agw`)

and re-writes all 8 `.yaml` and `.json` files in `cfg/`!

### Option B: Manual Edit in [`cfg/env.sh`](./env.sh)
Open [`cfg/env.sh`](./env.sh), update the variables with your new values, and run:
```bash
./render_configs.sh
```

---

## 2. Complete Checklist of Variables (Including "Hidden" Static Values!)

| Variable Name in [`cfg/env.sh`](./env.sh) | Description & Why It Changes | Example Value | How to Find It (`gcloud` Command) | Files Where It Is Used |
| :--- | :--- | :--- | :--- | :--- |
| **`PROJECT_ID`** | Your GCP Project ID string. | `"gcp-demo-02-307713"` | `gcloud config get-value project` | `agw-study-egress.yaml`, `agw-study-egress-authz-policy-iap.yaml`, `agw-study-ingress-svc-ext-modar.yaml`, `agw-study-ingress-authz-policy-modar.yaml`, `uap-rules*.json` |
| **`PROJECT_NUMBER`** | Your numeric GCP Project Number. Used in `ReasoningEngine` resource names, SPIFFE IDs, UAP CEL rules, and P4SA service account emails. | `"66063681189"` | `gcloud projects describe $PROJECT_ID --format="value(projectNumber)"` | `uap-rules.json`, `uap-rules-allow-subnet.json`, `network_agent/agent.py` |
| **`ORG_ID`** *(Hidden in SPIFFE URIs!)* | Your numeric GCP Organization ID. Every Agent Platform SPIFFE identity begins with `principal://agents.global.org-<ORG_ID>.system.id.goog/...`. If you move to a project in a different Org, this changes! | `"304553879287"` | `gcloud projects get-ancestors $PROJECT_ID --format="value(id)" \| tail -n 1` | `uap-rules.json`, `uap-rules-allow-subnet.json` |
| **`REGION`** *(Hidden in Model Armor REP hostname!)* | Region for Agent Gateway, Model Armor, Agent Registry, and Agent Platform. Must support both `agentGateways` and `modelarmor`. Also changes the **Regional Endpoint (REP) hostname** in `agw-study-ingress-svc-ext-modar.yaml` (`service: modelarmor.<REGION>.rep.googleapis.com`). | `"us-central1"` or `"asia-southeast1"` | N/A (choose a supported region) | All `cfg/*.yaml`, `uap-rules*.json`, `network_agent/agent.py` |
| **`CLOUD_RUN_REGION`** | Region for Cloud Run services (Mode 1 & Mode 3 Web UI). Can be `asia-southeast2` even when Agent Gateway is in `us-central1`. | `"asia-southeast2"` | N/A | `network_agent/agent.py`, `cfg/env.sh` |
| **`SUBNET_ENGINE_ID`** | Random numeric `ReasoningEngine` ID generated when you deploy `check-gcp-subnet-ips-agw` to Agent Platform. | `"8226712575031640064"` | `gcloud alpha ai reasoning-engines list --region=$REGION --project=$PROJECT_ID --filter="displayName=check-gcp-subnet-ips-agw" --format="value(name)" \| awk -F'/' '{print $NF}'` | `network_agent/agent.py` (or pass `-e SUBNET_ENGINE_ID=...`) |
| **`NETWORK_ENGINE_ID`** | Random numeric `ReasoningEngine` ID generated when you deploy `network-agent-agw` to Agent Platform. Used in the SPIFFE principal of UAP Rule 2. | `"8162536280341610496"` | `gcloud alpha ai reasoning-engines list --region=$REGION --project=$PROJECT_ID --filter="displayName=network-agent-agw" --format="value(name)" \| awk -F'/' '{print $NF}'` | `uap-rules-allow-subnet.json` (Rule 2 `principals`) |
| **`CORE_GAPI_ENDPOINT_ID`** *(Hidden Agent Registry UUID!)* | Random `agentregistry-...` UUID generated when you register `core-gapi-services` in Agent Registry. IAP v2 checks this internal UUID in UAP Rule 1! | `"agentregistry-00000000-0000-0000-444f-0dd5654527c5"` | `gcloud alpha agent-registry services describe core-gapi-services --location=$REGION --project=$PROJECT_ID --format="value(registryResource)" \| awk -F'/' '{print $NF}'` | `uap-rules.json`, `uap-rules-allow-subnet.json` (Rule 1 CEL `expression`) |
| **`SUBNET_AGENT_AUTO_REG_ID`** *(Hidden Agent Registry UUID!)* | Random `agentregistry-...` UUID auto-created in Agent Registry when `check-gcp-subnet-ips-agw` is deployed on Agent Platform. | `"agentregistry-00000000-0000-0000-bf2d-ca1285f7103b"` | `gcloud alpha agent-registry agents list --location=$REGION --project=$PROJECT_ID --filter="displayName=check-gcp-subnet-ips-agw" --format="value(name)" \| head -n 1 \| awk -F'/' '{print $NF}'` | `uap-rules-allow-subnet.json` (Rule 2 CEL `expression`) |
| **`SUBNET_AGENT_CUSTOM_REG_ID`** *(Hidden Agent Registry UUID!)* | Random `agentregistry-...` UUID generated when you register the custom `.mtls.` service `check-gcp-subnet-ips-agw` in Agent Registry. | `"agentregistry-00000000-0000-0000-f25b-29d92d70d0d5"` | `gcloud alpha agent-registry services describe check-gcp-subnet-ips-agw --location=$REGION --project=$PROJECT_ID --format="value(registryResource)" \| awk -F'/' '{print $NF}'` | `uap-rules-allow-subnet.json` (Rule 2 CEL `expression`) |

---

## 3. Non-File IAM Bindings That Also Use `PROJECT_NUMBER` When Moving to a New Project

When you switch to a new GCP project, remember that two Google-managed Service Agents (P4SAs) in the new project include your new **`PROJECT_NUMBER`** in their email addresses and require IAM bindings:

1. **Service Extensions P4SA (`service-${PROJECT_NUMBER}@gcp-sa-dep.iam.gserviceaccount.com`):**
   Must have `roles/modelarmor.user` so the Ingress Agent Gateway can invoke Model Armor templates:
   ```bash
   source cfg/env.sh
   gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
     --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-dep.iam.gserviceaccount.com" \
     --role="roles/modelarmor.user"
   ```
2. **Vertex AI Reasoning Engine P4SA (`service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com`):**
   Must have `roles/aiplatform.user` so one Agent Engine runtime can call `:streamQuery` on another Agent Engine runtime:
   ```bash
   source cfg/env.sh
   gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
     --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com" \
     --role="roles/aiplatform.user"
   ```

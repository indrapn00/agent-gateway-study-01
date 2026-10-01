import json
import os
import sys
from typing import AsyncGenerator
import warnings

import google.auth
import google.auth.transport.requests
from google.adk.agents.base_agent import BaseAgent
from google.adk.agents.invocation_context import InvocationContext
from google.adk.agents.llm_agent import Agent
from google.adk.agents.remote_a2a_agent import RemoteA2aAgent
from google.adk.events.event import Event
from google.genai import types
import httpx

warnings.filterwarnings("ignore", message=".*EXPERIMENTAL.*")

# Ensure Gemini model calls inside Cloud Run or Vertex AI Agent Engine (asia-southeast2)
# route to Vertex AI's global endpoint in Argolis projects:
os.environ["GOOGLE_GENAI_USE_VERTEXAI"] = "TRUE"
os.environ["GOOGLE_CLOUD_LOCATION"] = "global"


# ============================================================================
# CONFIGURATION: CHOOSE HOW `network_agent` CONNECTS TO `check_gcp_subnet_ips`
# ============================================================================
# [AGENT GATEWAY STUDY NOTE 0 - Parameterized Project, Region & ReasoningEngine ID]:
# When re-deploying to a DIFFERENT GCP Project or Region (which also assigns a
# new random numeric `ReasoningEngine` ID), you can either:
#   Option A: Pass individual environment variables (`GCP_PROJECT_NUMBER`,
#             `GCP_REGION`, `CLOUD_RUN_REGION`, `SUBNET_ENGINE_ID`), OR
#   Option B: Pass the full resource path in `CHECK_GCP_SUBNET_IPS_AGENT_ENGINE_ID`
#             (or `CHECK_GCP_SUBNET_IPS_BASE_URL` for Mode 1 Cloud Run), OR
#   Option C: Edit the fallback default values right below.
#
# Variables & Examples:
#   - `GCP_PROJECT_NUMBER`: Your numeric GCP Project Number.
#       * Example: "66063681189"
#       * How to find: `gcloud projects describe <PROJECT_ID> --format="value(projectNumber)"`
#   - `GCP_REGION`: Region where `check-gcp-subnet-ips` is deployed on Agent Platform.
#       * Example: "us-central1" (or "asia-southeast1", "asia-southeast2")
#   - `CLOUD_RUN_REGION`: Region where `check-gcp-subnet-ips` is deployed on Cloud Run (Mode 1).
#       * Example: "asia-southeast2"
#   - `SUBNET_ENGINE_ID`: Random numeric ReasoningEngine ID generated when `check-gcp-subnet-ips`
#     is deployed on Vertex AI Agent Engine.
#       * Example: "8226712575031640064"
# ============================================================================
GCP_PROJECT_NUMBER = os.environ.get("GCP_PROJECT_NUMBER", "66063681189")
GCP_REGION = os.environ.get("GCP_REGION", "us-central1")
CLOUD_RUN_REGION = os.environ.get("CLOUD_RUN_REGION", "asia-southeast2")
SUBNET_ENGINE_ID = os.environ.get("SUBNET_ENGINE_ID", "1020302260355203072")

# Supported values for `SUBNET_AGENT_TARGET`:
#   - "auto":
#       * On Cloud Run -> calls `check-gcp-subnet-ips` on Cloud Run (Mode 1: Native Cloud Run)
#       * On Agent Platform -> calls `check-gcp-subnet-ips` on Agent Platform (Mode 2: Native Agent Platform)
#   - "cloud_run":
#       * Forces `network_agent` to call `check-gcp-subnet-ips` on Cloud Run via A2A URL
#   - "agent_platform" (default for Agent Gateway Study Mode 2 & Mode 3):
#       * Forces `network_agent` to call `check-gcp-subnet-ips` on Agent Platform via ReasoningEngine ID
SUBNET_AGENT_TARGET = os.environ.get("SUBNET_AGENT_TARGET", "agent_platform").lower()

# 1. Target URL for Cloud Run `check-gcp-subnet-ips` (Used in Mode 1: Cloud Run -> Cloud Run)
#    - Description: Base HTTPS URL of the `check-gcp-subnet-ips` Cloud Run service.
#    - Example: "https://check-gcp-subnet-ips-66063681189.asia-southeast2.run.app"
CHECK_GCP_SUBNET_IPS_BASE_URL = os.environ.get(
    "CHECK_GCP_SUBNET_IPS_BASE_URL",
    f"https://check-gcp-subnet-ips-{GCP_PROJECT_NUMBER}.{CLOUD_RUN_REGION}.run.app",
)
CHECK_GCP_SUBNET_IPS_CARD_URL = os.environ.get(
    "CHECK_GCP_SUBNET_IPS_AGENT_CARD_URL",
    f"{CHECK_GCP_SUBNET_IPS_BASE_URL.rstrip('/')}/a2a/check_gcp_subnet_ips/.well-known/agent-card.json",
)

# 2. Target Resource Name for Agent Platform `check-gcp-subnet-ips` (Used in Mode 2 & Mode 3)
#    - Description: Full Vertex AI ReasoningEngine resource name in the format:
#      `projects/<GCP_PROJECT_NUMBER>/locations/<GCP_REGION>/reasoningEngines/<SUBNET_ENGINE_ID>`
#    - Example (us-central1):     "projects/66063681189/locations/us-central1/reasoningEngines/8226712575031640064"
#    - Example (asia-southeast2): "projects/66063681189/locations/asia-southeast2/reasoningEngines/8268573731480141824"
CHECK_GCP_SUBNET_IPS_AGENT_ENGINE_ID = os.environ.get(
    "CHECK_GCP_SUBNET_IPS_AGENT_ENGINE_ID",
    f"projects/{GCP_PROJECT_NUMBER}/locations/{GCP_REGION}/reasoningEngines/{SUBNET_ENGINE_ID}",
)


# ============================================================================
# HELPER CLASS FOR AGENT PLATFORM -> AGENT PLATFORM (OR HYBRID CLOUD RUN -> AGENT PLATFORM)
# ============================================================================

class RemoteAgentEngineSubAgent(BaseAgent):
    """Sub-Agent that calls `check-gcp-subnet-ips` deployed on Vertex AI Agent Engine (Agent Platform)
    via the regional Vertex AI `:streamQuery` REST API with ZERO Cloud Run dependency!"""

    agent_engine_id: str
    location: str = "asia-southeast2"

    async def _run_async_impl(self, ctx: InvocationContext) -> AsyncGenerator[Event, None]:
        user_text = ""
        if ctx.user_content and ctx.user_content.parts:
            user_text = "\n".join(p.text for p in ctx.user_content.parts if p.text)
        if not user_text and ctx.session and ctx.session.events:
            for ev in reversed(ctx.session.events):
                if ev.author == "user" and ev.content and ev.content.parts:
                    texts = [p.text for p in ev.content.parts if p.text]
                    if texts:
                        user_text = "\n".join(texts)
                        break

        creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
        creds.refresh(google.auth.transport.requests.Request())

        # Automatically detect the region from `projects/<num>/locations/<region>/reasoningEngines/<id>`
        parts = self.agent_engine_id.split("/")
        target_location = parts[3] if len(parts) >= 4 and parts[2] == "locations" else self.location
        url = f"https://{target_location}-aiplatform.googleapis.com/v1/{self.agent_engine_id}:streamQuery"
        payload = {
            "class_method": "stream_query",
            "input": {
                "user_id": ctx.user_id or "default_user",
                "message": user_text or "Calculate subnet IPs",
            },
        }

        # [AGENT GATEWAY STUDY NOTE 1 - Egress TLS Inspection Trust]:
        # When `network_agent` runs on Agent Platform bound to an Egress Agent Gateway
        # (`AGENT_TO_ANYWHERE`), Agent Gateway intercepts outbound HTTPS calls and
        # injects its Root CA into `/etc/ssl/certs/ca-certificates.crt`.
        # Because Python's `httpx` defaults to its bundled `certifi` store instead of
        # the OS CA bundle, we explicitly pass `/etc/ssl/certs/ca-certificates.crt` when present.
        ca_bundle = (
            "/etc/ssl/certs/ca-certificates.crt"
            if os.path.exists("/etc/ssl/certs/ca-certificates.crt")
            else True
        )

        final_text = ""
        async with httpx.AsyncClient(timeout=120.0, verify=ca_bundle) as client:
            resp = await client.post(
                url,
                headers={
                    "Authorization": f"Bearer {creds.token}",
                    "Content-Type": "application/json",
                },
                json=payload,
            )
            # [AGENT GATEWAY STUDY NOTE 2 - Surfacing Agent Gateway Policy Blocks]:
            # When Agent Gateway blocks a request (e.g., HTTP 403 Forbidden from IAP v2
            # Egress policy in Mode 2, or HTTP 400/799 from Model Armor Ingress filter in Mode 3),
            # we surface the exact gateway block message clearly instead of raising an unhandled exception.
            if resp.status_code != 200:
                final_text = (
                    f"[Agent Gateway Policy Block - HTTP {resp.status_code}]: "
                    f"Call to `check_gcp_subnet_ips` was blocked by Agent Gateway: {resp.text}"
                )
            else:
                for line in resp.text.splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    data = json.loads(line)
                    if "error" in data or "error_message" in data:
                        err_detail = data.get("error") or data.get("error_message")
                        final_text = f"[Agent Gateway / Runtime Error]: {json.dumps(err_detail)}"
                    for p in data.get("content", {}).get("parts", []):
                        if p.get("text"):
                            final_text = p["text"]

        if not final_text:
            final_text = "No response received from remote Agent Engine."

        yield Event(
            invocation_id=ctx.invocation_id,
            author=self.name,
            branch=ctx.branch,
            content=types.Content(
                role="model",
                parts=[types.Part.from_text(text=final_text)],
            ),
        )


# ============================================================================
# FORK 1: BUILD THE REMOTE `check_gcp_subnet_ips` SUB-AGENT (CLOUD RUN OR AGENT PLATFORM)
# ============================================================================

def _is_running_on_agent_platform() -> bool:
    """Returns True when running inside Vertex AI Agent Engine (Agent Platform).
    Note: Vertex AI Agent Engine runs on a managed Knative runtime under the hood
    (so `K_SERVICE` is set in BOTH Cloud Run and Agent Platform!).
    However:
      - `adk deploy agent_engine` passes `--session_service_uri=agentengine://...` in `sys.argv`, OR
      - Source-based Agent Platform deployments set `VERTX_INK_ENVIRONMENT` / `GOOGLE_CLOUD_AGENT_ENGINE_ID`
        or run from `/code` with `AGENT_PLATFORM_RUNTIME=true`.
    """
    cmdline = " ".join(sys.argv)
    if "agentengine://" in cmdline or "--gemini_enterprise_app_name" in cmdline:
        return True
    # [AGENT GATEWAY STUDY NOTE 3 - Detecting Source-Based Agent Platform Runtime]:
    # When deployed with Agent Identity & Agent Gateway via the Vertex AI SDK,
    # we also check `RUNNING_ON_AGENT_PLATFORM=true` (passed in `env_vars`).
    if os.environ.get("RUNNING_ON_AGENT_PLATFORM", "").lower() == "true":
        return True
    return False


def _create_subnet_sub_agent() -> BaseAgent:
    if SUBNET_AGENT_TARGET == "auto":
        effective_target = "agent_platform" if _is_running_on_agent_platform() else "cloud_run"
    else:
        effective_target = SUBNET_AGENT_TARGET

    if effective_target == "agent_platform":
        # Mode 2 (Agent Platform -> Agent Platform) OR Mode 3 (Cloud Run -> Agent Platform)
        return RemoteAgentEngineSubAgent(
            name="check_gcp_subnet_ips",
            description=(
                "Separately deployed GCP Subnet Calculator Agent on Agent Platform (Vertex AI Agent Engine) "
                "that calculates total IPs, usable IPs, netmask, and the 4 GCP-reserved IP addresses for any IPv4 CIDR block."
            ),
            agent_engine_id=CHECK_GCP_SUBNET_IPS_AGENT_ENGINE_ID,
        )
    else:
        # Mode 1 (Cloud Run -> Cloud Run via A2A protocol)
        return RemoteA2aAgent(
            name="check_gcp_subnet_ips",
            description=(
                "Separately deployed GCP Subnet Calculator Agent on Cloud Run (A2A) "
                "that calculates total IPs, usable IPs, netmask, and the 4 GCP-reserved IP addresses for any IPv4 CIDR block."
            ),
            agent_card=CHECK_GCP_SUBNET_IPS_CARD_URL,
        )


check_gcp_subnet_ips = _create_subnet_sub_agent()


# ============================================================================
# FORK 2 (KEPT AS A LOCAL FUNCTION!): Python Function Tool in `network_agent`
# ============================================================================

def recommend_agent_gateway_mode(traffic_pattern: str) -> dict:
    """Recommends the Google Cloud Agent Gateway deployment mode for a given networking scenario.

    Args:
        traffic_pattern: Description of traffic flow (e.g., 'client to agent', 'agent to mcp tool', 'existing ALB', 'existing SWP').
    """
    pattern = traffic_pattern.lower()
    if "alb" in pattern or "load balancer" in pattern or "swp" in pattern or "secure web proxy" in pattern:
        return {
            "recommended_mode": "Self-Managed Agent Gateway (selfManaged)",
            "attachment_target": "Existing Application Load Balancer (ALB) or Secure Web Proxy (SWP)",
            "how_it_works": (
                "Attaches Agent Gateway governance policies via Service Extensions to your existing "
                "Cloud Load Balancing or Secure Web Proxy infrastructure while binding to Agent Registry."
            ),
        }
    elif "egress" in pattern or "tool" in pattern or "mcp" in pattern or "anywhere" in pattern:
        return {
            "recommended_mode": "Google-Managed Agent Gateway (googleManaged: AGENT_TO_ANYWHERE)",
            "networking_features": "PSC-Interface Egress (networkAttachment) + DNS Peering to your VPC",
            "how_it_works": (
                "Google orchestrates a managed proxy in a tenant project with an mTLS endpoint, "
                "governing outbound Agent-to-Tool (MCP) and Agent-to-Agent (A2A) calls using Agent Registry bindings."
            ),
        }
    else:
        return {
            "recommended_mode": "Google-Managed Agent Gateway (googleManaged: CLIENT_TO_AGENT)",
            "networking_features": "Managed mTLS Endpoint + Root CA validation + Agent Registry governance",
            "how_it_works": (
                "Protects inbound Client-to-Agent or Agent-to-Agent (A2A) traffic with Google-managed "
                "proxy orchestration and identity/registry enforcement."
            ),
        }


# ============================================================================
# MAIN AGENT (`network_agent`): Calls Remote Agent (Fork 1) + Local Function (Fork 2)
# ============================================================================

root_agent = Agent(
    model="gemini-2.5-flash",
    name="network_agent",
    description="Main Google Cloud Networking & Agent Gateway orchestrator agent.",
    instruction=(
        "You are `network_agent`, the Main Google Cloud Networking & Agent Gateway Assistant. "
        "Keep answers clear, structured, and beginner-friendly.\n"
        "- Whenever the user asks about subnet CIDRs, IP sizing, or usable GCP IPs, delegate/transfer the task "
        "to the remote `check_gcp_subnet_ips` agent.\n"
        "- Whenever the user asks about Agent Gateway architecture, deployment modes, or traffic flows, "
        "call your local function tool `recommend_agent_gateway_mode`."
    ),
    sub_agents=[check_gcp_subnet_ips],          # <-- Fork 1: Remote Agent (Cloud Run A2A OR Agent Platform) (🤖)
    tools=[recommend_agent_gateway_mode],       # <-- Fork 2: Local Python Function (🔧)
)

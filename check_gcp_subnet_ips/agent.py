# [AGENT GATEWAY STUDY NOTE]:
# Zero functional changes are required in `check_gcp_subnet_ips/agent.py` to govern this agent
# with Agent Gateway! Both Ingress (`CLIENT_TO_AGENT` + Model Armor) and Egress
# (`AGENT_TO_ANYWHERE` + IAP v2) are attached declaratively at deployment time via
# `identity_type="AGENT_IDENTITY"` and `agent_gateway_config`.

import ipaddress
import os
from google.adk.agents.llm_agent import Agent

# Ensure Gemini model calls inside Cloud Run or Vertex AI Agent Engine (asia-southeast2)
# route to Vertex AI's global endpoint in Argolis projects:
os.environ["GOOGLE_GENAI_USE_VERTEXAI"] = "TRUE"
os.environ["GOOGLE_CLOUD_LOCATION"] = "global"


def calculate_subnet_ips(cidr: str) -> dict:
    """Calculates usable IP addresses and the 4 GCP-reserved IPs for a VPC subnet CIDR block.

    Args:
        cidr: IPv4 CIDR string, e.g. '10.10.0.0/28' or '192.168.1.0/24'.
    """
    try:
        net = ipaddress.IPv4Network(cidr, strict=False)
        total_ips = net.num_addresses
        usable_gcp_ips = max(0, total_ips - 4)
        return {
            "status": "success",
            "cidr": str(net),
            "netmask": str(net.netmask),
            "total_ips": total_ips,
            "usable_gcp_ips": usable_gcp_ips,
            "gcp_reserved_ips": {
                "network_address": str(net.network_address),
                "default_gateway": str(net.network_address + 1),
                "second_to_last_reserved": str(net.broadcast_address - 1),
                "broadcast_address": str(net.broadcast_address),
            },
        }
    except ValueError as e:
        return {"status": "error", "error_message": f"Invalid CIDR '{cidr}': {e}"}


root_agent = Agent(
    model="gemini-2.5-flash",
    name="check_gcp_subnet_ips",
    description=(
        "Standalone GCP Subnet Calculator Agent that calculates total IPs, "
        "usable IPs, netmask, and the 4 GCP-reserved IP addresses for any IPv4 CIDR block."
    ),
    instruction=(
        "You are `check_gcp_subnet_ips`, a standalone Google Cloud VPC Subnet Specialist Agent. "
        "Whenever you receive a subnet CIDR question (for example, '10.10.0.0/28'), "
        "call your `calculate_subnet_ips` tool and return a clear, well-structured breakdown of:\n"
        "- CIDR & Netmask\n"
        "- Total IPv4 Addresses\n"
        "- Usable IPs in Google Cloud VPC (Total - 4)\n"
        "- The exact 4 IP addresses reserved by Google Cloud VPC."
    ),
    tools=[calculate_subnet_ips],
)

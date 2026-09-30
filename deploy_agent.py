#!/usr/bin/env python3
"""Deploy an ADK Agent to Vertex AI Agent Runtime (Reasoning Engine) with Agent Identity and Agent Gateway.

Uses the ADK Dockerfile (`image_spec: {}` + `adk api_server`) deployment pattern with
Agent Gateway Root CA injection (`ARG AGENT_GATEWAY_ROOT_CERTIFICATES`) and supports
fast in-place `agentGatewayConfig` binding via `updateMask=spec.deploymentSpec.agentGatewayConfig`.
"""

import argparse
import os
import shutil
import sys
import tempfile
import time
import google.auth
import google.auth.transport.requests
import requests


DOCKERFILE_TEMPLATE = """FROM python:3.11-slim
WORKDIR /app

USER root
ARG AGENT_GATEWAY_ROOT_CERTIFICATES
RUN if [ -n "$AGENT_GATEWAY_ROOT_CERTIFICATES" ]; then \\
      echo "Installing Agent Gateway root certificates..."; \\
      printf "%b" "$AGENT_GATEWAY_ROOT_CERTIFICATES" | awk 'BEGIN {{c=0}} /BEGIN CERTIFICATE/ {{c++}} c > 0 {{ print > "/usr/local/share/ca-certificates/agw-" c ".crt" }}'; \\
      update-ca-certificates; \\
    fi

ENV GRPC_DEFAULT_SSL_ROOTS_FILE_PATH=${{AGENT_GATEWAY_ROOT_CERTIFICATES:+/etc/ssl/certs/ca-certificates.crt}}
ENV REQUESTS_CA_BUNDLE=${{AGENT_GATEWAY_ROOT_CERTIFICATES:+/etc/ssl/certs/ca-certificates.crt}}
ENV SSL_CERT_FILE=${{AGENT_GATEWAY_ROOT_CERTIFICATES:+/etc/ssl/certs/ca-certificates.crt}}
ENV AGENT_GATEWAY_ROOT_CERT_302034098528=${{AGENT_GATEWAY_ROOT_CERTIFICATES:+/etc/ssl/certs/ca-certificates.crt}}

# Create a non-root user
RUN adduser --disabled-password --gecos "" myuser
USER myuser

ENV PATH="/home/myuser/.local/bin:$PATH"
ENV GOOGLE_GENAI_USE_ENTERPRISE=1
ENV GOOGLE_CLOUD_PROJECT={project}
ENV GOOGLE_CLOUD_LOCATION=global
ENV GOOGLE_GENAI_USE_VERTEXAI=TRUE
ENV RUNNING_ON_AGENT_PLATFORM=true
{extra_env_lines}

RUN pip install --no-cache-dir "google-adk[a2a]==2.9.1" "a2a-sdk[http-server]==1.1.2" "sse-starlette==3.4.11"
RUN python -c "import os, glob, google.adk.cli as cli; d = os.path.dirname(cli.__file__); [os.remove(f) for f in glob.glob(os.path.join(d, 'dev_server*'))]; [os.remove(f) for f in glob.glob(os.path.join(d, '__pycache__', 'dev_server*'))]" || true

COPY --chown=myuser:myuser "agents/{app_name}/" "/app/agents/{app_name}/"
RUN pip install --no-cache-dir -r "/app/agents/{app_name}/requirements.txt"

EXPOSE 8080

CMD adk api_server --port=8080 --host=0.0.0.0 --session_service_uri=agentengine://{resource_name} --memory_service_uri=agentengine://{resource_name} --otel_to_cloud --a2a --gemini_enterprise_app_name={app_name} "/app/agents"
"""


def get_auth_headers() -> dict[str, str]:
    creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    creds.refresh(google.auth.transport.requests.Request())
    return {
        "Authorization": f"Bearer {creds.token}",
        "Content-Type": "application/json",
    }


def patch_agent_gateway_config(
    project: str,
    region: str,
    resource_name: str,
    egress_gw: str | None,
    ingress_gw: str | None,
) -> None:
    """Fast in-place PATCH of spec.deploymentSpec.agentGatewayConfig without rebuilding the container."""
    gw_config = {}
    if egress_gw:
        gw_config["agentToAnywhereConfig"] = {"agentGateway": egress_gw}
    if ingress_gw:
        gw_config["clientToAgentConfig"] = {"agentGateway": ingress_gw}

    base_url = f"https://{region}-aiplatform.googleapis.com/v1beta1"
    url = f"{base_url}/{resource_name}?updateMask=spec.deploymentSpec.agentGatewayConfig"
    payload = {
        "spec": {
            "identityType": "AGENT_IDENTITY",
            "deploymentSpec": {
                "agentGatewayConfig": gw_config,
            },
        }
    }
    print(f"Binding Agent Gateway config to {resource_name}: {gw_config}...")
    resp = requests.patch(url, headers=get_auth_headers(), json=payload, timeout=60)
    data = resp.json()
    if "error" in data:
        raise RuntimeError(f"Failed to patch agentGatewayConfig: {data['error']}")
    op_name = data["name"]
    op_url = f"{base_url}/{op_name}"
    print(f"Waiting for LRO {op_name}...")
    while True:
        op_res = requests.get(op_url, headers=get_auth_headers(), timeout=60).json()
        if op_res.get("done"):
            if "error" in op_res:
                raise RuntimeError(f"Agent Gateway binding failed: {op_res['error']}")
            print(f"SUCCESS: Bound Agent Gateway to {resource_name}")
            return
        time.sleep(10)


def main():
    parser = argparse.ArgumentParser(
        description="Deploy ADK Agent to Vertex AI Agent Engine with Agent Identity and Agent Gateway"
    )
    parser.add_argument("--project", required=True, help="Google Cloud Project ID")
    parser.add_argument("--region", default="us-central1", help="Vertex AI Region")
    parser.add_argument(
        "--src-dir",
        help="Directory containing agent code (must contain agent.py)",
    )
    parser.add_argument(
        "--staging-bucket",
        help="GCS bucket for staging (default: gs://PROJECT-staging)",
    )
    parser.add_argument(
        "--gcs-dir-name",
        help="Optional GCS subdirectory name",
    )
    parser.add_argument(
        "--display-name",
        default="My ADK Agent",
        help="Display name for the deployed agent",
    )
    parser.add_argument(
        "--description",
        default="An ADK agent.",
        help="Agent description",
    )
    parser.add_argument(
        "--agent-gateway-egress",
        help="Egress Agent Gateway resource name (Agent-to-Anywhere)",
    )
    parser.add_argument(
        "--agent-gateway-ingress",
        help="Ingress Agent Gateway resource name (Client-to-Agent)",
    )
    parser.add_argument(
        "--enable-agent-identity",
        action="store_true",
        help="Enable Agent Identity (SPIFFE ID)",
    )
    parser.add_argument(
        "--enable-telemetry",
        action="store_true",
        help="Enable native Reasoning Engine telemetry",
    )
    parser.add_argument(
        "--allow-token-sharing",
        action="store_true",
        help="Allow agent identity token sharing for GCP services",
    )
    parser.add_argument(
        "--update-existing",
        help="Resource name or ID of an existing reasoning engine to update in place",
    )
    parser.add_argument(
        "--bind-gateway-only",
        action="store_true",
        help="Only PATCH spec.deploymentSpec.agentGatewayConfig on --update-existing without rebuilding",
    )
    parser.add_argument(
        "-e",
        "--env-var",
        action="append",
        help="Additional environment variables to pass to deployed engine (format: KEY=VALUE)",
    )

    args = parser.parse_args()

    if args.bind_gateway_only:
        if not args.update_existing:
            raise ValueError("--bind-gateway-only requires --update-existing")
        resource_name = args.update_existing
        if not resource_name.startswith("projects/"):
            resource_name = f"projects/{args.project}/locations/{args.region}/reasoningEngines/{resource_name}"
        patch_agent_gateway_config(
            args.project,
            args.region,
            resource_name,
            args.agent_gateway_egress,
            args.agent_gateway_ingress,
        )
        return

    if not args.src_dir:
        raise ValueError("--src-dir is required unless --bind-gateway-only is set")

    import vertexai
    from google.adk.cli import cli_deploy

    client = vertexai.Client(
        project=args.project,
        location=args.region,
        http_options=dict(api_version="v1beta1"),
    )

    src_abs_path = os.path.abspath(args.src_dir)
    app_name = os.path.basename(os.path.normpath(src_abs_path))

    # 1. Resolve or create the ReasoningEngine resource with AGENT_IDENTITY first
    if args.update_existing:
        resource_name = args.update_existing
        if not resource_name.startswith("projects/"):
            resource_name = (
                f"projects/{args.project}/locations/{args.region}/reasoningEngines/{resource_name}"
            )
        print(f"Using existing ReasoningEngine: {resource_name}")
    else:
        create_cfg = {"display_name": args.display_name}
        if args.enable_agent_identity:
            create_cfg["identity_type"] = "AGENT_IDENTITY"
        print(f"Creating ReasoningEngine shell '{args.display_name}' in {args.region}...")
        engine = client.agent_engines.create(config=create_cfg)
        resource_name = engine.api_resource.name
        print(f"Created ReasoningEngine: {resource_name}")

    staging_dir = tempfile.mkdtemp(prefix="agent_deploy_")
    original_cwd = os.getcwd()

    try:
        agent_dest = os.path.join(staging_dir, "agents", app_name)
        os.makedirs(os.path.dirname(agent_dest), exist_ok=True)

        print(f"Staging agent code from {src_abs_path} to {agent_dest}...")
        shutil.copytree(
            src_abs_path,
            agent_dest,
            ignore=shutil.ignore_patterns(
                "__pycache__", "*.pyc", ".pytest_cache", ".venv", "Dockerfile", ".dockerignore"
            ),
        )

        env_vars = {
            "GOOGLE_GENAI_USE_VERTEXAI": "TRUE",
            "GOOGLE_CLOUD_LOCATION": "global",
            "RUNNING_ON_AGENT_PLATFORM": "true",
        }
        if args.enable_telemetry:
            env_vars["GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY"] = "true"
            env_vars["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"] = "true"
        if args.allow_token_sharing:
            env_vars["GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES"] = "false"
        if args.env_var:
            for item in args.env_var:
                if "=" in item:
                    k, v = item.split("=", 1)
                    env_vars[k.strip()] = v.strip()

        extra_env_lines = "\n".join(f'ENV {k}="{v}"' for k, v in env_vars.items())

        dockerfile_path = os.path.join(staging_dir, "Dockerfile")
        with open(dockerfile_path, "w", encoding="utf-8") as f:
            f.write(
                DOCKERFILE_TEMPLATE.format(
                    project=args.project,
                    app_name=app_name,
                    resource_name=resource_name,
                    extra_env_lines=extra_env_lines,
                )
            )

        os.chdir(staging_dir)

        deploy_config = {
            "display_name": args.display_name,
            "description": args.description,
            "source_packages": [f"agents/{app_name}", "Dockerfile"],
            "image_spec": {},
            "class_methods": cli_deploy._AGENT_ENGINE_CLASS_METHODS,
            "agent_framework": "google-adk",
            "env_vars": env_vars,
        }
        if args.enable_agent_identity:
            deploy_config["identity_type"] = "AGENT_IDENTITY"

        if args.agent_gateway_egress or args.agent_gateway_ingress:
            deploy_config["agent_gateway_config"] = {}
            if args.agent_gateway_egress:
                deploy_config["agent_gateway_config"]["agent_to_anywhere_config"] = {
                    "agent_gateway": args.agent_gateway_egress
                }
            if args.agent_gateway_ingress:
                deploy_config["agent_gateway_config"]["client_to_agent_config"] = {
                    "agent_gateway": args.agent_gateway_ingress
                }

        print(f"Building and deploying '{args.display_name}' ({resource_name})...")
        engine = client.agent_engines.update(name=resource_name, config=deploy_config)
        print(f"SUCCESS: Agent deployed: {engine.api_resource.name}")
    finally:
        os.chdir(original_cwd)
        shutil.rmtree(staging_dir, ignore_errors=True)


if __name__ == "__main__":
    main()

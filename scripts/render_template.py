#!/usr/bin/env python3
"""Render the Hermes Kubernetes template with validated environment substitutions.

Purpose: Convert a template plus installer environment into a manifest while rejecting
unsafe control characters and invalid values at the YAML/shell boundary.
Usage: python3 scripts/render_template.py TEMPLATE OUTPUT
Exit status: 0 on successful rendering; 2 for usage errors; non-zero for validation errors.
"""
import os
import re
import sys
from pathlib import Path

if len(sys.argv) != 3:
    print("usage: render_template.py TEMPLATE OUTPUT", file=sys.stderr)
    sys.exit(2)

tpl = Path(sys.argv[1]).read_text()


def reject_control_chars(name: str, value: str) -> None:
    if any(ord(char) < 0x20 and char not in "\t" for char in value):
        raise SystemExit(f"{name} contains a control character")
    if "\n" in value or "\r" in value:
        raise SystemExit(f"{name} must be a single-line value")


def require_pattern(name: str, pattern: str, *, allow_empty: bool = False) -> None:
    if name not in os.environ:
        return
    value = os.environ.get(name, "")
    reject_control_chars(name, value)
    if not value and allow_empty:
        return
    if not re.fullmatch(pattern, value):
        raise SystemExit(f"invalid {name}")


for env_name, env_value in os.environ.items():
    if env_name.startswith("HERMES_") or env_name in {
        "WEBUI_HOST", "DASHBOARD_HOST", "TLS_SECRET_NAME", "STORAGE_CLASS_NAME",
        "INGRESS_CLASS_NAME", "TRAEFIK_ENTRYPOINT", "MODEL_PROVIDER", "MODEL_NAME",
    }:
        reject_control_chars(env_name, env_value)

require_pattern("HERMES_NAMESPACE", r"[a-z0-9]([-a-z0-9]*[a-z0-9])?")
for host_name in ("WEBUI_HOST", "DASHBOARD_HOST"):
    require_pattern(host_name, r"[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?", allow_empty=True)
require_pattern("TLS_SECRET_NAME", r"[a-z0-9]([-a-z0-9]*[a-z0-9])?", allow_empty=True)
require_pattern("STORAGE_CLASS_NAME", r"[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?", allow_empty=True)
for image_name in ("HERMES_AGENT_IMAGE", "HERMES_WEBUI_IMAGE", "HERMES_BROWSER_IMAGE"):
    require_pattern(image_name, r"[A-Za-z0-9._/@:-]+")
require_pattern("HERMES_IMAGE_PULL_POLICY", r"IfNotPresent|Always")
for size_name in ("HERMES_HOME_STORAGE_SIZE", "HERMES_WORKSPACE_STORAGE_SIZE"):
    require_pattern(size_name, r"[0-9]+([EPTGMK]i?)?")
for boolean_name in (
    "HERMES_AGENT_ENABLED", "HERMES_DASHBOARD_ENABLED", "HERMES_WEBUI_ENABLED",
    "HERMES_BROWSER_ENABLED", "TLS_ENABLED", "HERMES_SSH_SETUP",
    "HERMES_SSH_GENERATE_KEY", "HERMES_ANSIBLE_SETUP", "HERMES_MAINTENANCE_UPGRADE",
):
    require_pattern(boolean_name, r"(?:true|false|TRUE|FALSE|1|0|yes|no|YES|NO|on|off|ON|OFF)")
require_pattern("HERMES_MAINTENANCE_UPGRADE", r"true|false")
for numeric_name in (
    "HERMES_RUNTIME_UID", "HERMES_RUNTIME_GID", "HERMES_WEBUI_MAX_UPLOAD_MB",
    "BROWSER_CONCURRENT", "BROWSER_QUEUED", "BROWSER_TIMEOUT_MS",
):
    require_pattern(numeric_name, r"[0-9]+")
for path_name in ("HERMES_UV_DIR", "HERMES_ADDON_VENV", "HERMES_SSH_KEY_PATH"):
    require_pattern(path_name, r"/[A-Za-z0-9._/@+-]+", allow_empty=True)


def strip_auth_blocks(template: str) -> str:
    mode = os.environ.get("HERMES_AUTH_MODE", "local-password")
    if mode not in {"local-password", "external-oidc"}:
        raise SystemExit(f"unsupported HERMES_AUTH_MODE: {mode}")
    keep_local = mode == "local-password"
    keep_external = mode == "external-oidc"
    for name, keep in (
        ("HERMES_AUTH_LOCAL_ONLY", keep_local),
        ("HERMES_AUTH_EXTERNAL_OIDC", keep_external),
    ):
        start = f"# {name}_START"
        end = f"# {name}_END"
        while start in template:
            before, remainder = template.split(start, 1)
            block, after = remainder.split(end, 1)
            template = before + (block if keep else "") + after
    return template


tpl = strip_auth_blocks(tpl)


def enabled(name: str, default: bool = True) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes", "on"}


disabled_resources: set[tuple[str, str]] = set()
if not enabled("HERMES_DASHBOARD_ENABLED"):
    disabled_resources.update({
        ("Middleware", "hermes-dashboard-login-rewrite"),
        ("Deployment", "hermes-dashboard"),
        ("Service", "hermes-dashboard"),
        ("Ingress", "hermes-dashboard"),
        ("Ingress", "hermes-dashboard-login"),
    })
if not enabled("HERMES_WEBUI_ENABLED"):
    disabled_resources.update({
        ("Deployment", "hermes-webui"),
        ("Service", "hermes-webui"),
        ("Ingress", "hermes-webui"),
    })
if not enabled("HERMES_BROWSER_ENABLED"):
    disabled_resources.update({
        ("Deployment", "hermes-browser"),
        ("Service", "hermes-browser"),
        ("NetworkPolicy", "hermes-browser-restrict"),
    })
if os.environ.get("HERMES_AUTH_MODE", "local-password") in {"external-oidc", "disabled"}:
    disabled_resources.update({
        ("Middleware", "hermes-dashboard-login-rewrite"),
        ("Ingress", "hermes-dashboard-login"),
    })

documents = []
for document in tpl.split("\n---\n"):
    kind_match = re.search(r"(?m)^kind:\s*(\S+)\s*$", document)
    name_match = re.search(
        r"(?ms)^metadata:\s*\n(?:^[ ]+.*\n)*?^[ ]+name:\s*(\S+)\s*$", document
    )
    identity = (
        kind_match.group(1) if kind_match else "",
        name_match.group(1) if name_match else "",
    )
    if identity not in disabled_resources:
        documents.append(document)
tpl = "\n---\n".join(documents)

# Handle the few shell-style conditional blocks used in the manifest template.
storage_line = "${STORAGE_CLASS_NAME:+storageClassName: ${STORAGE_CLASS_NAME}}"
storage = os.environ.get("STORAGE_CLASS_NAME", "")
tpl = tpl.replace(storage_line, f"storageClassName: {storage}" if storage else "")

for host_var in ("WEBUI_HOST", "DASHBOARD_HOST"):
    block = "${TLS_SECRET_NAME:+tls:\n  - hosts:\n    - ${" + host_var + "}\n    secretName: ${TLS_SECRET_NAME}}"
    tls_secret = os.environ.get("TLS_SECRET_NAME", "")
    host = os.environ.get(host_var, "")
    replacement = f"tls:\n  - hosts:\n    - {host}\n    secretName: {tls_secret}" if tls_secret else ""
    tpl = tpl.replace(block, replacement)

namespace = os.environ.get("HERMES_NAMESPACE", "hermes")
tpl = tpl.replace("${DASHBOARD_LOGIN_MIDDLEWARE_ANNOTATION}", f"    traefik.ingress.kubernetes.io/router.middlewares: {namespace}-hermes-dashboard-login-rewrite@kubernetescrd")

pattern = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-(.*?))?\}")


def repl(match: re.Match[str]) -> str:
    name, default = match.group(1), match.group(2)
    return os.environ.get(name, default or "")


out = pattern.sub(repl, tpl)
leftovers = re.findall(r"\$\{[^}]+\}", out)
if leftovers:
    print("unrendered placeholders remain:", ", ".join(sorted(set(leftovers))), file=sys.stderr)
    sys.exit(1)

Path(sys.argv[2]).parent.mkdir(parents=True, exist_ok=True)
Path(sys.argv[2]).write_text(out)

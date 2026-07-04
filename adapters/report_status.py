#!/usr/bin/env python3
"""Reporter Claude Code -> F-AI-X-Portal AgentStatus v1.

Script de disparo unico para hooks de Claude Code. Lee el JSON del hook por
stdin, traduce el evento a AgentStatus y publica por POST. Nunca devuelve un
codigo distinto de 0: el hook no debe interferir con la sesion.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from collections.abc import Mapping
from datetime import datetime, timezone
from typing import Any


DEFAULT_AGENT_ID = "claude-tooty"
DEFAULT_NAME = "Tooty (Claude Code)"
DEFAULT_PORTAL_URL = "http://127.0.0.1:3000"
ROLE = "diseño, dirección y validación"
KIND = "claude"
LOCATION = "local"
POST_TIMEOUT_SECONDS = 3

ALLOWED_STATUSES = {"idle", "thinking", "running", "error", "done", "offline"}
ALLOWED_EVENTS = {"session_start", "user_prompt", "pre_tool", "stop"}
AGENT_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def clean_string(value: Any, *, max_length: int = 120) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = " ".join(value.strip().split())
    if not normalized:
        return None
    return normalized[:max_length]


def read_hook_payload() -> Mapping[str, Any]:
    if sys.stdin.isatty():
        return {}

    try:
        raw = sys.stdin.read()
    except OSError:
        return {}

    if not raw.strip():
        return {}

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return {}

    if not isinstance(payload, Mapping):
        return {}

    return payload


def event_to_status(event: str | None, hook_payload: Mapping[str, Any]) -> dict[str, Any] | None:
    if event == "session_start":
        return {
            "status": "idle",
            "currentTask": "Sesión iniciada",
            "lastLog": "Claude Code listo",
        }

    if event == "user_prompt":
        return {
            "status": "thinking",
            "currentTask": "Procesando nueva instrucción",
        }

    if event == "pre_tool":
        tool_name = clean_string(hook_payload.get("tool_name"), max_length=80)
        current_task = tool_name or "Herramienta de Claude Code"
        last_log = f"Usando {tool_name}" if tool_name else "Usando herramienta"
        return {
            "status": "running",
            "currentTask": current_task,
            "lastLog": last_log,
        }

    if event == "stop":
        return {
            "status": "idle",
            "currentTask": "En espera",
            "lastLog": "Turno completado",
        }

    return None


def build_agent_status(
    *,
    agent_id: str,
    name: str,
    event: str | None,
    hook_payload: Mapping[str, Any],
) -> dict[str, Any] | None:
    event_status = event_to_status(event, hook_payload)
    if event_status is None:
        return None

    payload: dict[str, Any] = {
        "v": 1,
        "agentId": agent_id,
        "name": name,
        "kind": KIND,
        "role": ROLE,
        "status": event_status["status"],
        "location": LOCATION,
        "updatedAt": datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z"),
    }

    for key in ("currentTask", "lastLog"):
        value = clean_string(event_status.get(key), max_length=160)
        if value is not None:
            payload[key] = value

    validate_agent_status(payload)
    return payload


def validate_agent_status(payload: Mapping[str, Any]) -> None:
    allowed_keys = {
        "v",
        "agentId",
        "name",
        "kind",
        "role",
        "status",
        "currentTask",
        "lastLog",
        "location",
        "updatedAt",
    }
    unknown_keys = set(payload) - allowed_keys
    if unknown_keys:
        raise ValueError(f"AgentStatus trae campos no permitidos: {sorted(unknown_keys)}")
    if payload.get("v") != 1:
        raise ValueError("AgentStatus.v debe ser 1.")
    agent_id = payload.get("agentId")
    if not isinstance(agent_id, str) or not AGENT_ID_PATTERN.match(agent_id):
        raise ValueError("AgentStatus.agentId invalido.")
    for key in ("name", "kind", "role", "status", "location", "updatedAt"):
        value = payload.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"AgentStatus.{key} debe ser string no vacio.")
    if payload["status"] not in ALLOWED_STATUSES:
        raise ValueError("AgentStatus.status fuera del enum D3.")
    for key in ("currentTask", "lastLog"):
        value = payload.get(key)
        if value is not None and (not isinstance(value, str) or not value.strip()):
            raise ValueError(f"AgentStatus.{key} debe ser string no vacio si se envia.")


def post_status(*, portal_url: str, agent_id: str, status: Mapping[str, Any]) -> None:
    encoded_agent_id = urllib.parse.quote(agent_id, safe="")
    url = f"{portal_url.rstrip('/')}/api/agents/{encoded_agent_id}/status"
    body = json.dumps(status, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=POST_TIMEOUT_SECONDS) as response:
        response.read()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Reporter Claude Code para F-AI-X-Portal.")
    parser.add_argument(
        "--event",
        metavar="{session_start|user_prompt|pre_tool|stop}",
        help="Tipo de evento recibido desde el hook de Claude Code.",
    )
    parser.add_argument("--agent-id", default=DEFAULT_AGENT_ID, help="Id del nodo en el portal.")
    parser.add_argument("--name", default=DEFAULT_NAME, help="Nombre visible del nodo.")
    parser.add_argument(
        "--portal-url",
        default=os.environ.get("FAIX_PORTAL_URL", DEFAULT_PORTAL_URL),
        help="URL base del portal; tambien puede venir de FAIX_PORTAL_URL.",
    )
    args, _unknown = parser.parse_known_args(argv)
    return args


def run(args: argparse.Namespace) -> None:
    event = clean_string(args.event, max_length=40)
    if event not in ALLOWED_EVENTS:
        return

    agent_id = clean_string(args.agent_id, max_length=80) or DEFAULT_AGENT_ID
    name = clean_string(args.name, max_length=120) or DEFAULT_NAME
    portal_url = clean_string(args.portal_url, max_length=300) or DEFAULT_PORTAL_URL
    hook_payload = read_hook_payload()
    status = build_agent_status(
        agent_id=agent_id,
        name=name,
        event=event,
        hook_payload=hook_payload,
    )
    if status is None:
        return

    post_status(portal_url=portal_url, agent_id=agent_id, status=status)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv or sys.argv[1:])
        run(args)
    except (Exception, SystemExit):
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

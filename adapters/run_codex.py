#!/usr/bin/env python3
"""Wrapper Codex -> F-AI-X-Portal AgentStatus v1.

Envuelve `codex exec` sin capturar stdout/stderr/stdin. La telemetria es
best-effort: si el portal no responde, Codex debe ejecutarse igual.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from collections.abc import Mapping
from datetime import datetime, timezone
from typing import Any


DEFAULT_AGENT_ID = "codex-1"
DEFAULT_NAME = "Codex"
DEFAULT_PORTAL_URL = "http://127.0.0.1:3000"
KIND = "codex"
ROLE = "ejecución de tareas (gpt-5.5 xhigh)"
LOCATION = "local"
POST_TIMEOUT_SECONDS = 3

ALLOWED_STATUSES = {"idle", "thinking", "running", "error", "done", "offline"}
AGENT_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def iso_z_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def clean_string(value: Any, *, max_length: int = 160) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = " ".join(value.strip().split())
    if not normalized:
        return None
    return normalized[:max_length]


def build_agent_status(
    *,
    agent_id: str,
    name: str,
    task: str,
    status: str,
    last_log: str | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "v": 1,
        "agentId": agent_id,
        "name": name,
        "kind": KIND,
        "role": ROLE,
        "status": status,
        "currentTask": task,
        "location": LOCATION,
        "updatedAt": iso_z_now(),
    }

    if status == "done":
        payload["progress"] = 1.0

    clean_log = clean_string(last_log, max_length=160)
    if clean_log is not None:
        payload["lastLog"] = clean_log

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
        "progress",
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
    progress = payload.get("progress")
    if progress is not None and (
        not isinstance(progress, (int, float))
        or isinstance(progress, bool)
        or progress < 0
        or progress > 1
    ):
        raise ValueError("AgentStatus.progress debe estar entre 0 y 1.")


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


def publish_best_effort(*, portal_url: str, agent_id: str, status: Mapping[str, Any]) -> None:
    try:
        post_status(portal_url=portal_url, agent_id=agent_id, status=status)
    except Exception as exc:  # noqa: BLE001 - el wrapper no debe impedir la ejecucion.
        print(f"[run_codex] No se pudo publicar AgentStatus: {exc}", file=sys.stderr)


def split_wrapper_args(argv: list[str]) -> tuple[list[str], list[str]]:
    try:
        separator_index = argv.index("--")
    except ValueError:
        return argv, []
    return argv[:separator_index], argv[separator_index + 1 :]


def parse_args(argv: list[str]) -> tuple[argparse.Namespace, list[str]]:
    wrapper_argv, codex_args = split_wrapper_args(argv)
    parser = argparse.ArgumentParser(
        description="Wrapper de `codex exec` que reporta estado a F-AI-X-Portal.",
        usage="%(prog)s --task \"etiqueta corta\" [--agent-id ID] [--name NOMBRE] "
        "[--portal-url URL] -- [args para codex exec]",
    )
    parser.add_argument(
        "--task",
        required=True,
        help="Etiqueta corta de la tarea; no debe ser el prompt completo.",
    )
    parser.add_argument("--agent-id", default=DEFAULT_AGENT_ID, help="Id del nodo en el portal.")
    parser.add_argument("--name", default=DEFAULT_NAME, help="Nombre visible del nodo.")
    parser.add_argument(
        "--portal-url",
        default=os.environ.get("FAIX_PORTAL_URL", DEFAULT_PORTAL_URL),
        help="URL base del portal; tambien puede venir de FAIX_PORTAL_URL.",
    )
    args = parser.parse_args(wrapper_argv)

    args.task = clean_string(args.task, max_length=160)
    args.agent_id = clean_string(args.agent_id, max_length=80) or DEFAULT_AGENT_ID
    args.name = clean_string(args.name, max_length=120) or DEFAULT_NAME
    args.portal_url = clean_string(args.portal_url, max_length=300) or DEFAULT_PORTAL_URL

    if args.task is None:
        parser.error("--task debe ser una etiqueta corta no vacia.")
    if not AGENT_ID_PATTERN.match(args.agent_id):
        parser.error("--agent-id debe iniciar con letra/numero y usar letras, numeros, '.', '-' o '_'.")

    return args, codex_args


def codex_exit_code(returncode: int) -> int:
    if returncode < 0:
        return 128 + abs(returncode)
    return returncode


def run(args: argparse.Namespace, codex_args: list[str]) -> int:
    running_status = build_agent_status(
        agent_id=args.agent_id,
        name=args.name,
        task=args.task,
        status="running",
    )
    publish_best_effort(portal_url=args.portal_url, agent_id=args.agent_id, status=running_status)

    command = ["codex", "exec", *codex_args]
    try:
        completed = subprocess.run(command, check=False)
        exit_code = codex_exit_code(completed.returncode)
    except FileNotFoundError:
        exit_code = 127
    except PermissionError:
        exit_code = 126

    final_status = "done" if exit_code == 0 else "error"
    final_payload = build_agent_status(
        agent_id=args.agent_id,
        name=args.name,
        task=args.task,
        status=final_status,
        last_log=f"codex exec terminó (exit {exit_code})",
    )
    publish_best_effort(portal_url=args.portal_url, agent_id=args.agent_id, status=final_payload)

    return exit_code


def main(argv: list[str] | None = None) -> int:
    args, codex_args = parse_args(argv or sys.argv[1:])
    return run(args, codex_args)


if __name__ == "__main__":
    raise SystemExit(main())

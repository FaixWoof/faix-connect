# faix-connect 🐾

Conector universal de agentes para **F-AIX Portal** (Faix Labs).

Un solo comando en el servidor del agente — detecta si hay **Hermes**,
**Claude Code** o **Codex**, instala lo necesario y te guía paso a paso:

```bash
# desde el portal:
curl -fsSL http://IP_DEL_PORTAL:3000/connect-agent.sh | bash -s -- \
  --id mi-agente --name MiAgente --location mihost

# o desde este repo:
curl -fsSL https://raw.githubusercontent.com/TU_USUARIO/faix-connect/main/connect-agent.sh | bash -s -- \
  --id mi-agente --name MiAgente --location mihost --portal http://IP_DEL_PORTAL:3000
```

| Tecnología | Qué instala |
|---|---|
| Hermes | `hermes serve` (chat en vivo) + reporter de estado real cada 4s |
| Claude Code | hooks oficiales (`report_status.py`) → estado por evento |
| Codex | wrapper `faix-codex` que envuelve `codex exec` reportando |

Flags: `--kind hermes|claude|codex` (si el host tiene varios agentes),
`--portal URL`, `--serve-port 9119`, `--no-serve`.

Si el server no alcanza el portal, el script imprime el puente SSH exacto
(patrón validado con GIR y ZIM).

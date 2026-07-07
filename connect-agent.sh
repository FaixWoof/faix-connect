#!/usr/bin/env bash
# ==========================================================================
# F-AIX Portal — conector UNIVERSAL de agentes (plug & play)
#
# Un solo comando en el servidor del agente, CON EL USUARIO DUEÑO del agente
# (--name es lo único obligatorio; --id/--location se auto-completan):
#
#   curl -fsSL http://IP_PORTAL:3000/connect-agent.sh | bash -s -- --name MiAgente
#
# Detecta qué tecnología hay instalada (Hermes / Claude Code / Codex) y el
# sistema operativo, instala SOLO lo necesario y te guía paso a paso:
#   · Hermes  → hermes serve (chat en vivo) + reporter de estado real
#   · Claude  → hooks oficiales (report_status.py) → estado real por evento
#   · Codex   → wrapper faix-codex (envuelve `codex exec` reportando estado)
#
# MODO REMOTO (--remote): para servers FUERA de la red del portal (VPS, nube).
# Sin túneles SSH: el serve de Hermes se publica con autenticación oficial
# (usuario+contraseña, proveedor "basic") y el PORTAL se conecta directo:
#   agente:  hermes serve --host 0.0.0.0 + credenciales  (este script lo hace)
#   portal:  Conectar agente → Remoto → pegar URL + credenciales
# El estado lo deriva el portal sondeando GET /api/status (público) — aquí
# no se instala reporter porque el server no puede alcanzar al portal.
#
# IDENTIDAD / MULTI-INSTANCIA: cada usuario del sistema = UN agente distinto
# (p.ej. /root/.hermes = un agente; /home/otro/.hermes = OTRO agente). El
# script siempre te dice qué instancia va a conectar antes de tocar nada.
# ==========================================================================
set -euo pipefail

ID="" NAME="" LOCATION="" KIND="" PORTAL="http://127.0.0.1:3000" SERVE_PORT="9119"
NO_SERVE="0" REMOTE="0" AUTH_USER="faix" AUTH_PASS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --id) ID="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    --location) LOCATION="$2"; shift 2;;
    --kind) KIND="$2"; shift 2;;
    --portal) PORTAL="$2"; shift 2;;
    --serve-port) SERVE_PORT="$2"; shift 2;;
    --no-serve) NO_SERVE="1"; shift;;
    --remote) REMOTE="1"; shift;;
    --auth-user) AUTH_USER="$2"; shift 2;;
    --auth-pass) AUTH_PASS="$2"; shift 2;;
    *) echo "flag desconocida: $1"; exit 1;;
  esac
done

KIND_GIVEN="$KIND"   # recordamos si el usuario pasó --kind (para el resumen "auto")

[ -n "$NAME" ] || {
  echo "uso: connect-agent.sh --name <Nombre> [--id <agent-id>] [--location <host>]"
  echo "     [--kind hermes|claude|codex] [--portal URL] [--remote]"
  echo "     [--serve-port 9119] [--auth-user faix] [--auth-pass ...]"
  exit 1
}

# ubicación por defecto: hostname normalizado (no depende del KIND, va ya).
LOCATION="${LOCATION:-$(hostname -s | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-32)}"

# ------------------------------- 0. sistema -------------------------------
OS="$(uname -s)"
HAS_SYSTEMD="0"
command -v systemctl >/dev/null 2>&1 && HAS_SYSTEMD="1"
echo "→ sistema: $OS $( [ "$HAS_SYSTEMD" = "1" ] && echo '(systemd ✓)' || echo '(sin systemd)')"
if [ "$OS" = "Darwin" ]; then
  echo "  macOS detectado: instalo los scripts; los servicios te los doy como comandos manuales (launchd opcional)."
fi

# --------------------- 0b. identidad y multi-instancia ---------------------
echo "→ identidad: usuario $(whoami)  (HOME=$HOME)"
OTHER_INSTANCES=""
for d in /root /home/*; do
  [ "$d" = "$HOME" ] && continue
  [ -d "$d/.hermes" ] 2>/dev/null && OTHER_INSTANCES="$OTHER_INSTANCES $d"
done
if [ -n "$OTHER_INSTANCES" ]; then
  echo "⚠ OJO — hay OTRAS instancias Hermes en esta máquina:$OTHER_INSTANCES"
  echo "  Cada usuario del sistema = un agente DISTINTO con su propia identidad."
  echo "  Este comando conecta SOLO la instancia de $(whoami): $HOME/.hermes"
  echo "  Si querías conectar otra, cancela (Ctrl-C) y corre el script como ese usuario."
fi

# --------------------------- 1. detectar agente ----------------------------
FOUND=""
[ -x "$HOME/.hermes/hermes-agent/venv/bin/python" ] && FOUND="$FOUND hermes"
command -v claude >/dev/null 2>&1 && FOUND="$FOUND claude"
command -v codex >/dev/null 2>&1 && FOUND="$FOUND codex"
FOUND="$(echo "$FOUND" | xargs || true)"

if [ -z "$KIND" ]; then
  case "$(echo "$FOUND" | wc -w | xargs)" in
    0) echo "✗ No encontré Hermes (~/.hermes/hermes-agent), ni claude, ni codex para el usuario $(whoami)."; exit 1;;
    1) KIND="$FOUND"; echo "✓ detectado: $KIND";;
    *) echo "⚠ Hay varias tecnologías aquí: $FOUND"; echo "  Vuelve a correr con --kind <una de ellas>."; exit 1;;
  esac
fi

# id por defecto: kind-ubicación (sí depende del KIND, ya resuelto arriba).
ID="${ID:-${KIND}-${LOCATION}}"

KIND_AUTO_LABEL=""
[ -z "$KIND_GIVEN" ] && KIND_AUTO_LABEL=" (auto)"
echo "→ conectando: ${NAME}  (id: ${ID} · ubicación: ${LOCATION} · kind: ${KIND}${KIND_AUTO_LABEL})"

# ----------------------------- 2. ver portal -------------------------------
if [ "$REMOTE" = "1" ]; then
  echo "→ modo REMOTO: este server está fuera de la red del portal (no se prueba el portal)."
  if [ "$KIND" != "hermes" ]; then
    echo "✗ El modo remoto hoy aplica a Hermes (claude/codex reportan POR PUSH y necesitan alcanzar el portal)."
    echo "  Para claude/codex remotos: expón el portal o usa una VPN, y corre sin --remote."
    exit 1
  fi
else
  echo "→ probando portal $PORTAL …"
  if ! curl -fsS --max-time 6 "$PORTAL/api/agents" >/dev/null; then
    if [ "$KIND" = "hermes" ]; then
      echo "⚠ El portal no es alcanzable desde aquí → cambio automático a modo REMOTO (gateway público con credenciales)"
      REMOTE="1"
    else
      echo "✗ Este server no alcanza el portal ($PORTAL)."
      echo "  ¿Este server está en OTRA red (VPS / nube)? → vuelve a correr con --remote:"
      echo "    el serve de Hermes se publica con usuario+contraseña y el portal se"
      echo "    conecta directo; no se necesita túnel."
      echo "  Alternativa avanzada (misma red con firewall): puente SSH inverso desde el portal:"
      echo "    ssh -N -R 3000:127.0.0.1:3000 <ssh-alias-de-este-server>"
      exit 1
    fi
  else
    echo "✓ portal alcanzable"
  fi
fi

BIN_DIR="$HOME/.local/bin/faix"; mkdir -p "$BIN_DIR"
if [ "$(id -u)" = "0" ]; then UNIT_DIR="/etc/systemd/system"; SCTL="systemctl"; WANTED="multi-user.target"; else
  UNIT_DIR="$HOME/.config/systemd/user"; SCTL="systemctl --user"; WANTED="default.target"; mkdir -p "$UNIT_DIR"; fi

UNIT_EXTRA=""   # líneas extra de [Service] (p.ej. Environment=) — la usa el modo remoto

install_unit() { # $1 nombre, $2 ExecStart
  [ "$HAS_SYSTEMD" = "1" ] || { echo "  (sin systemd) corre a mano: $2"; return 0; }
  cat > "$UNIT_DIR/$1.service" <<EOF
[Unit]
Description=F-AIX $1
After=network.target
[Service]
ExecStart=$2
Restart=always
RestartSec=5
WorkingDirectory=${HOME}
${UNIT_EXTRA}
[Install]
WantedBy=${WANTED}
EOF
  $SCTL daemon-reload && $SCTL enable --now "$1.service"
  [ "$(id -u)" = "0" ] || loginctl enable-linger "$(whoami)" 2>/dev/null || true
  echo "  servicio $1: $($SCTL is-active "$1")"
}

post_status() { # $1 status, $2 nota
  curl -fsS --max-time 6 -X POST "$PORTAL/api/agents/$ID/status" -H "Content-Type: application/json" -d "{
    \"v\":1,\"agentId\":\"$ID\",\"name\":\"$NAME\",\"kind\":\"$KIND\",\"role\":\"$KIND-agent\",
    \"location\":\"$LOCATION\",\"status\":\"$1\",\"currentTask\":\"$2\",
    \"updatedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >/dev/null && echo "✓ registrado en el portal ($1)"
}

# ============================== HERMES =====================================
if [ "$KIND" = "hermes" ]; then
  VENV_PY="$HOME/.hermes/hermes-agent/venv/bin/python"
  "$VENV_PY" -m hermes_cli.main --version | head -1 || {
    echo "⚠ Hermes no responde. Si es primera vez: corre 'hermes' una vez para loguearte (Nous Portal) y reintenta."; exit 1; }

  # ---------- REMOTO: serve público con auth basic, sin túnel ni reporter ----
  if [ "$REMOTE" = "1" ]; then
    [ -n "$AUTH_PASS" ] || AUTH_PASS="$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
    AUTH_SECRET="$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48)"

    UNIT_EXTRA="Environment=HERMES_DASHBOARD_BASIC_AUTH_USERNAME=${AUTH_USER}
Environment=HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${AUTH_PASS}
Environment=HERMES_DASHBOARD_BASIC_AUTH_SECRET=${AUTH_SECRET}"
    install_unit "faix-serve-${ID}" "${VENV_PY} -m hermes_cli.main serve --host 0.0.0.0 --port ${SERVE_PORT}"
    UNIT_EXTRA=""

    # Firewall local: abrir el puerto (best-effort, según lo que haya).
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
      ufw allow "${SERVE_PORT}/tcp" >/dev/null 2>&1 && echo "  firewall: ufw allow ${SERVE_PORT}/tcp ✓"
    elif command -v iptables >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
      if ! iptables -C INPUT -p tcp --dport "${SERVE_PORT}" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p tcp --dport "${SERVE_PORT}" -j ACCEPT && echo "  firewall: iptables ACCEPT ${SERVE_PORT}/tcp ✓"
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
      else
        echo "  firewall: puerto ${SERVE_PORT} ya permitido en iptables ✓"
      fi
    fi

    # Autocomprobación local: el gate debe estar ACTIVO y con el proveedor basic.
    sleep 4
    STATUS_JSON="$(curl -fsS --max-time 8 "http://127.0.0.1:${SERVE_PORT}/api/status" 2>/dev/null || true)"
    if echo "$STATUS_JSON" | grep -q '"auth_required"[: ]*true' && echo "$STATUS_JSON" | grep -q '"basic"'; then
      echo "✓ serve público con auth activa (proveedor basic)"
    else
      echo "⚠ El serve aún no reporta auth activa; revisa: journalctl -u faix-serve-${ID} -n 30"
    fi

    PUBLIC_IP="$(curl -fsS --max-time 6 ifconfig.me 2>/dev/null || curl -fsS --max-time 6 api.ipify.org 2>/dev/null || echo '<IP-PUBLICA>')"
    echo
    echo "════════════════════════════════════════════════════════════════"
    echo "✓ ${NAME} (Hermes REMOTO) listo. Ahora, en el PORTAL:"
    echo "  Mission Control → Conectar agente → \"Servidor remoto\" y pega:"
    echo "    URL del gateway : http://${PUBLIC_IP}:${SERVE_PORT}"
    echo "    Usuario         : ${AUTH_USER}"
    echo "    Contraseña      : ${AUTH_PASS}"
    echo "    ID / Nombre / Ubicación : ${ID} / ${NAME} / ${LOCATION}"
    echo
    echo "  Si el portal no llega a esa URL, abre el puerto ${SERVE_PORT} en el"
    echo "  firewall de tu NUBE (p.ej. Oracle: VCN → Security List → Ingress"
    echo "  TCP ${SERVE_PORT}). El firewall local ya quedó abierto."
    echo "════════════════════════════════════════════════════════════════"
    echo
    echo "Listo 🐾 — sin túneles: el portal habla directo y con credenciales."
    exit 0
  fi

  # ---------- LOCAL (misma red): serve loopback + túnel + reporter ----------
  cat > "$BIN_DIR/faix_reporter_${ID}.py" <<PYEOF
#!/usr/bin/env python3
import json, socket, time, urllib.request
from datetime import datetime, timezone
BASE = {"v":1,"agentId":"${ID}","name":"${NAME}","kind":"hermes","role":"hermes-agent","location":"${LOCATION}"}
def up():
    try:
        with socket.create_connection(("127.0.0.1", ${SERVE_PORT}), timeout=1.5): return True
    except OSError: return False
while True:
    p = dict(BASE); ok = up()
    p["status"] = "idle" if ok else "error"
    p["currentTask"] = "hermes serve activo (chat listo)" if ok else "hermes serve caído (puerto ${SERVE_PORT})"
    p["updatedAt"] = datetime.now(timezone.utc).isoformat().replace("+00:00","Z")
    try:
        r = urllib.request.Request("${PORTAL}/api/agents/${ID}/status", data=json.dumps(p).encode(),
                                   headers={"Content-Type":"application/json"})
        urllib.request.urlopen(r, timeout=4).read()
    except Exception: pass
    time.sleep(4)
PYEOF
  chmod +x "$BIN_DIR/faix_reporter_${ID}.py"
  [ "$NO_SERVE" = "0" ] && install_unit "faix-serve-${ID}" "${VENV_PY} -m hermes_cli.main serve"
  install_unit "faix-reporter-${ID}" "/usr/bin/python3 ${BIN_DIR}/faix_reporter_${ID}.py"
  echo
  echo "✓ ${NAME} (Hermes) conectado. Para CHAT EN VIVO falta 1 paso en el PORTAL:"
  echo "  1) túnel:  ssh -N -L <puertoLibre>:127.0.0.1:${SERVE_PORT} <ssh-alias-de-este-server>  (servicio faix-*-tunnel)"
  echo "  2) en .gateways.json del portal:  {\"${LOCATION}\": \"http://127.0.0.1:<puertoLibre>\"}"
fi

# ============================== CLAUDE CODE ================================
if [ "$KIND" = "claude" ]; then
  curl -fsS --max-time 10 "$PORTAL/adapters/report_status.py" -o "$BIN_DIR/report_status.py"
  chmod +x "$BIN_DIR/report_status.py"
  python3 - "$ID" "$NAME" "$PORTAL" "$BIN_DIR" <<'PYEOF'
import json, os, sys, shutil
agent_id, name, portal, bin_dir = sys.argv[1:5]
path = os.path.expanduser("~/.claude/settings.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
settings = {}
if os.path.exists(path):
    shutil.copy(path, path + ".bak-faix")
    settings = json.load(open(path))
hooks = settings.setdefault("hooks", {})
cmd = (f"FAIX_PORTAL_URL='{portal}' python3 '{bin_dir}/report_status.py' "
       f"--agent-id '{agent_id}' --name '{name}' --event {{ev}}")
for event, ev in [("SessionStart","session_start"),("UserPromptSubmit","user_prompt"),
                  ("PreToolUse","pre_tool"),("Stop","stop")]:
    entries = hooks.setdefault(event, [])
    if any("report_status.py" in json.dumps(e) for e in entries):
        continue
    entries.append({"hooks":[{"type":"command","command":cmd.format(ev=ev),"async":True,"timeout":5}]})
json.dump(settings, open(path,"w"), indent=2, ensure_ascii=False)
print("✓ hooks instalados en ~/.claude/settings.json (backup .bak-faix)")
PYEOF
  post_status idle "Claude Code con hooks: reporta al usar la CLI"
  echo "✓ ${NAME} (Claude Code) conectado: el estado se actualiza solo cada vez que claude trabaja."
  echo "  ('Sin señal' cuando la CLI no está corriendo = normal)."
fi

# ============================== CODEX ======================================
if [ "$KIND" = "codex" ]; then
  curl -fsS --max-time 10 "$PORTAL/adapters/run_codex.py" -o "$BIN_DIR/run_codex.py"
  chmod +x "$BIN_DIR/run_codex.py"
  cat > "$HOME/.local/bin/faix-codex" <<EOF
#!/usr/bin/env bash
# Envuelve 'codex exec' reportando estado real al F-AIX Portal.
FAIX_PORTAL_URL="${PORTAL}" exec python3 "${BIN_DIR}/run_codex.py" \\
  --agent-id "${ID}" --name "${NAME}" --task "\${FAIX_TASK:-codex}" -- "\$@"
EOF
  chmod +x "$HOME/.local/bin/faix-codex"
  post_status idle "Codex por wrapper: usa faix-codex en lugar de codex exec"
  echo "✓ ${NAME} (Codex) conectado. Usa:  faix-codex <args de codex exec>"
  echo "  (agrega ~/.local/bin al PATH si hace falta)"
fi

echo
echo "Listo 🐾 — revisa el Directorio del portal: ${NAME} ya debe aparecer."

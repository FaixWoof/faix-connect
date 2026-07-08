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
# sistema operativo, instala SOLO lo necesario y te deja LISTO sin pasos
# manuales:
#   · Hermes  → hermes serve (chat en vivo) + reporter de estado real +
#               autoregistro DIRECTO en el portal (POST /api/gateways)
#   · Claude  → hooks oficiales (report_status.py) → estado real por evento
#   · Codex   → wrapper faix-codex (envuelve `codex exec` reportando estado)
#
# HERMES EN LA MISMA RED (LAN): el serve queda protegido con usuario y
# contraseña (auth "basic") y el script registra al agente DIRECTO en el
# portal — sin túneles SSH, sin editar .gateways.json a mano, sin
# placeholders. Volver a correr el comando es seguro: NO rota credenciales,
# NO reinicia servicios sanos, y siempre revalida el registro en el portal.
#
# MODO REMOTO (--remote): para servers FUERA de la red del portal (VPS, nube).
# El serve se publica igual con auth basic, pero como el portal no puede
# alcanzarlo automáticamente hace falta un paso EN EL PORTAL (pegar la URL +
# credenciales en el wizard "Servidor remoto") — eso sí es manual.
#
# DESINSTALAR: mismo comando + --uninstall (funciona aunque ya hayas quitado
# Hermes/Claude/Codex de la máquina):
#   curl -fsSL http://IP_PORTAL:3000/connect-agent.sh | bash -s -- --name MiAgente --uninstall
#
# IDENTIDAD / MULTI-INSTANCIA: cada usuario del sistema = UN agente distinto
# (p.ej. /root/.hermes = un agente; /home/otro/.hermes = OTRO agente). El
# script siempre te dice qué instancia va a conectar antes de tocar nada.
# ==========================================================================
set -euo pipefail

ID="" NAME="" LOCATION="" KIND="" PORTAL="http://127.0.0.1:3000" SERVE_PORT="9119"
NO_SERVE="0" REMOTE="0" AUTH_USER="faix" AUTH_PASS="" ADVERTISE_IP="" UNINSTALL="0"
AUTH_USER_EXPLICIT="0" AUTH_PASS_EXPLICIT="0"

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
    --auth-user) AUTH_USER="$2"; AUTH_USER_EXPLICIT="1"; shift 2;;
    --auth-pass) AUTH_PASS="$2"; AUTH_PASS_EXPLICIT="1"; shift 2;;
    --advertise-ip) ADVERTISE_IP="$2"; shift 2;;
    --uninstall) UNINSTALL="1"; shift;;
    *) echo "flag desconocida: $1"; exit 1;;
  esac
done

KIND_GIVEN="$KIND"   # recordamos si el usuario pasó --kind (para el resumen "auto")

[ -n "$NAME" ] || {
  echo "uso: connect-agent.sh --name <Nombre> [--id <agent-id>] [--location <host>]"
  echo "     [--kind hermes|claude|codex] [--portal URL] [--remote]"
  echo "     [--serve-port 9119] [--auth-user faix] [--auth-pass ...]"
  echo "     [--advertise-ip <IP>]  IP LAN de este server, si no se autodetecta"
  echo "     [--uninstall]          retira el agente de esta máquina (usa --id"
  echo "                            si ya no queda ninguna tecnología instalada)"
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

# --------------------- rutas y utilidades compartidas -----------------------
BIN_DIR="$HOME/.local/bin/faix"; mkdir -p "$BIN_DIR"
if [ "$(id -u)" = "0" ]; then UNIT_DIR="/etc/systemd/system"; SCTL="systemctl"; WANTED="multi-user.target"; else
  UNIT_DIR="$HOME/.config/systemd/user"; SCTL="systemctl --user"; WANTED="default.target"; mkdir -p "$UNIT_DIR"; fi

# Hermes se instala de DOS formas: venv del repo (~/.hermes/hermes-agent/venv)
# o CLI en el PATH (pipx/pip → binario `hermes`). Aceptamos ambas. Esta misma
# detección la usan la conexión normal (sección 1) y --uninstall (sección 0c).
detect_installed_kind() {
  local found=""
  { [ -x "$HOME/.hermes/hermes-agent/venv/bin/python" ] || command -v hermes >/dev/null 2>&1; } && found="$found hermes"
  command -v claude >/dev/null 2>&1 && found="$found claude"
  command -v codex >/dev/null 2>&1 && found="$found codex"
  echo "$found" | xargs || true
}

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

# --------------------------- 0c. desinstalar --------------------------------
# NO requiere que el agente siga instalado: si ya no hay Hermes/Claude/Codex,
# busca los servicios que hayan quedado de una instalación anterior.
if [ "$UNINSTALL" = "1" ]; then
  if [ -z "$ID" ]; then
    if [ -z "$KIND" ]; then
      FOUND="$(detect_installed_kind)"
      [ "$(echo "$FOUND" | wc -w | xargs)" = "1" ] && KIND="$FOUND"
    fi
    if [ -n "$KIND" ]; then
      ID="${KIND}-${LOCATION}"
    else
      MATCHES=""
      for f in "$UNIT_DIR"/faix-serve-*-"${LOCATION}".service; do
        [ -e "$f" ] || continue
        base="$(basename "$f" .service)"
        MATCHES="$MATCHES ${base#faix-serve-}"
      done
      MATCHES="$(echo "$MATCHES" | xargs || true)"
      case "$(echo "$MATCHES" | wc -w | xargs)" in
        0)
          echo "✗ No encontré ninguna tecnología (hermes/claude/codex) ni servicios instalados para la ubicación '${LOCATION}'."
          echo "  Pasa el ID exacto:  connect-agent.sh --name \"${NAME}\" --uninstall --id <agent-id>"
          exit 1
          ;;
        1) ID="$MATCHES";;
        *)
          echo "⚠ Hay varios agentes registrados en esta ubicación: $MATCHES"
          echo "  Vuelve a correr especificando cuál:  --uninstall --id <uno-de-esos>"
          exit 1
          ;;
      esac
    fi
  fi

  echo "→ desinstalando: ${NAME}  (id: ${ID} · ubicación: ${LOCATION})"

  for unit in "faix-serve-${ID}" "faix-reporter-${ID}"; do
    if [ "$HAS_SYSTEMD" = "1" ] && [ -f "$UNIT_DIR/$unit.service" ]; then
      $SCTL disable --now "$unit.service" >/dev/null 2>&1 || true
      rm -f "$UNIT_DIR/$unit.service"
      echo "  ✓ servicio $unit detenido y borrado"
    fi
  done
  [ "$HAS_SYSTEMD" = "1" ] && { $SCTL daemon-reload || true; }
  if [ -f "$BIN_DIR/faix_reporter_${ID}.py" ]; then
    rm -f "$BIN_DIR/faix_reporter_${ID}.py"
    echo "  ✓ reporter borrado"
  fi

  if curl -fsS --max-time 6 -X DELETE "$PORTAL/api/agents/$ID?location=$LOCATION" >/dev/null 2>&1; then
    echo "  ✓ dado de baja en el portal"
  else
    echo "  ⚠ no pude avisar al portal — quítalo desde el portal: Directorio → (o avisa a Tooty)"
  fi

  echo
  echo "🧹 ${NAME} retirado de esta máquina."
  exit 0
fi

# --------------------------- 1. detectar agente ----------------------------
FOUND="$(detect_installed_kind)"

if [ -z "$KIND" ]; then
  case "$(echo "$FOUND" | wc -w | xargs)" in
    0) echo "✗ No encontré Hermes (~/.hermes/hermes-agent ni 'hermes' en el PATH), ni claude, ni codex para el usuario $(whoami)."; exit 1;;
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

UNIT_EXTRA=""   # líneas extra de [Service] (p.ej. Environment=) — la usa hermes

install_unit() { # $1 nombre, $2 ExecStart
  [ "$HAS_SYSTEMD" = "1" ] || { echo "  (sin systemd) corre a mano: $2"; return 0; }
  local unit_file="$UNIT_DIR/$1.service"
  local desired
  desired="$(cat <<EOF
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
)"
  # Idempotencia: si el archivo YA existe con el mismo contenido (mismo
  # comando + mismas variables de entorno) y el servicio está activo, no
  # tocamos nada — evita reinicios/rotaciones innecesarias en un re-run sano.
  if [ -f "$unit_file" ]; then
    local current
    current="$(cat "$unit_file")"
    if [ "$current" = "$desired" ] && [ "$($SCTL is-active "$1" 2>/dev/null || true)" = "active" ]; then
      echo "✓ $1 ya configurado y activo"
      return 0
    fi
    echo "→ actualizando servicio $1…"
  else
    echo "→ instalando servicio $1…"
  fi
  printf '%s\n' "$desired" > "$unit_file"
  $SCTL daemon-reload && $SCTL enable --now "$1.service"
  [ "$(id -u)" = "0" ] || loginctl enable-linger "$(whoami)" 2>/dev/null || true
  echo "  servicio $1: $($SCTL is-active "$1" 2>/dev/null || true)"
}

open_firewall() { # $1 puerto — abre el puerto localmente (LAN o remoto, best-effort)
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 && echo "  firewall: ufw allow ${port}/tcp ✓"
  elif command -v iptables >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
    if ! iptables -C INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null; then
      iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT && echo "  firewall: iptables ACCEPT ${port}/tcp ✓"
      command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
    else
      echo "  firewall: puerto ${port} ya permitido en iptables ✓"
    fi
  else
    echo "  firewall: no pude verificar/abrir automáticamente (revisa manualmente el puerto ${port}/tcp)"
  fi
}

post_status() { # $1 status, $2 nota
  curl -fsS --max-time 6 -X POST "$PORTAL/api/agents/$ID/status" -H "Content-Type: application/json" -d "{
    \"v\":1,\"agentId\":\"$ID\",\"name\":\"$NAME\",\"kind\":\"$KIND\",\"role\":\"$KIND-agent\",
    \"location\":\"$LOCATION\",\"status\":\"$1\",\"currentTask\":\"$2\",
    \"updatedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >/dev/null && echo "✓ registrado en el portal ($1)"
}

# ============================== HERMES =====================================
if [ "$KIND" = "hermes" ]; then
  # Resuelve el ejecutable Hermes según cómo esté instalado. HERMES_CMD acepta
  # subcomandos directamente:  "$HERMES_CMD serve …"  /  "$HERMES_CMD --version".
  if [ -x "$HOME/.hermes/hermes-agent/venv/bin/python" ]; then
    HERMES_CMD="$HOME/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main"
  else
    HERMES_CMD="$(command -v hermes)"
  fi
  HVER="$($HERMES_CMD --version 2>/dev/null | head -1)"
  [ -n "$HVER" ] || {
    echo "⚠ Hermes no responde. Si es primera vez: corre 'hermes' una vez para loguearte (Nous Portal) y reintenta."; exit 1; }
  echo "  Hermes: ${HVER}"

  # VALIDACIÓN CLAVE: el chat en vivo del portal usa el backend 'serve'
  # (JSON-RPC/WebSocket). Versiones viejas de Hermes NO lo traen (tienen
  # 'dashboard'/'gateway', que NO sirven para esto). Si falta, guiamos a
  # actualizar + Nous Portal en vez de instalar un servicio que no arrancaría.
  if ! $HERMES_CMD serve --help 2>&1 | grep -qiE 'backend server|--port|json-rpc|websocket'; then
    echo "✗ Tu Hermes (${HVER}) no expone el backend 'serve' que el portal necesita para el chat en vivo."
    echo "  (El 'gateway' de mensajería —Telegram/Discord— NO sirve para esto; hace falta 'hermes serve'.)"
    echo "  Arréglalo y reintenta:"
    echo "   1) Actualiza Hermes:   hermes update        (o reinstala la última versión)"
    echo "   2) Regístrate/loguéate en Nous Portal:   hermes login   (o: hermes portal)"
    exit 1
  fi
  echo "✓ backend 'serve' disponible"

  # ---------- Credenciales: si ya existían, se conservan (NUNCA rotar en un
  # re-run) — salvo que vengan explícitas con --auth-user/--auth-pass. Aplica
  # igual a modo local y --remote, porque ambos usan la misma unit faix-serve.
  UNIT_FILE_SERVE="$UNIT_DIR/faix-serve-${ID}.service"
  if [ -f "$UNIT_FILE_SERVE" ]; then
    EXISTING_USER="$(grep -m1 '^Environment=HERMES_DASHBOARD_BASIC_AUTH_USERNAME=' "$UNIT_FILE_SERVE" | sed -E 's/^Environment=HERMES_DASHBOARD_BASIC_AUTH_USERNAME=//' || true)"
    EXISTING_PASS="$(grep -m1 '^Environment=HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=' "$UNIT_FILE_SERVE" | sed -E 's/^Environment=HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=//' || true)"
    EXISTING_SECRET="$(grep -m1 '^Environment=HERMES_DASHBOARD_BASIC_AUTH_SECRET=' "$UNIT_FILE_SERVE" | sed -E 's/^Environment=HERMES_DASHBOARD_BASIC_AUTH_SECRET=//' || true)"
    [ "$AUTH_USER_EXPLICIT" = "1" ] || { [ -z "$EXISTING_USER" ] || AUTH_USER="$EXISTING_USER"; }
    [ "$AUTH_PASS_EXPLICIT" = "1" ] || { [ -z "$EXISTING_PASS" ] || AUTH_PASS="$EXISTING_PASS"; }
    [ -z "$EXISTING_SECRET" ] || AUTH_SECRET="$EXISTING_SECRET"
  fi
  [ -n "$AUTH_PASS" ] || AUTH_PASS="$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  [ -n "${AUTH_SECRET:-}" ] || AUTH_SECRET="$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48)"

  # ---------- REMOTO: serve público con auth basic, sin túnel ni reporter ----
  if [ "$REMOTE" = "1" ]; then
    UNIT_EXTRA="Environment=HERMES_DASHBOARD_BASIC_AUTH_USERNAME=${AUTH_USER}
Environment=HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${AUTH_PASS}
Environment=HERMES_DASHBOARD_BASIC_AUTH_SECRET=${AUTH_SECRET}"
    install_unit "faix-serve-${ID}" "${HERMES_CMD} serve --host 0.0.0.0 --port ${SERVE_PORT}"
    UNIT_EXTRA=""

    open_firewall "${SERVE_PORT}"

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

  # ---------- LOCAL (misma red): serve con AUTH + registro directo ----------
  # Mismo protocolo autenticado que el modo remoto (usuario+contraseña). En
  # LAN el portal habla DIRECTO al agente (sin túnel SSH): el serve ya exige
  # login, así que basta con que el firewall deje pasar el puerto y con darlo
  # de alta una vez en el portal (esto último lo hace el propio script).
  cat > "$BIN_DIR/faix_reporter_${ID}.py" <<PYEOF
#!/usr/bin/env python3
import json, os, socket, time, urllib.request
from datetime import datetime, timezone
SERVE_PORT = int(os.environ.get("FAIX_SERVE_PORT", "${SERVE_PORT}"))
BASE = {"v":1,"agentId":"${ID}","name":"${NAME}","kind":"hermes","role":"hermes-agent","location":"${LOCATION}"}
def up():
    try:
        with socket.create_connection(("127.0.0.1", SERVE_PORT), timeout=1.5): return True
    except OSError: return False
while True:
    p = dict(BASE); ok = up()
    p["status"] = "idle" if ok else "error"
    p["currentTask"] = "hermes serve activo (chat listo)" if ok else f"hermes serve caído (puerto {SERVE_PORT})"
    p["updatedAt"] = datetime.now(timezone.utc).isoformat().replace("+00:00","Z")
    try:
        r = urllib.request.Request("${PORTAL}/api/agents/${ID}/status", data=json.dumps(p).encode(),
                                   headers={"Content-Type":"application/json"})
        urllib.request.urlopen(r, timeout=4).read()
    except Exception: pass
    time.sleep(4)
PYEOF
  chmod +x "$BIN_DIR/faix_reporter_${ID}.py"

  if [ "$NO_SERVE" = "0" ]; then
    UNIT_EXTRA="Environment=HERMES_DASHBOARD_BASIC_AUTH_USERNAME=${AUTH_USER}
Environment=HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${AUTH_PASS}
Environment=HERMES_DASHBOARD_BASIC_AUTH_SECRET=${AUTH_SECRET}"
    install_unit "faix-serve-${ID}" "${HERMES_CMD} serve --host 0.0.0.0 --port ${SERVE_PORT}"
    UNIT_EXTRA=""
    open_firewall "${SERVE_PORT}"
  fi
  # El puerto va como variable de entorno (no solo dentro del .py) para que
  # un cambio de --serve-port se detecte como cambio de configuración y el
  # reporter se reinicie (si no, seguiría vigilando el puerto viejo).
  UNIT_EXTRA="Environment=FAIX_SERVE_PORT=${SERVE_PORT}"
  install_unit "faix-reporter-${ID}" "/usr/bin/python3 ${BIN_DIR}/faix_reporter_${ID}.py"
  UNIT_EXTRA=""

  # Autocomprobación: el gate debe quedar ACTIVO con el proveedor basic.
  sleep 4
  STATUS_JSON="$(curl -fsS --max-time 8 "http://127.0.0.1:${SERVE_PORT}/api/status" 2>/dev/null || true)"
  SERVE_OK="0"
  if echo "$STATUS_JSON" | grep -q '"auth_required"[: ]*true' && echo "$STATUS_JSON" | grep -q '"basic"'; then
    SERVE_OK="1"
  fi
  REPORTER_OK="0"
  if [ "$HAS_SYSTEMD" = "1" ]; then
    [ "$($SCTL is-active "faix-reporter-${ID}" 2>/dev/null || true)" = "active" ] && REPORTER_OK="1"
  else
    REPORTER_OK="1"
  fi

  # ---------- Autoregistro: IP LAN de este agente + alta directa en el portal
  AGENT_IP="$ADVERTISE_IP"
  if [ -z "$AGENT_IP" ]; then
    PORTAL_HOST="${PORTAL#*://}"; PORTAL_HOST="${PORTAL_HOST%%/*}"; PORTAL_HOST="${PORTAL_HOST%%:*}"
    AGENT_IP="$(ip route get "$PORTAL_HOST" 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' || true)"
    [ -n "$AGENT_IP" ] || AGENT_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi

  GW_HTTP="" GW_BODY="" GW_ERR=""
  if [ -z "$AGENT_IP" ]; then
    GW_ERR="no pude determinar la IP LAN de este servidor hacia el portal"
  else
    GATEWAY_URL="http://${AGENT_IP}:${SERVE_PORT}"
    GW_RAW="$(curl -sS --max-time 10 -w '\n%{http_code}' -X POST "$PORTAL/api/gateways" \
      -H "Content-Type: application/json" \
      -d "{\"location\":\"${LOCATION}\",\"url\":\"${GATEWAY_URL}\",\"username\":\"${AUTH_USER}\",\"password\":\"${AUTH_PASS}\",\"agentId\":\"${ID}\",\"name\":\"${NAME}\"}" \
      2>/dev/null || true)"
    GW_HTTP="$(echo "$GW_RAW" | tail -1)"
    GW_BODY="$(echo "$GW_RAW" | sed '$d')"
    GW_ERR="$(echo "$GW_BODY" | grep -oE '"error"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"//; s/"$//' || true)"
  fi

  echo
  echo "Resumen:"
  if [ "$SERVE_OK" = "1" ]; then
    echo "  ✓ serve activo (auth ok)"
  else
    echo "  ⚠ serve con problemas — revisa: journalctl -u faix-serve-${ID} -n 30"
  fi
  if [ "$REPORTER_OK" = "1" ]; then
    echo "  ✓ reporter activo"
  else
    echo "  ⚠ reporter con problemas — revisa: journalctl -u faix-reporter-${ID} -n 30"
  fi

  if [ "$GW_HTTP" = "200" ]; then
    echo "  ✓ registrado en el portal (chat verificado)"
    echo
    echo "════════════════════════════════════════════════════════════════"
    echo "🎉 TODO LISTO — abre el portal: ${NAME} ya aparece y el CHAT EN VIVO está activo."
    echo "   Sin pasos extra."
    echo "════════════════════════════════════════════════════════════════"
    exit 0
  else
    echo "  ✗ no se pudo registrar en el portal${GW_HTTP:+ (HTTP $GW_HTTP)}"
    [ -n "$GW_ERR" ] && echo "    motivo: $GW_ERR"
    echo
    if [ -z "$AGENT_IP" ]; then
      echo "  → corre de nuevo agregando:  --advertise-ip <IP-de-este-servidor>"
    else
      echo "  → revisa que el puerto ${SERVE_PORT} esté abierto (ufw/iptables) y"
      echo "    reintenta corriendo el mismo comando (es seguro repetirlo)."
    fi
    exit 1
  fi
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

# faix-connect 🐾

Conector universal de agentes para **F-AIX Portal** (Faix Labs).

Un solo comando en el servidor del agente — detecta si hay **Hermes**,
**Claude Code** o **Codex**, instala lo necesario y te guía paso a paso:

```bash
# desde el portal (solo --name es obligatorio; id/ubicación/tecnología se detectan):
curl -fsSL http://IP_DEL_PORTAL:3000/connect-agent.sh | bash -s -- \
  --name MiAgente --portal http://IP_DEL_PORTAL:3000

# o desde este repo:
curl -fsSL https://raw.githubusercontent.com/FaixWoof/faix-connect/main/connect-agent.sh | bash -s -- \
  --name MiAgente --portal http://IP_DEL_PORTAL:3000
```

| Tecnología | Qué instala |
|---|---|
| Hermes | `hermes serve` (chat en vivo) + reporter de estado real cada 4s |
| Claude Code | hooks oficiales (`report_status.py`) → estado por evento |
| Codex | wrapper `faix-codex` que envuelve `codex exec` reportando |

Defaults automáticos: `--location` = hostname normalizado, `--id` = `<kind>-<ubicación>`.
Flags: `--id`, `--location`, `--kind hermes|claude|codex` (si el host tiene varios agentes),
`--portal URL`, `--serve-port 9119`, `--no-serve`. Si el portal no es alcanzable y hay
Hermes, cambia SOLO a modo remoto.

## Servidor REMOTO (VPS / nube) — sin túneles

Si el server está fuera de la red del portal, agrega `--remote` (Hermes):

```bash
curl -fsSL https://raw.githubusercontent.com/FaixWoof/faix-connect/main/connect-agent.sh | sudo -H bash -s -- \
  --name MiAgente --remote
```

Publica `hermes serve --host 0.0.0.0` con el proveedor de auth **oficial**
de Hermes (usuario+contraseña "basic"; un bind público siempre exige auth),
abre el firewall local e imprime las credenciales para pegarlas en el portal
(Conectar agente → "¿Tu servidor está en OTRA red?"). Recuerda abrir el
puerto también en el firewall de tu nube (Oracle: VCN → Security List →
Ingress TCP 9119). El estado lo deriva el portal sondeando `GET /api/status`.

**Multi-instancia:** cada usuario del sistema = un agente distinto. El script
siempre imprime qué instancia va a conectar; para instancias de root usa
`sudo -H` (patrón validado con ZIM, con Snoopy conviviendo en el mismo server).

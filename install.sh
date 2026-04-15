#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# install.sh — Bare Metal Prometheus + Grafana + Node Exporter Installer
# LineSight Digital | linesightdigital.com
#
# Works on Ubuntu/Debian and RHEL/Alma/Rocky
# Installs binaries as systemd services (no Docker required)
#
# Usage:
#   sudo ./install.sh                            # Full install with defaults
#   sudo ./install.sh --grafana-port 3000 \
#                     --prometheus-port 9090 \
#                     --node-exporter-port 9100  # Custom ports
#   sudo ./install.sh --with-loki                # Also install Loki + Promtail
#   sudo ./install.sh --dry-run                  # Preview only
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
GRAFANA_PORT=3000
PROMETHEUS_PORT=9090
NODE_EXPORTER_PORT=9100
ALERTMANAGER_PORT=9093
LOKI_PORT=3100
PROMTAIL_PORT=9080
WITH_LOKI=false
DRY_RUN=false
LOG_FILE="/var/log/monitoring-install.log"
INSTALL_DIR="/opt/monitoring"
START_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --grafana-port <port>        Grafana port (default: 3000)
  --prometheus-port <port>     Prometheus port (default: 9090)
  --node-exporter-port <port>  Node Exporter port (default: 9100)
  --alertmanager-port <port>   Alertmanager port (default: 9093)
  --loki-port <port>           Loki port (default: 3100)
  --promtail-port <port>       Promtail port (default: 9080)
  --with-loki                  Also install Loki + Promtail (log aggregation)
  --dry-run                    Preview actions without applying changes
  -h, --help                   Show this help

Example:
  sudo ./install.sh --grafana-port 3000 --prometheus-port 9090
  sudo ./install.sh --with-loki
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --grafana-port)       GRAFANA_PORT="${2:-3000}"; shift ;;
    --prometheus-port)    PROMETHEUS_PORT="${2:-9090}"; shift ;;
    --node-exporter-port) NODE_EXPORTER_PORT="${2:-9100}"; shift ;;
    --alertmanager-port)  ALERTMANAGER_PORT="${2:-9093}"; shift ;;
    --loki-port)          LOKI_PORT="${2:-3100}"; shift ;;
    --promtail-port)      PROMTAIL_PORT="${2:-9080}"; shift ;;
    --with-loki)          WITH_LOKI=true ;;
    --dry-run)            DRY_RUN=true ;;
    -h|--help)            usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root (sudo)."
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date +'%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
ok()   { echo "  ✅ $*" | tee -a "$LOG_FILE"; }
warn() { echo "  ⚠️  $*" | tee -a "$LOG_FILE"; }
skip() { echo "  ⏭️  [DRY-RUN] Would: $*" | tee -a "$LOG_FILE"; }
hr()   { printf -- "----------------------------------------------\n" | tee -a "$LOG_FILE"; }
run()  {
  if $DRY_RUN; then
    skip "$*"
  else
    bash -c "$1" >> "$LOG_FILE" 2>&1 || warn "'$1' returned non-zero (continuing)"
  fi
}

# ── OS Detection ──────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  ID_LC="${ID,,}"
  LIKE="${ID_LIKE:-}"
else
  ID_LC="$(uname -s)"
  LIKE=""
fi

IS_DEBIAN=false
IS_RHEL=false
case "$ID_LC:$LIKE" in
  *ubuntu*:*|*debian*:*|debian:*|ubuntu:*) IS_DEBIAN=true ;;
  *almalinux*:*|*rocky*:*|*rhel*:*|*centos*:*|*fedora*:*|:*rhel*|:*fedora*) IS_RHEL=true ;;
esac

# ── Detect arch ───────────────────────────────────────────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  ARCH_GO="amd64" ;;
  aarch64) ARCH_GO="arm64" ;;
  armv7l)  ARCH_GO="armv7" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
log "=== Prometheus + Grafana Stack — Bare Metal Installer ==="
log "Host: $(hostname)  |  OS: ${PRETTY_NAME:-$ID_LC}  |  Arch: $ARCH  |  Time (UTC): $START_TS"
$DRY_RUN && warn "DRY-RUN mode — no changes will be applied"
hr

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1 — Dependencies
# ═══════════════════════════════════════════════════════════════════════════════
log "[1/6] Installing dependencies"
if $IS_DEBIAN; then
  run "apt-get update -y"
  run "apt-get install -y curl wget tar adduser apt-transport-https software-properties-common gnupg2"
  ok "APT dependencies installed"
elif $IS_RHEL; then
  run "dnf install -y curl wget tar"
  ok "DNF dependencies installed"
fi
hr

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2 — Node Exporter
# ═══════════════════════════════════════════════════════════════════════════════
log "[2/6] Node Exporter"
NE_VER=$(curl -sf https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep '"tag_name"' | cut -d'"' -f4 | tr -d 'v' || echo "1.8.2")
NE_URL="https://github.com/prometheus/node_exporter/releases/download/v${NE_VER}/node_exporter-${NE_VER}.linux-${ARCH_GO}.tar.gz"

if ! id node_exporter &>/dev/null; then
  run "useradd --no-create-home --shell /bin/false node_exporter"
  ok "Created user: node_exporter"
fi

run "curl -L '$NE_URL' -o /tmp/node_exporter.tar.gz"
run "tar -xzf /tmp/node_exporter.tar.gz -C /tmp"
run "cp /tmp/node_exporter-${NE_VER}.linux-${ARCH_GO}/node_exporter /usr/local/bin/"
run "chown node_exporter:node_exporter /usr/local/bin/node_exporter"
run "rm -rf /tmp/node_exporter*"
ok "Node Exporter ${NE_VER} installed to /usr/local/bin/"

if ! $DRY_RUN; then
  cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:${NODE_EXPORTER_PORT}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
fi

run "systemctl daemon-reload"
run "systemctl enable --now node_exporter"
ok "Node Exporter running on port ${NODE_EXPORTER_PORT}"
hr

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Prometheus
# ═══════════════════════════════════════════════════════════════════════════════
log "[3/6] Prometheus"
PROM_VER=$(curl -sf https://api.github.com/repos/prometheus/prometheus/releases/latest | grep '"tag_name"' | cut -d'"' -f4 | tr -d 'v' || echo "2.53.1")
PROM_URL="https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}/prometheus-${PROM_VER}.linux-${ARCH_GO}.tar.gz"

if ! id prometheus &>/dev/null; then
  run "useradd --no-create-home --shell /bin/false prometheus"
  ok "Created user: prometheus"
fi

run "mkdir -p /etc/prometheus /var/lib/prometheus"
run "curl -L '$PROM_URL' -o /tmp/prometheus.tar.gz"
run "tar -xzf /tmp/prometheus.tar.gz -C /tmp"
run "cp /tmp/prometheus-${PROM_VER}.linux-${ARCH_GO}/prometheus /usr/local/bin/"
run "cp /tmp/prometheus-${PROM_VER}.linux-${ARCH_GO}/promtool /usr/local/bin/"
run "cp -r /tmp/prometheus-${PROM_VER}.linux-${ARCH_GO}/consoles /etc/prometheus/"
run "cp -r /tmp/prometheus-${PROM_VER}.linux-${ARCH_GO}/console_libraries /etc/prometheus/"
run "chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus"
run "chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool"
run "rm -rf /tmp/prometheus*"
ok "Prometheus ${PROM_VER} installed"

# Copy prometheus.yml config if present alongside this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/config/prometheus.yml" ]]; then
  run "cp '${SCRIPT_DIR}/config/prometheus.yml' /etc/prometheus/prometheus.yml"
  run "chown prometheus:prometheus /etc/prometheus/prometheus.yml"
  ok "Copied prometheus.yml from repo config/"
else
  if ! $DRY_RUN; then
    cat > /etc/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:${PROMETHEUS_PORT}']

  - job_name: node
    static_configs:
      - targets: ['localhost:${NODE_EXPORTER_PORT}']
        labels:
          instance: host
EOF
    chown prometheus:prometheus /etc/prometheus/prometheus.yml
  fi
  warn "No config/prometheus.yml found — minimal config written. Edit /etc/prometheus/prometheus.yml."
fi

if ! $DRY_RUN; then
  cat > /etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus
After=network.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \\
  --config.file=/etc/prometheus/prometheus.yml \\
  --storage.tsdb.path=/var/lib/prometheus \\
  --storage.tsdb.retention.time=30d \\
  --web.listen-address=:${PROMETHEUS_PORT} \\
  --web.console.libraries=/etc/prometheus/console_libraries \\
  --web.console.templates=/etc/prometheus/consoles \\
  --web.enable-lifecycle
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
fi

run "systemctl daemon-reload"
run "systemctl enable --now prometheus"
ok "Prometheus running on port ${PROMETHEUS_PORT}"
hr

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4 — Alertmanager
# ═══════════════════════════════════════════════════════════════════════════════
log "[4/6] Alertmanager"
AM_VER=$(curl -sf https://api.github.com/repos/prometheus/alertmanager/releases/latest | grep '"tag_name"' | cut -d'"' -f4 | tr -d 'v' || echo "0.27.0")
AM_URL="https://github.com/prometheus/alertmanager/releases/download/v${AM_VER}/alertmanager-${AM_VER}.linux-${ARCH_GO}.tar.gz"

run "curl -L '$AM_URL' -o /tmp/alertmanager.tar.gz"
run "tar -xzf /tmp/alertmanager.tar.gz -C /tmp"
run "cp /tmp/alertmanager-${AM_VER}.linux-${ARCH_GO}/alertmanager /usr/local/bin/"
run "cp /tmp/alertmanager-${AM_VER}.linux-${ARCH_GO}/amtool /usr/local/bin/"
run "mkdir -p /etc/alertmanager /var/lib/alertmanager"
run "chown -R prometheus:prometheus /etc/alertmanager /var/lib/alertmanager"
run "rm -rf /tmp/alertmanager*"
ok "Alertmanager ${AM_VER} installed"

if [[ -f "${SCRIPT_DIR}/config/alertmanager.yml" ]]; then
  run "cp '${SCRIPT_DIR}/config/alertmanager.yml' /etc/alertmanager/alertmanager.yml"
  run "chown prometheus:prometheus /etc/alertmanager/alertmanager.yml"
  ok "Copied alertmanager.yml from repo config/"
else
  warn "No config/alertmanager.yml found — place your config at /etc/alertmanager/alertmanager.yml"
fi

if ! $DRY_RUN; then
  cat > /etc/systemd/system/alertmanager.service <<EOF
[Unit]
Description=Alertmanager
After=network.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/alertmanager \\
  --config.file=/etc/alertmanager/alertmanager.yml \\
  --storage.path=/var/lib/alertmanager \\
  --web.listen-address=:${ALERTMANAGER_PORT}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
fi

run "systemctl daemon-reload"
run "systemctl enable --now alertmanager"
ok "Alertmanager running on port ${ALERTMANAGER_PORT}"
hr

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5 — Grafana
# ═══════════════════════════════════════════════════════════════════════════════
log "[5/6] Grafana"
if $IS_DEBIAN; then
  run "curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /usr/share/keyrings/grafana.gpg"
  run "echo 'deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main' | tee /etc/apt/sources.list.d/grafana.list"
  run "apt-get update -y"
  run "apt-get install -y grafana"
  ok "Grafana installed via APT"
elif $IS_RHEL; then
  if ! $DRY_RUN; then
    cat > /etc/yum.repos.d/grafana.repo <<'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
  fi
  run "dnf install -y grafana"
  ok "Grafana installed via DNF"
fi

# Set Grafana port if non-default
if [[ "$GRAFANA_PORT" != "3000" ]]; then
  run "sed -i 's/^;http_port = .*/http_port = ${GRAFANA_PORT}/' /etc/grafana/grafana.ini"
  run "sed -i 's/^http_port = .*/http_port = ${GRAFANA_PORT}/' /etc/grafana/grafana.ini"
  ok "Grafana port set to ${GRAFANA_PORT}"
fi

# Copy provisioning configs if present
if [[ -d "${SCRIPT_DIR}/grafana/provisioning" ]]; then
  run "cp -r '${SCRIPT_DIR}/grafana/provisioning/'* /etc/grafana/provisioning/"
  run "chown -R grafana:grafana /etc/grafana/provisioning/"
  ok "Grafana provisioning configs copied"
fi

run "systemctl daemon-reload"
run "systemctl enable --now grafana-server"
ok "Grafana running on port ${GRAFANA_PORT} (default login: admin / admin)"
warn "Change the Grafana admin password immediately after first login"
hr

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6 — Firewall
# ═══════════════════════════════════════════════════════════════════════════════
log "[6/6] Firewall rules"
OPEN_PORTS="${GRAFANA_PORT} ${PROMETHEUS_PORT} ${NODE_EXPORTER_PORT} ${ALERTMANAGER_PORT}"
$WITH_LOKI && OPEN_PORTS="${OPEN_PORTS} ${LOKI_PORT} ${PROMTAIL_PORT}"

if $IS_DEBIAN && command -v ufw &>/dev/null; then
  for port in $OPEN_PORTS; do
    run "ufw allow ${port}/tcp"
  done
  ok "UFW rules added: ${OPEN_PORTS}"
elif $IS_RHEL && command -v firewall-cmd &>/dev/null; then
  for port in $OPEN_PORTS; do
    run "firewall-cmd --permanent --add-port=${port}/tcp"
  done
  run "firewall-cmd --reload"
  ok "firewalld rules added: ${OPEN_PORTS}"
else
  warn "No supported firewall detected — open these ports manually: ${OPEN_PORTS}"
fi
hr

# ═══════════════════════════════════════════════════════════════════════════════
# OPTIONAL — Loki + Promtail (--with-loki)
# ═══════════════════════════════════════════════════════════════════════════════
if $WITH_LOKI; then
  log "[7/8] Loki"
  LOKI_VER=$(curl -sf https://api.github.com/repos/grafana/loki/releases/latest | grep '"tag_name"' | cut -d'"' -f4 | tr -d 'v' || echo "3.1.0")
  LOKI_URL="https://github.com/grafana/loki/releases/download/v${LOKI_VER}/loki-linux-${ARCH_GO}.zip"

  run "curl -L '$LOKI_URL' -o /tmp/loki.zip"
  run "unzip -o /tmp/loki.zip -d /tmp/loki-bin"
  run "cp /tmp/loki-bin/loki-linux-${ARCH_GO} /usr/local/bin/loki"
  run "chmod +x /usr/local/bin/loki"
  run "rm -rf /tmp/loki.zip /tmp/loki-bin"
  ok "Loki ${LOKI_VER} installed"

  run "mkdir -p /etc/loki /var/lib/loki"

  if [[ -f "${SCRIPT_DIR}/config/loki.yml" ]]; then
    run "cp '${SCRIPT_DIR}/config/loki.yml' /etc/loki/loki.yml"
    # Bare metal: point S3/MinIO endpoint to localhost instead of Docker service name
    run "sed -i 's|http://minio:9000|http://localhost:9000|g' /etc/loki/loki.yml"
    ok "Copied loki.yml — MinIO endpoint updated to localhost"
  else
    warn "No config/loki.yml found — place your config at /etc/loki/loki.yml"
  fi

  if ! $DRY_RUN; then
    cat > /etc/systemd/system/loki.service <<EOF
[Unit]
Description=Loki Log Aggregation
After=network.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/loki -config.file=/etc/loki/loki.yml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  fi

  run "chown -R prometheus:prometheus /etc/loki /var/lib/loki"
  run "systemctl daemon-reload"
  run "systemctl enable --now loki"
  ok "Loki running on port ${LOKI_PORT}"
  hr

  log "[8/8] Promtail"
  PROMTAIL_VER="$LOKI_VER"
  PROMTAIL_URL="https://github.com/grafana/loki/releases/download/v${PROMTAIL_VER}/promtail-linux-${ARCH_GO}.zip"

  run "curl -L '$PROMTAIL_URL' -o /tmp/promtail.zip"
  run "unzip -o /tmp/promtail.zip -d /tmp/promtail-bin"
  run "cp /tmp/promtail-bin/promtail-linux-${ARCH_GO} /usr/local/bin/promtail"
  run "chmod +x /usr/local/bin/promtail"
  run "rm -rf /tmp/promtail.zip /tmp/promtail-bin"
  ok "Promtail ${PROMTAIL_VER} installed"

  run "mkdir -p /etc/promtail /tmp/promtail-positions"

  if [[ -f "${SCRIPT_DIR}/config/promtail.yml" ]]; then
    run "cp '${SCRIPT_DIR}/config/promtail.yml' /etc/promtail/promtail.yml"
    # Bare metal: update Loki push URL and positions path
    run "sed -i 's|http://loki:3100|http://localhost:${LOKI_PORT}|g' /etc/promtail/promtail.yml"
    run "sed -i 's|/tmp/positions|/tmp/promtail-positions|g' /etc/promtail/promtail.yml"
    ok "Copied promtail.yml — Loki URL updated to localhost"
  else
    warn "No config/promtail.yml found — place your config at /etc/promtail/promtail.yml"
  fi

  if ! $DRY_RUN; then
    cat > /etc/systemd/system/promtail.service <<EOF
[Unit]
Description=Promtail Log Shipper
After=network.target loki.service

[Service]
User=root
Group=root
Type=simple
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/promtail.yml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  fi

  run "systemctl daemon-reload"
  run "systemctl enable --now promtail"
  ok "Promtail running — shipping logs to Loki on port ${LOKI_PORT}"

  # Wire Loki datasource into Grafana provisioning
  if [[ -f "${SCRIPT_DIR}/grafana/provisioning/datasources/loki.yml" ]]; then
    run "cp '${SCRIPT_DIR}/grafana/provisioning/datasources/loki.yml' /etc/grafana/provisioning/datasources/loki.yml"
    run "sed -i 's|http://loki:3100|http://localhost:${LOKI_PORT}|g' /etc/grafana/provisioning/datasources/loki.yml"
    run "chown grafana:grafana /etc/grafana/provisioning/datasources/loki.yml"
    run "cp '${SCRIPT_DIR}/grafana/provisioning/dashboards/logs.json' /etc/grafana/provisioning/dashboards/logs.json"
    run "chown grafana:grafana /etc/grafana/provisioning/dashboards/logs.json"
    run "systemctl restart grafana-server"
    ok "Loki datasource + Logs dashboard provisioned in Grafana"
  fi
  hr
fi

# ── Summary ───────────────────────────────────────────────────────────────────
HOST_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "============================================================"
log "[Summary] Bare metal install complete — $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo ""
echo "  ✅ Node Exporter  → http://${HOST_IP}:${NODE_EXPORTER_PORT}/metrics"
echo "  ✅ Prometheus     → http://${HOST_IP}:${PROMETHEUS_PORT}"
echo "  ✅ Alertmanager   → http://${HOST_IP}:${ALERTMANAGER_PORT}"
echo "  ✅ Grafana        → http://${HOST_IP}:${GRAFANA_PORT}"
if $WITH_LOKI; then
echo "  ✅ Loki           → http://${HOST_IP}:${LOKI_PORT}"
echo "  ✅ Promtail       → http://${HOST_IP}:${PROMTAIL_PORT}"
fi
echo ""
echo "  ⚠️  NEXT STEPS:"
echo "     1. Edit /etc/alertmanager/alertmanager.yml — fill in SMTP/Slack credentials"
echo "     2. Log in to Grafana and change the default admin password"
echo "     3. Verify targets at http://${HOST_IP}:${PROMETHEUS_PORT}/targets"
if $WITH_LOKI; then
echo "     4. Verify Loki is ingesting at http://${HOST_IP}:${LOKI_PORT}/ready"
echo "     5. Open the 'Logs Overview' dashboard in Grafana"
fi
echo ""
echo "  Full log: ${LOG_FILE}"
echo "============================================================"

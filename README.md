# 📊 Prometheus + Grafana Monitoring Stack

> **Production-ready monitoring in one command — Docker Compose or bare metal, your choice.**

Deploys Prometheus, Grafana, Node Exporter, cAdvisor, and Alertmanager with pre-wired dashboards, alerting rules, and Email + Slack notifications. Works on Ubuntu/Debian and RHEL/Alma/Rocky. Fully idempotent.

Built for Bay Area SMBs and cloud environments that need real observability without a dedicated ops team.

![Prometheus Grafana Stack](./image/prometheus-grafana-stack.webp)
---

## ⚡ Quick Start — Docker Compose

```bash
git clone https://github.com/suresh-1001/prometheus-grafana-stack.git
cd prometheus-grafana-stack

cp .env.example .env
# Edit .env — set GF_ADMIN_PASSWORD and MINIO_ROOT_PASSWORD before proceeding

# Metrics only (Prometheus + Grafana + Node Exporter + cAdvisor + Alertmanager)
docker compose up -d

# Metrics + Logs (adds Loki + Promtail + MinIO)
docker compose -f docker-compose.yml -f docker-compose.loki.yml up -d
```

**Grafana** → http://localhost:3000 (login: admin / your password from .env)  
**Prometheus** → http://localhost:9090  
**Alertmanager** → http://localhost:9093  
**Loki** → http://localhost:3100 (when running with Loki overlay)  
**MinIO Console** → http://localhost:9001 (when running with Loki overlay)

---

## 🖥️ Quick Start — Bare Metal

```bash
git clone https://github.com/suresh-1001/prometheus-grafana-stack.git
cd prometheus-grafana-stack
chmod +x install.sh

# Preview first
sudo ./install.sh --dry-run

# Metrics stack only
sudo ./install.sh

# Metrics + Loki + Promtail log aggregation
sudo ./install.sh --with-loki
```

Installs Prometheus, Alertmanager, Node Exporter, Grafana (and optionally Loki + Promtail) as systemd services. No Docker required.

Custom ports:
```bash
sudo ./install.sh --grafana-port 3000 --prometheus-port 9090 --with-loki --loki-port 3100
```

---

## 🚀 What's Included

| Component | Purpose | Port |
|---|---|---|
| **Prometheus** | Metrics collection + alerting engine | 9090 |
| **Grafana** | Dashboards and visualization | 3000 |
| **Alertmanager** | Alert routing → Email + Slack | 9093 |
| **Node Exporter** | Host OS metrics (CPU, RAM, disk, net) | 9100 |
| **cAdvisor** | Docker container metrics | 8080 (Docker only) |
| **Loki** | Log aggregation and querying | 3100 (opt-in) |
| **Promtail** | Log shipper (syslog, files, Docker) | 9080 (opt-in) |
| **MinIO** | S3-compatible log storage for Loki | 9000/9001 (Docker opt-in) |

---

## 📊 Dashboards

Three dashboards auto-provision on first boot — no manual import required:

| Dashboard | Covers |
|---|---|
| **Node Overview** | CPU %, memory %, disk %, network I/O, disk I/O — with instance variable filter |
| **Docker Containers** | Per-container CPU, memory, network RX/TX — with container variable filter |
| **Prometheus Overview** | Prometheus + Alertmanager status, scrape duration, samples/sec, TSDB size, active alerts |

> **Want the community dashboards?** Drop these JSONs into `grafana/provisioning/dashboards/` to replace the built-in ones:
> - [Node Exporter Full](https://grafana.com/grafana/dashboards/1860) (ID: 1860)
> - [Docker cAdvisor](https://grafana.com/grafana/dashboards/893) (ID: 893)
> - [Prometheus Overview](https://grafana.com/grafana/dashboards/3662) (ID: 3662)

---

## 🔔 Alerting

### Alert Rules (`config/rules/alerts.rules.yml`)

| Alert | Threshold | Severity |
|---|---|---|
| NodeDown | Node Exporter unreachable 1m | critical |
| HighCPULoad | CPU > 85% for 5m | warning |
| CriticalCPULoad | CPU > 95% for 5m | critical |
| HighMemoryUsage | Memory > 85% for 5m | warning |
| CriticalMemoryUsage | Memory > 95% for 2m | critical |
| DiskSpaceWarning | Disk > 80% | warning |
| DiskSpaceCritical | Disk > 90% | critical |
| DiskWillFillIn4Hours | Predictive fill rate | critical |
| HighDiskIOWait | I/O wait > 20% for 5m | warning |
| NetworkReceiveErrors | RX errors > 0 for 5m | warning |
| SystemdServiceFailed | systemd unit in failed state | critical |
| ContainerDown | Container not seen 1m | critical |
| ContainerHighCPU | Container CPU > 80% for 5m | warning |
| ContainerHighMemory | Container memory > 85% limit for 5m | warning |
| PrometheusDown | Prometheus unreachable | critical |
| AlertmanagerDown | Alertmanager unreachable | critical |
| PrometheusConfigReloadFailed | Config reload failed 5m | warning |

### Configuring Notifications

Edit `config/alertmanager.yml` and replace all `!! CONFIGURE !!` values:

```yaml
# SMTP
smtp_smarthost:     'smtp.gmail.com:587'
smtp_from:          'alerts@yourdomain.com'
smtp_auth_username: 'alerts@yourdomain.com'
smtp_auth_password: 'your-app-password'    # Gmail app password, not account password

# Slack
slack_api_url: 'https://hooks.slack.com/services/YOUR/WEBHOOK/URL'
```

Routing: **critical** alerts → Email + Slack `#alerts-critical`. **Warning** alerts → Slack `#alerts-warning` only.

---

## 🔧 Adding Remote Nodes (Bare Metal)

To monitor additional servers, install Node Exporter on each:

```bash
# On the remote node
curl -L https://github.com/prometheus/node_exporter/releases/latest/download/node_exporter-*.linux-amd64.tar.gz | tar -xz
sudo cp node_exporter-*/node_exporter /usr/local/bin/
sudo useradd --no-create-home --shell /bin/false node_exporter
```

Then add them to `config/prometheus.yml`:

```yaml
- job_name: node-remote
  static_configs:
    - targets:
        - 192.168.1.10:9100
      labels:
        instance: web-01
        env: prod
```

Reload Prometheus without restarting:
```bash
curl -X POST http://localhost:9090/-/reload
```

---

## 📁 Repository Structure

```
prometheus-grafana-stack/
├── docker-compose.yml                      # Full stack — Docker Compose
├── install.sh                              # Bare metal installer (Ubuntu/Debian + RHEL)
├── .env.example                            # Copy to .env and set credentials
├── config/
│   ├── prometheus.yml                      # Scrape configs
│   ├── alertmanager.yml                    # Email + Slack routing
│   └── rules/
│       └── alerts.rules.yml               # 17 alerting rules
├── grafana/
│   └── provisioning/
│       ├── datasources/
│       │   └── prometheus.yml             # Auto-wired Prometheus datasource
│       └── dashboards/
│           ├── dashboard.yml              # Dashboard provider config
│           ├── node.json                  # Node overview dashboard
│           ├── docker.json                # Docker containers dashboard
│           └── prometheus.json            # Prometheus self-monitoring dashboard
├── checklist.md                            # Post-deploy verification checklist
└── README.md
```

---

## 🏗️ Tested On

| Distro | Version |
|---|---|
| Ubuntu | 22.04 LTS, 24.04 LTS |
| AlmaLinux | 8, 9, 10 |
| Rocky Linux | 8, 9 |
| Debian | 11, 12 |

---

## 🔗 Related

- [linux-server-onboarding-baseline](https://github.com/suresh-1001/linux-server-onboarding-baseline) — deploy a clean, hardened server first
- [linux-auto-debug](https://github.com/suresh-1001/linux-auto-debug) — triage and self-heal Linux issues

---

## 👤 Author

**Suresh Chand** — IT Consultant & Fractional IT Director, San Jose CA  
20+ years in Linux systems administration, VMware, Azure, and SMB infrastructure.

---

## 📜 License

MIT — free to use, modify, and distribute.

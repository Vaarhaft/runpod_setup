#!/usr/bin/env bash
set -euo pipefail

# Konfigurieren Sie die Zeitzone sofort
echo 'export TZ="Europe/Berlin"' >> ~/.bashrc
export DEBIAN_FRONTEND=noninteractive

# =========================
# RunPod Environment Variables / S3 Config
# =========================

# RunPod injiziert diese Werte als Umgebungsvariablen.
# Stellen Sie sicher, dass diese im RunPod Template unter "Environment Variables" 
# mit den Werten {{ RUNPOD_SECRET_... }} konfiguriert sind!
AWS_ACCESS_KEY_ID_VAR="${AWS_ACCESS_KEY_ID}"
AWS_SECRET_ACCESS_KEY_VAR="${AWS_SECRET_ACCESS_KEY}"
AWS_DEFAULT_REGION_VAR="${AWS_DEFAULT_REGION:-eu-central-1}"
AWS_DEFAULT_OUTPUT="json"

# Feste Auswahl für diesen Pod (Ihre Anforderung)
S3_SRC="s3://vh-core/GenV03/"
TARGET_DIR="/root/framework/gen"
START_SCRIPT_PATH="${TARGET_DIR}/start.sh"

# =========================
# Config / Helpers (unverändert übernommen)
# =========================
SUDO=""
if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi

log()  { printf "\n\033[1;36m=== %s ===\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*" >&2; }
err()  { printf "\n\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
have_apt() { command -v apt >/dev/null 2>&1; }

apt_safe_install() {
  local pkgs=("$@")
  if ! have_apt; then warn "apt nicht gefunden – überspringe Paketinstallation: ${pkgs[*]}"; return 0; fi
  $SUDO apt update -y
  if ! $SUDO apt install -y "${pkgs[@]}"; then
    warn "apt install hatte Konflikte – versuche Reparatur"
    $SUDO apt -y --fix-broken install || true
    $SUDO apt install -y "${pkgs[@]}"
  fi
}

ensure_pkg_removed() {
  local pkg="$1"
  if have_apt && dpkg -l 2>/dev/null | awk '{print $2" "$1" "$3}' | grep -qE "^${pkg}\s"; then
    $SUDO apt purge -y "$pkg" || true
    $SUDO apt -y --fix-broken install || true
    $SUDO apt autoremove -y || true
  fi
}

ensure_dir_owned() {
  local d="$1"
  $SUDO mkdir -p "$d"
  $SUDO chown -R "$(id -u)":"$(id -g)" "$d" || true
}

# =========================
# 1) SYSTEM & TOOLS
# =========================
log "System-Tools (curl, unzip, ca-certificates, gnupg, tmux) – installiere nur falls nötig"
need_base=()
have_cmd curl   || need_base+=("curl")
have_cmd unzip  || need_base+=("unzip")
have_cmd tmux   || need_base+=("tmux") # Behalten, falls für manuelle Nutzung/Debugging
need_base+=("ca-certificates" "gnupg")
((${#need_base[@]})) && apt_safe_install "${need_base[@]}"

# Node.js 20 + npm via NodeSource
if ! have_cmd node || ! have_cmd npm; then
  log "Installiere Node.js 20 (inkl. npm) via NodeSource"
  ensure_pkg_removed "npm"
  if have_apt; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO -E bash -
    apt_safe_install nodejs
  else
    err "Kein apt verfügbar – Node.js Installation nicht automatisiert."
  fi
  hash -r || true
  have_cmd npm || { err "npm nicht gefunden nach NodeSource-Installation."; exit 1; }
else
  log "Node/NPM bereits vorhanden: node $(node -v), npm $(npm -v)"
  if have_apt && dpkg -l 2>/dev/null | grep -q "^ii\s\+npm\s"; then
    warn "Debian 'npm'-Paket gefunden – entferne zur Konfliktvermeidung."
    ensure_pkg_removed "npm"
  fi
fi

# AWS CLI v2 sicherstellen/aktualisieren
if ! have_cmd aws || ! aws --version 2>/dev/null | grep -q "aws-cli/2"; then
  log "Installiere/Aktualisiere AWS CLI v2"
  tmp="$(mktemp -d)"; pushd "$tmp" >/dev/null
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
  unzip -o awscliv2.zip >/dev/null 2>&1
  # `--update` ignoriert "Found preexisting" Warnungen
  $SUDO ./aws/install --update >/dev/null 2>&1 || true
  popd >/dev/null; rm -rf "$tmp"
  have_cmd aws || { err "AWS CLI v2 nicht verfügbar"; exit 1; }
else
  log "AWS CLI v2 bereits installiert: $(aws --version 2>&1)"
fi

# =========================
# 2) AWS KONFIG (mittels RunPod Secrets)
# =========================

log "Setze AWS Konfiguration (default profile) aus Umgebungsvariablen"
# Setzen der Config-Dateien mit den Werten aus den RunPod Environment Variables
aws configure set aws_access_key_id "${AWS_ACCESS_KEY_ID_VAR}"
aws configure set aws_secret_access_key "${AWS_SECRET_ACCESS_KEY_VAR}"
aws configure set default.region "${AWS_DEFAULT_REGION_VAR}"
aws configure set default.output "${AWS_DEFAULT_OUTPUT}"

log "Teste AWS Auth (STS Call)"
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  err "AWS Auth fehlgeschlagen (STS). Überprüfen Sie die RunPod Secrets."
  exit 1
fi

# =========================
# 3) S3 Sync
# =========================
log "Synchronisiere ${S3_SRC} → ${TARGET_DIR}"
ensure_dir_owned "$TARGET_DIR"

# Wichtig: Nutzen Sie die Environment Variables für Credentials, 
# damit der aws-cli-Befehl sie verwendet.
# (RunPod injiziert sie in die Umgebung, aber wir setzen sie hier explizit
# als temporäre Umgebungsvariablen, um sicherzugehen, falls der Pod sie nicht
# als persistente Shell-Variablen setzt)
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID_VAR}" \
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY_VAR}" \
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION_VAR}" \
  aws s3 sync "$S3_SRC" "$TARGET_DIR" --only-show-errors

log "Download erfolgreich. Ausführen des Framework-Startskripts: ${START_SCRIPT_PATH}"

# =========================
# 4) Hauptprozess starten & am Leben erhalten
# =========================

if [[ -f "${START_SCRIPT_PATH}" ]]; then
  # Führt die eigentliche Logik Ihres Frameworks aus
  log "Starte ${START_SCRIPT_PATH}..."
  exec bash "${START_SCRIPT_PATH}"
else
  warn "Framework-Startskript (${START_SCRIPT_PATH}) nicht gefunden. Container bleibt am Leben."
  # Wenn das Startskript fehlt, halten Sie den Pod am Leben
  sleep infinity
fi

log "Fertig." # Wird nur erreicht, wenn 'exec' fehlschlägt.

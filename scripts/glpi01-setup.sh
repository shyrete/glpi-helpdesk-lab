#!/bin/bash
# =====================================================================================
#  glpi01-setup.sh  -  runs INSIDE the Ubuntu VM GLPI01, after Deploy-GLPILab.ps1
#  Installs Docker, starts GLPI 11 + MySQL, then sets the static IP (last step).
#  Usage:  sudo bash ~/glpi01-setup.sh
#  Lab only: the database password is in clear text on purpose.
# =====================================================================================

echo " ----------------------------------------- VARIABLES ----------------------------------"

GLPI_IP="192.168.100.30"
PREFIX="24"
GATEWAY="192.168.100.1"
DNS_SERVER="192.168.100.10"     # DC1
DOMAIN="labo.lan"
TIMEZONE="Europe/Brussels"
DB_PASSWORD='ChangeMe-Lab2026!'
LAB_USER="${SUDO_USER:-$USER}"
GLPI_DIR="/home/$LAB_USER/glpi"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
LOG="/var/log/glpi01-setup_$TIMESTAMP.log"

if [ "$EUID" -ne 0 ]; then
    echo " ------- ERROR: run with sudo:  sudo bash $0 ---------"
    exit 1
fi

exec > >(tee -a "$LOG") 2>&1     # same idea as Start-Transcript
set -e
echo "=== Script started: $(date '+%Y-%m-%d %H:%M:%S') ==="


echo " ----------------------------------------- Updating Ubuntu ----------------------------------"

apt-get update
apt-get -y upgrade
apt-get install -y curl ca-certificates
echo " ------- Hyper-V tools (so Hyper-V Manager shows the VM's IP) ---------"
apt-get install -y linux-cloud-tools-virtual || echo " ------- WARNING: Hyper-V tools not installed, not blocking ---------"


echo " ----------------------------------------- Timezone ----------------------------------"

timedatectl set-timezone "$TIMEZONE"
timedatectl | grep "Time zone"


echo " ----------------------------------------- Installing Docker ----------------------------------"

if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
else
    echo " ------- Docker already installed ---------"
fi
usermod -aG docker "$LAB_USER"
docker run --rm hello-world


echo " ----------------------------------------- Creating GLPI files ----------------------------------"

mkdir -p "$GLPI_DIR"

cat > "$GLPI_DIR/.env" <<EOF
GLPI_DB_HOST=db
GLPI_DB_PORT=3306
GLPI_DB_NAME=glpi
GLPI_DB_USER=glpi
GLPI_DB_PASSWORD=$DB_PASSWORD
EOF

cat > "$GLPI_DIR/timezone.ini" <<EOF
date.timezone = $TIMEZONE
EOF

cat > "$GLPI_DIR/docker-compose.yml" <<'EOF'
name: glpi
services:
  glpi:
    image: "glpi/glpi:latest"
    restart: "unless-stopped"
    volumes:
      - glpi_data:/var/glpi
      - ./timezone.ini:/usr/local/etc/php/conf.d/zz-timezone.ini:ro
    env_file: .env
    environment:
      TZ: "Europe/Brussels"
    depends_on:
      - db
    ports:
      - "80:80"
  db:
    image: "mysql"
    restart: "unless-stopped"
    volumes:
      - db_data:/var/lib/mysql
    environment:
      TZ: "Europe/Brussels"
      MYSQL_RANDOM_ROOT_PASSWORD: "yes"
      MYSQL_DATABASE: ${GLPI_DB_NAME}
      MYSQL_USER: ${GLPI_DB_USER}
      MYSQL_PASSWORD: ${GLPI_DB_PASSWORD}
volumes:
  glpi_data:
  db_data:
EOF

chown -R "$LAB_USER":"$LAB_USER" "$GLPI_DIR"
chmod 600 "$GLPI_DIR/.env"


echo " ----------------------------------------- Starting GLPI ----------------------------------"

cd "$GLPI_DIR"
docker compose up -d

echo " ------- Waiting for GLPI to answer (first start installs the database, can take a few minutes) ---------"
GLPI_READY=0
for i in $(seq 1 60); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost || true)
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
        GLPI_READY=1
        break
    fi
    sleep 10
done
if [ "$GLPI_READY" = "1" ]; then
    echo " ------- GLPI is answering ---------"
else
    echo " ------- WARNING: GLPI not answering after 10 min - check: docker compose logs glpi ---------"
fi


echo " ----------------------------------------- Static IP (LAST STEP - your SSH session will drop) ----------------------------------"

IFACE=$(ip route | awk '/default/ {print $5; exit}')
echo " ------- Interface: $IFACE -> $GLPI_IP/$PREFIX ---------"

# Stop cloud-init from rewriting the network config at the next boot
mkdir -p /etc/cloud/cloud.cfg.d
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
if [ -f /etc/netplan/50-cloud-init.yaml ]; then
    mv /etc/netplan/50-cloud-init.yaml /root/50-cloud-init.yaml.bak
fi

cat > /etc/netplan/60-static.yaml <<EOF
network:
  version: 2
  ethernets:
    $IFACE:
      dhcp4: false
      addresses: [$GLPI_IP/$PREFIX]
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [$DNS_SERVER]
        search: [$DOMAIN]
EOF
chmod 600 /etc/netplan/60-static.yaml

echo ""
echo " DONE. Log: $LOG"
echo " Reconnect with:  ssh $LAB_USER@$GLPI_IP"
echo " Open GLPI:       http://glpi.$DOMAIN  (or http://$GLPI_IP)  - login glpi / glpi, then change ALL default passwords"
echo "=== Script finished: $(date '+%Y-%m-%d %H:%M:%S') ==="

netplan apply

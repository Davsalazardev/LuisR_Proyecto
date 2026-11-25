#!/usr/bin/env bash
# ==============================================================================
# Instalación base de Docker Engine y Docker Compose en Ubuntu 24.04 EC2
# Ejecutar en cada instancia EC2 (t3.micro / t2.micro)
# ==============================================================================
set -euo pipefail

sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release git

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

sudo usermod -aG docker "$USER"
sudo systemctl enable docker
sudo systemctl start docker

echo "[OK] Docker instalado. Cierra y vuelve a abrir SSH (o ejecuta 'newgrp docker')."
docker --version
docker compose version

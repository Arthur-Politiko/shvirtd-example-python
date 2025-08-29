#!/usr/bin/env bash
set -e

REPO_URL="https://github.com/Arthur-Politiko/shvirtd-example-python.git"
TARGET_DIR="/opt/shvirtd-example-python"

# Клонируем форк в /opt (пересоздаём каталог)
sudo rm -rf "$TARGET_DIR"
sudo git clone "$REPO_URL" "$TARGET_DIR"

# Запуск только compose.yaml
cd "$TARGET_DIR"
docker compose up -d

echo "[INFO] Запущено. Проверка состояния:" 
docker compose -f compose.yaml ps

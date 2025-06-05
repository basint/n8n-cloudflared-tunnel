#!/bin/bash

# Function to get current UTC timestamp in ISO 8601 format
get_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}
# Color and style variables for terminal output
CYAN='\033[38;2;0;255;255m'       # (Info)      #00FFFF
YELLOW='\033[38;2;255;213;79m'    # (Context)   #FFD54F
GREEN='\033[38;2;99;255;99m'      # (Success)   #63FF63
RED='\033[38;2;255;99;99m'        # (Error)     #FF6363
GRAY='\033[38;2;180;180;180m'     # (Subtext)   #B4B4B4
RESET='\033[0m'                   # Reset color
BOLD='\033[1m'                    # Bold text
RESET_BOLD='\033[22m'             # Reset bold Text

# Parse optional command-line arguments for environment variables
# Usage: ./run-n8n-tunnel.sh [-h domain_name] [-t tunnel_name] [-c credentials_file] [-d data_dir] [-n container_name]
while getopts "h:t:c:d:n:" opt; do
  case $opt in
    h) DOMAIN_NAME="$OPTARG" ;;
    t) TUNNEL_NAME="$OPTARG" ;;
    c) CREDENTIALS_FILE="$OPTARG" ;;
    d) HOST_DATA_DIR="$OPTARG" ;;
    n) CONTAINER_NAME="$OPTARG" ;;
    *)
      echo "Usage: $0 [-h domain_name] [-t tunnel_name] [-c credentials_file] [-d data_dir] [-n container_name]"
      exit 1
      ;;
  esac
 done

# Set variables for cloudflared and n8n (with defaults if not set by CLI)
CLOUDFLARED_DIR="$HOME/.cloudflared"
: "${DOMAIN_NAME:=yourdomain.com}"
: "${TUNNEL_NAME:=n8n-tunnel}"
: "${CREDENTIALS_FILE:=$CLOUDFLARED_DIR/bbdef245-d94c-44f8-8a2c-dab3533abebb.json}"
: "${HOST_DATA_DIR:=$HOME/Documents/Docker/n8n-data}"
: "${CONTAINER_NAME:=n8n}"
CONFIG_FILE="$CLOUDFLARED_DIR/config.yml"
WEBHOOK_URL="$DOMAIN_NAME"

# Cleanup function: called on Ctrl+C or termination signal
cleanup() {
  echo -e "$(get_timestamp) ERR ${RED}[✖]${RESET} ${YELLOW}🛑 ${BOLD}Shutdown signal detected! Cleaning up cloudflared and n8n container.${RESET_BOLD}${RESET}"
  if [ -n "$CF_PID" ]; then
    kill $CF_PID 2>/dev/null
  fi
  exit 0
}
trap cleanup INT TERM

# Step 1: Always create a new config.yml for cloudflared tunnel
# This file configures the tunnel, credentials, and ingress rules for n8n
  echo -e "$(get_timestamp) INF ${CYAN}[✔]${RESET} ${YELLOW}📝 ${BOLD}Creating a new config.yml file for cloudflared.${RESET_BOLD}${RESET}"
  mkdir -p "$CLOUDFLARED_DIR"
  cat > "$CONFIG_FILE" <<EOF
tunnel: $TUNNEL_NAME
credentials-file: $CREDENTIALS_FILE

ingress:
  - hostname: $DOMAIN_NAME
    service: http://localhost:5678
  - service: http_status:404
EOF

# Step 2: Check and run n8n docker container
# If the container does not exist, create and initialize it with utility tools
if ! docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
  echo -e "$(get_timestamp) INF ${CYAN}[✔]${RESET} ${YELLOW}🐳 ${BOLD}n8n container not found. Creating a new one.${RESET_BOLD}${RESET}"
  mkdir -p "$HOST_DATA_DIR"
  docker run -d \
    --name $CONTAINER_NAME \
    -p 5678:5678 \
    -e WEBHOOK_URL=$WEBHOOK_URL \
    -e N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true \
    -e N8N_RUNNERS_ENABLED=true \
    -v $HOST_DATA_DIR:/home/node/.n8n \
    n8nio/n8n:latest
  sleep 3
  # Install bash, curl, nano inside the container for convenience
  echo -e "$(get_timestamp) INF ${CYAN}[✔]${RESET} ${YELLOW}🔧 ${BOLD}Installing bash, curl, nano in the container...${RESET_BOLD}${RESET}"
  docker exec -u root $CONTAINER_NAME apk update > /dev/null
  docker exec -u root $CONTAINER_NAME apk add --no-cache bash curl nano > /dev/null
else
  # If the container exists but is stopped, start it
  if ! docker ps --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    echo -e "$(get_timestamp) INF ${CYAN}[✔]${RESET} ${YELLOW}🐳 ${BOLD}n8n container is stopped. Starting it.${RESET_BOLD}${RESET}"
    docker start $CONTAINER_NAME
  else
    echo -e "$(get_timestamp) INF ${CYAN}[✔]${RESET} ${YELLOW}🐳 ${BOLD}n8n container is already running.${RESET_BOLD}${RESET}"
  fi
fi

# Step 3: Always (re)create DNS route between tunnel and domain
# This ensures the tunnel is mapped to the custom domain, forcibly updating the record
  echo -e "$(get_timestamp) INF ${CYAN}[✔]${RESET} ${YELLOW}🌐 ${BOLD}Forcibly mapping tunnel to domain via DNS route.${RESET_BOLD}${RESET}"
  ROUTE_OUTPUT=$(cloudflared tunnel route dns $TUNNEL_NAME $DOMAIN_NAME 2>&1)

  if echo "$ROUTE_OUTPUT" | grep -q "already configured"; then
    echo -e "$(get_timestamp) INF ${CYAN}[✔]${RESET} ${YELLOW}🌐 ${BOLD}A DNS record for $DOMAIN_NAME already exists. Skipping creation.${RESET_BOLD}${RESET}"
  elif echo "$ROUTE_OUTPUT" | grep -qi "Added CNAME"; then
    echo -e "$(get_timestamp) INF ${CYAN}[✔]${RESET} ${YELLOW}🌐 ${BOLD}Tunnel successfully mapped to domain.${RESET_BOLD}${RESET}"
  else
    echo -e "$(get_timestamp) ERR ${RED}[✖]${RESET} ${RED}🌐 ${BOLD}Failed to map tunnel to domain. Output:${RESET_BOLD}${RESET}\n$ROUTE_OUTPUT"
  fi

# Step 4: Run the cloudflared tunnel in the background
# This exposes the local n8n service to the public via the custom domain

echo -e "$(get_timestamp) INF ${CYAN}[✔]${RESET} ${YELLOW}🚀 ${BOLD}Running cloudflared tunnel in the background.${RESET_BOLD}${RESET}"
cloudflared tunnel run $TUNNEL_NAME &
CF_PID=$!

sleep 3

# Step 5: Print status and access information
N8N_LOCAL_URL="http://localhost:5678"
echo -e "$(get_timestamp) INF ${CYAN}[✔]${RESET} ${YELLOW}✅ ${BOLD}n8n is running at $N8N_LOCAL_URL${RESET_BOLD}${RESET}"
echo -e "$(get_timestamp) INF ${CYAN}[✔]${RESET} ${YELLOW}🌐 ${BOLD}External access URL: https://$DOMAIN_NAME${RESET_BOLD}${RESET}"
echo -e "$(get_timestamp) INF ${CYAN}[✔]${RESET} ${GRAY}💡 ${BOLD}Press Ctrl+C to stop the tunnel and clean up.${RESET_BOLD}${RESET}"

# Step 6: Wait indefinitely until interrupted
while true; do
  sleep 60
done

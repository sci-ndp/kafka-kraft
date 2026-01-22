#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CLEAN_DATA=false
CLEAN_ALL=false

usage() {
    cat << EOF
${GREEN}Kafka KRaft Cluster Shutdown${NC}

Usage: $0 [OPTIONS]

${YELLOW}Options:${NC}
  --clean           Remove Kafka data (topics, offsets, etc.)
  --clean-all       Remove all generated files (data, certs, .env, credentials)
  -h, --help        Show this help message

${YELLOW}Examples:${NC}
  # Stop the cluster (keep data)
  $0

  # Stop and remove Kafka data
  $0 --clean

  # Stop and remove everything (fresh start)
  $0 --clean-all
EOF
    exit 0
}

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)
            CLEAN_DATA=true
            shift
            ;;
        --clean-all)
            CLEAN_ALL=true
            CLEAN_DATA=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Check for Docker or Podman
COMPOSE_CMD=""
if command -v docker &> /dev/null && docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
elif command -v podman &> /dev/null && podman compose version &> /dev/null; then
    COMPOSE_CMD="podman compose"
else
    echo -e "${RED}Docker Compose or Podman Compose is required but not found${NC}"
    exit 1
fi

log "Stopping Kafka cluster..."

# Stop all possible compose files
$COMPOSE_CMD -f docker-compose.generated.yml down 2>/dev/null || true
$COMPOSE_CMD -f docker-compose.yml down 2>/dev/null || true
$COMPOSE_CMD -f docker-compose.multi.yml down 2>/dev/null || true

success "Kafka containers stopped"

if [[ "$CLEAN_DATA" == "true" ]]; then
    log "Removing Kafka data..."
    rm -rf "$SCRIPT_DIR/data"
    success "Kafka data removed"
fi

if [[ "$CLEAN_ALL" == "true" ]]; then
    log "Removing generated files..."
    rm -f "$SCRIPT_DIR/docker-compose.generated.yml"
    rm -f "$SCRIPT_DIR/.env"
    rm -f "$SCRIPT_DIR/.kafka-credentials"

    # Only remove certs if it's a directory (not a symlink)
    if [[ -d "$SCRIPT_DIR/certs" && ! -L "$SCRIPT_DIR/certs" ]]; then
        rm -rf "$SCRIPT_DIR/certs"
        success "Certificates removed"
    fi

    success "Generated files removed"
fi

echo ""
success "Kafka cluster shutdown complete"

if [[ "$CLEAN_ALL" == "true" ]]; then
    echo ""
    echo "To start fresh, run: ./kafka-start.sh --generate-passwords"
fi

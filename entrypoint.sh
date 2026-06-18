#!/bin/bash
set -e

# ===========================================
# Odoo.sh Local Enhanced Entrypoint Script
# ===========================================

# Enable debug mode if requested
if [ "${DEBUG:-0}" = "1" ]; then
    set -x
    echo "[ENTRYPOINT] Debug mode enabled"
fi

echo "[ENTRYPOINT] Starting Odoo container initialization..."
echo "[ENTRYPOINT] Project: erick"
echo "[ENTRYPOINT] Odoo Version: 18.0"
echo "[ENTRYPOINT] Environment: ${ODOO_ENV:-development}"

# ===========================================
# Environment Variables and Configuration
# ===========================================

# Set PostgreSQL connection variables
: ${HOST:=${DB_PORT_5432_TCP_ADDR:='postgres'}}
: ${PORT:=${DB_PORT_5432_TCP_PORT:=5432}}
: ${USER:=${DB_ENV_POSTGRES_USER:=${POSTGRES_USER:='odoo'}}}
: ${PASSWORD:=${DB_ENV_POSTGRES_PASSWORD:=${POSTGRES_PASSWORD:='odoo'}}}
: ${DB_NAME:=${POSTGRES_DB:='erick'}}

echo "[ENTRYPOINT] Database configuration:"
echo "[ENTRYPOINT]   Host: $HOST"
echo "[ENTRYPOINT]   Port: $PORT"
echo "[ENTRYPOINT]   User: $USER"
echo "[ENTRYPOINT]   Database: $DB_NAME"

# ===========================================
# Utility Functions
# ===========================================

# Function to wait for PostgreSQL
wait_for_postgres() {
    echo "[ENTRYPOINT] Waiting for PostgreSQL to be ready..."
    local retries=60
    until pg_isready -h "$HOST" -p "$PORT" -U "$USER" -d "$DB_NAME" >/dev/null 2>&1; do
        retries=$((retries - 1))
        if [ $retries -eq 0 ]; then
            echo "[ENTRYPOINT] ERROR: PostgreSQL is not ready after 60 attempts"
            exit 1
        fi
        echo "[ENTRYPOINT] PostgreSQL is not ready yet, waiting... ($retries attempts left)"
        sleep 1
    done
    echo "[ENTRYPOINT] PostgreSQL is ready!"
}

# Function to install system packages
install_system_packages() {
    if [ -f /tmp/system-packages.txt ] && [ -s /tmp/system-packages.txt ]; then
        echo "[ENTRYPOINT] Installing additional system packages..."
        apt-get update -qq
        while IFS= read -r package; do
            [ -z "$package" ] || [ "${package:0:1}" = "#" ] && continue
            echo "[ENTRYPOINT] Installing system package: $package"
            apt-get install -y "$package"
        done < /tmp/system-packages.txt
        apt-get clean
        rm -rf /var/lib/apt/lists/*
    fi
}

# Function to install Python packages
install_python_packages() {
    local requirements_files=(
        "/tmp/requirements.txt"
        "/etc/odoo/requirements.txt"
        "/mnt/extra-addons/requirements.txt"
        "/mnt/custom-addons/requirements.txt"
    )
    
    for req_file in "${requirements_files[@]}"; do
        if [ -f "$req_file" ] && [ -s "$req_file" ]; then
            echo "[ENTRYPOINT] Installing Python packages from: $req_file"
            pip3 install --no-cache-dir -r "$req_file" --progress-bar off --break-system-packages
        fi
    done
}

# Function to setup logging
setup_logging() {
    echo "[ENTRYPOINT] Setting up logging configuration..."
    
    # Create log directory
    mkdir -p /var/log/odoo 2>/dev/null || true
    chown odoo:odoo /var/log/odoo 2>/dev/null || true
    
    # Install and configure logrotate (only if we have permissions)
    if command -v apt-get >/dev/null 2>&1 && [ -w /var/lib/apt/lists ]; then
        if ! dpkg -l | grep -q logrotate; then
            echo "[ENTRYPOINT] Installing logrotate..."
            apt-get update -qq && apt-get install -y logrotate 2>/dev/null || {
                echo "[ENTRYPOINT] Warning: Could not install logrotate (permission issue)"
            }
        fi
    else
        echo "[ENTRYPOINT] Skipping logrotate installation (no permissions)"
    fi
    
    if [ -f /etc/odoo/logrotate ] && [ -w /etc/logrotate.d ]; then
        cp /etc/odoo/logrotate /etc/logrotate.d/odoo
        echo "[ENTRYPOINT] Logrotate configuration installed"
    fi
    
    # Start cron for logrotate
    service cron start > /dev/null 2>&1 || true
}

# Function to setup custom addons
setup_addons() {
    echo "[ENTRYPOINT] Setting up custom addons..."
    
    # Create addon directories
    mkdir -p /mnt/custom-addons /mnt/extra-addons
    
    # Set correct ownership
    chown -R odoo:odoo /mnt/custom-addons /mnt/extra-addons
    
    # Install addon dependencies if available
    for addon_dir in /mnt/custom-addons /mnt/extra-addons; do
        if [ -f "$addon_dir/requirements.txt" ]; then
            echo "[ENTRYPOINT] Installing addon dependencies from: $addon_dir/requirements.txt"
            pip3 install --no-cache-dir -r "$addon_dir/requirements.txt" --progress-bar off --break-system-packages
        fi
    done
}

# Function to initialize database
init_database() {
    if [ "${INIT_DB:-0}" = "1" ]; then
        echo "[ENTRYPOINT] Initializing database..."
        
        # Check if database already exists and has data
        local table_count
        table_count=$(psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public'" 2>/dev/null || echo "0")
        
        if [ "$table_count" -eq "0" ]; then
            echo "[ENTRYPOINT] Database is empty, initializing with base modules..."
            odoo -d "$DB_NAME" -i base --without-demo=all --stop-after-init --no-http
        else
            echo "[ENTRYPOINT] Database already initialized ($table_count tables found)"
        fi
    fi
}

# ===========================================
# Main Initialization
# ===========================================

echo "[ENTRYPOINT] Running initialization steps..."

# Install additional packages
install_system_packages
install_python_packages

# Setup environment
setup_logging
setup_addons

# Refresh font cache so fontconfig picks up /etc/fonts/local.conf and installed fonts
if command -v fc-cache >/dev/null 2>&1; then
    echo "[ENTRYPOINT] Refreshing font cache (fc-cache)..."
    fc-cache -f -v || true
else
    echo "[ENTRYPOINT] fc-cache not found; fontconfig may not refresh automatically"
fi

# Wait for database
wait_for_postgres

# Initialize database if requested
init_database

# ===========================================
# Database Connection Arguments
# ===========================================

DB_ARGS=()
function check_config() {
    param="$1"
    value="$2"
    if grep -q -E "^\s*\b${param}\b\s*=" "${ODOO_RC:-/etc/odoo/odoo.conf}" 2>/dev/null; then       
        value=$(grep -E "^\s*\b${param}\b\s*=" "${ODOO_RC:-/etc/odoo/odoo.conf}" | cut -d '=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/["\n\r]//g')
    fi
    DB_ARGS+=("--${param}")
    DB_ARGS+=("${value}")
}

check_config "db_host" "$HOST"
check_config "db_port" "$PORT"
check_config "db_user" "$USER"
check_config "db_password" "$PASSWORD"

# ===========================================
# Health Check Setup
# ===========================================

# Create health check script in accessible location
mkdir -p /tmp/health 2>/dev/null || true
cat > /tmp/health/health-check.sh << 'EOF' || true
#!/bin/bash
# Simple health check for Odoo
curl -f -s http://localhost:8069/web/health > /dev/null 2>&1
EOF
chmod +x /tmp/health/health-check.sh 2>/dev/null || true

# ===========================================
# Start Odoo
# ===========================================

echo "[ENTRYPOINT] Initialization complete, starting Odoo..."
echo "[ENTRYPOINT] Command: $*"
echo "[ENTRYPOINT] DB Args: ${DB_ARGS[*]}"

# Handle different startup scenarios
case "$1" in
    -- | odoo)
        shift
        if [[ "$1" == "scaffold" ]]; then
            echo "[ENTRYPOINT] Running Odoo scaffold command"
            exec odoo "$@"
        else
            echo "[ENTRYPOINT] Starting Odoo server"
            exec odoo "$@" "${DB_ARGS[@]}"
        fi
        ;;
    -*)
        echo "[ENTRYPOINT] Starting Odoo with custom flags"
        exec odoo "$@" "${DB_ARGS[@]}"
        ;;
    *)
        echo "[ENTRYPOINT] Running custom command: $*"
        exec "$@"
esac

echo "[ENTRYPOINT] ERROR: Failed to start Odoo"
exit 1

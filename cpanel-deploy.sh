#!/bin/bash
# cpanel-deploy.sh - A script to create domains in cPanel and deploy Docker containers

# Exit on any error
set -e

# Load environment variables from .env file if it exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Required environment variables
# CPANEL_USERNAME - cPanel username
# CPANEL_PASSWORD - cPanel password or API token
# CPANEL_DOMAIN - Main cPanel domain 
# CPANEL_API_URL - cPanel API URL (e.g., https://example.com:2083)
# DOCKER_IMAGE - Docker image to deploy

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to create a domain/subdomain in cPanel
create_cpanel_domain() {
    local domain=$1
    local is_subdomain=$2
    
    log "Creating domain in cPanel: $domain"
    
    if [ "$is_subdomain" = true ]; then
        # Extract the subdomain part
        subdomain=$(echo "$domain" | cut -d. -f1)
        parent_domain=$(echo "$domain" | cut -d. -f2-)
        
        # Create subdomain using cPanel API
        curl -s -k "${CPANEL_API_URL}/json-api/cpanel" \
          -H "Authorization: Basic $(echo -n ${CPANEL_USERNAME}:${CPANEL_PASSWORD} | base64)" \
          -d "cpanel_jsonapi_module=SubDomain&cpanel_jsonapi_func=addsubdomain&cpanel_jsonapi_apiversion=2&domain=${subdomain}&rootdomain=${parent_domain}&dir=public_html/${domain}"
    else
        # Create addon domain using cPanel API
        curl -s -k "${CPANEL_API_URL}/json-api/cpanel" \
          -H "Authorization: Basic $(echo -n ${CPANEL_USERNAME}:${CPANEL_PASSWORD} | base64)" \
          -d "cpanel_jsonapi_module=AddonDomain&cpanel_jsonapi_func=addaddondomain&cpanel_jsonapi_apiversion=2&domain=${domain}&dir=public_html/${domain}&subdomain=${domain//./_}"
    fi
    
    log "Domain creation completed"
}

# Function to setup Nginx configuration for the domain
setup_nginx() {
    local domain=$1
    local container_port=$2
    
    log "Setting up Nginx configuration for $domain"
    
    # Create Nginx configuration file
    cat > "/etc/nginx/conf.d/${domain}.conf" << EOF
server {
    listen 80;
    server_name ${domain};
    
    access_log /var/log/nginx/${domain}_access.log;
    error_log /var/log/nginx/${domain}_error.log;
    
    location / {
        proxy_pass http://localhost:${container_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Additional security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";
}
EOF
    
    # Test Nginx configuration
    nginx -t
    
    # Reload Nginx configuration
    systemctl reload nginx
    
    log "Nginx configuration completed"
}

# Function to deploy Docker container
deploy_docker() {
    local container_name=$1
    local domain=$2
    local port=$3
    
    log "Deploying Docker container for $domain"
    
    # Remove existing container if it exists
    if docker ps -a | grep -q "$container_name"; then
        log "Removing existing container: $container_name"
        docker stop "$container_name" 2>/dev/null || true
        docker rm "$container_name" 2>/dev/null || true
    fi
    
    # Pull the latest image
    log "Pulling Docker image: $DOCKER_IMAGE"
    docker pull "$DOCKER_IMAGE"
    
    # Run the container
    log "Starting container on port $port"
    docker run -d \
        --name "$container_name" \
        --restart unless-stopped \
        -p "$port:80" \
        -e "VIRTUAL_HOST=$domain" \
        -e "DOMAIN=$domain" \
        "$DOCKER_IMAGE"
    
    # Check if the container is running
    if docker ps | grep -q "$container_name"; then
        log "Container successfully started"
    else
        log "Failed to start container"
        docker logs "$container_name"
        exit 1
    fi
}

# Function to find an available port
find_available_port() {
    local start_port=8080
    local end_port=9000
    
    for port in $(seq $start_port $end_port); do
        if ! netstat -tuln | grep -q ":$port "; then
            echo $port
            return 0
        fi
    done
    
    log "No available ports found in range $start_port-$end_port"
    exit 1
}

# Main function
main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain)
                DOMAIN="$2"
                shift 2
                ;;
            --subdomain)
                SUBDOMAIN="$2"
                shift 2
                ;;
            --name)
                PROJECT_NAME="$2"
                shift 2
                ;;
            --credits)
                CREDITS="$2"
                shift 2
                ;;
            *)
                log "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Validate required parameters
    if [ -z "$DOMAIN" ]; then
        log "Missing required parameter: --domain"
        exit 1
    fi
    
    if [ -z "$PROJECT_NAME" ]; then
        log "Missing required parameter: --name"
        exit 1
    fi
    
    # Determine the full domain name
    if [ -n "$SUBDOMAIN" ]; then
        FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"
        IS_SUBDOMAIN=true
    else
        FULL_DOMAIN="${DOMAIN}"
        IS_SUBDOMAIN=false
    fi
    
    # Create a sanitized container name
    CONTAINER_NAME=$(echo "${PROJECT_NAME}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr '.' '-')
    
    # Find an available port
    PORT=$(find_available_port)
    
    # Create the domain in cPanel
    create_cpanel_domain "$FULL_DOMAIN" "$IS_SUBDOMAIN"
    
    # Deploy the Docker container
    deploy_docker "$CONTAINER_NAME" "$FULL_DOMAIN" "$PORT"
    
    # Setup Nginx as reverse proxy
    setup_nginx "$FULL_DOMAIN" "$PORT"
    
    # Save deployment information
    DEPLOYMENT_DIR="/home/${CPANEL_USERNAME}/deployments"
    mkdir -p "$DEPLOYMENT_DIR"
    
    cat > "${DEPLOYMENT_DIR}/${CONTAINER_NAME}.info" << EOF
Project Name: ${PROJECT_NAME}
Domain: ${FULL_DOMAIN}
Container: ${CONTAINER_NAME}
Port: ${PORT}
Docker Image: ${DOCKER_IMAGE}
Deployed At: $(date)
Credits: ${CREDITS}
EOF
    
    log "Deployment completed successfully"
    log "Website is now available at: http://${FULL_DOMAIN}"
}

# Execute main function with all arguments
main "$@"
#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Vault arguments — use password file if available, otherwise prompt
VAULT_ARGS=""
if [ -f .vault_pass ]; then
    VAULT_ARGS="--vault-password-file .vault_pass"
else
    VAULT_ARGS="--ask-vault-pass"
fi

usage() {
    echo "Usage: $0 {vagrant|infra|cloud|all|stop|start|destroy|vault-setup}"
    echo ""
    echo "  vagrant      - Deploy locally using Vagrant + VirtualBox"
    echo "  infra        - Provision cloud VM with Terraform"
    echo "  cloud        - Deploy app to cloud VM with Ansible"
    echo "  all          - Terraform + Ansible in one shot"
    echo "  stop         - Stop EC2 instance (saves money, keeps data)"
    echo "  start        - Start a stopped EC2 instance"
    echo "  destroy      - Tear down deployment"
    echo "  vault-setup  - Encrypt secrets with Ansible Vault"
    exit 1
}

check_deps() {
    for cmd in "$@"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}Error: '$cmd' is not installed.${NC}"
            exit 1
        fi
    done
}

# Helper: get Terraform output value
tf_output() {
    cd terraform && terraform output -raw "$1" 2>/dev/null && cd ..
}

# Run Ansible with appropriate inventory and vault args
run_ansible() {
    local inventory="$1"
    local configured_domain
    configured_domain=$(grep -oP '^server_name:\s*"?\K[^"\s]+' group_vars/all/vars.yml 2>/dev/null || true)
    local extra=""
    # If server_name in vars.yml is an IP or empty, pass detected IP
    if [[ -z "$configured_domain" || "$configured_domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local server_ip
        server_ip=$(grep -oP '^\d+\.\d+\.\d+\.\d+' "$inventory" | head -1)
        if [ -n "$server_ip" ]; then
            extra="--extra-vars server_name=$server_ip"
        fi
    fi
    ansible-playbook -i "$inventory" playbook.yml $extra $VAULT_ARGS
}

case "${1:-}" in
    vagrant)
        check_deps vagrant ansible-playbook
        if [ ! -f .vault_pass ]; then
            echo -e "${YELLOW}Warning: .vault_pass not found.${NC}"
            echo "  echo 'your-vault-password' > .vault_pass && chmod 600 .vault_pass"
            echo "  Then encrypt vault: ./deploy.sh vault-setup"
            exit 1
        fi
        echo -e "${GREEN}==> Starting Vagrant VM and provisioning...${NC}"
        vagrant up --provision
        echo ""
        echo -e "${GREEN}==> Deployment complete!${NC}"
        echo "    WordPress:  https://192.168.56.10"
        echo "    phpMyAdmin: https://192.168.56.10/phpmyadmin/"
        echo "    WP Admin:   https://192.168.56.10/wp-admin/"
        ;;
    infra)
        check_deps terraform
        if [ ! -f terraform/terraform.tfvars ]; then
            echo -e "${RED}Error: terraform/terraform.tfvars not found.${NC}"
            echo "  cp terraform/terraform.tfvars.example terraform/terraform.tfvars"
            echo "  Then edit terraform.tfvars with your AWS settings."
            exit 1
        fi
        echo -e "${GREEN}==> Provisioning cloud infrastructure...${NC}"
        cd terraform
        terraform init
        terraform apply
        cd ..
        echo ""
        echo -e "${GREEN}==> Infrastructure provisioned!${NC}"
        echo "    Inventory written to inventories/cloud.ini"
        cd terraform && terraform output && cd ..
        ;;
    cloud)
        check_deps ansible-playbook
        if [ ! -f inventories/cloud.ini ]; then
            echo -e "${RED}Error: inventories/cloud.ini not found.${NC}"
            echo "  Run './deploy.sh infra' first, or create it manually."
            exit 1
        fi
        echo -e "${GREEN}==> Deploying to cloud VPS...${NC}"
        run_ansible inventories/cloud.ini
        SERVER_IP=$(grep -oP '^\d+\.\d+\.\d+\.\d+' inventories/cloud.ini | head -1)
        DISPLAY_HOST=$(grep -oP '^server_name:\s*"?\K[^"\s]+' group_vars/all/vars.yml 2>/dev/null || echo "$SERVER_IP")
        echo ""
        echo -e "${GREEN}==> Deployment complete!${NC}"
        echo "    WordPress:  https://$DISPLAY_HOST"
        echo "    phpMyAdmin: https://$DISPLAY_HOST/phpmyadmin/"
        echo "    WP Admin:   https://$DISPLAY_HOST/wp-admin/"
        ;;
    all)
        check_deps terraform ansible-playbook
        echo -e "${GREEN}==> Step 1/2: Provisioning infrastructure...${NC}"
        $0 infra
        echo ""
        echo -e "${GREEN}==> Step 2/2: Deploying application...${NC}"
        # Wait for SSH to be ready on the new instance
        SERVER_IP=$(grep -oP '^\d+\.\d+\.\d+\.\d+' inventories/cloud.ini | head -1)
        echo "    Waiting for SSH on $SERVER_IP..."
        for i in $(seq 1 30); do
            if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -i "$(grep -oP 'ansible_ssh_private_key_file=\K\S+' inventories/cloud.ini)" ubuntu@"$SERVER_IP" true 2>/dev/null; then
                break
            fi
            sleep 5
        done
        $0 cloud
        ;;
    stop)
        check_deps aws
        if [ ! -d terraform/.terraform ]; then
            echo -e "${RED}Error: Terraform not initialized. Run './deploy.sh infra' first.${NC}"
            exit 1
        fi
        INSTANCE_ID=$(cd terraform && terraform output -raw instance_id 2>/dev/null) || true
        REGION=$(cd terraform && terraform output -raw aws_region 2>/dev/null) || true
        if [ -z "$INSTANCE_ID" ]; then
            echo -e "${RED}Error: Could not get instance ID from Terraform state.${NC}"
            exit 1
        fi
        # Check current state
        STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
            --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)
        if [ "$STATE" = "stopped" ]; then
            echo -e "${YELLOW}Instance $INSTANCE_ID is already stopped.${NC}"
            exit 0
        fi
        if [ "$STATE" != "running" ]; then
            echo -e "${RED}Instance is in state '$STATE', cannot stop.${NC}"
            exit 1
        fi
        echo -e "${GREEN}==> Stopping EC2 instance $INSTANCE_ID...${NC}"
        aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
        echo "    Waiting for instance to stop..."
        aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" --region "$REGION"
        echo ""
        echo -e "${GREEN}==> Instance stopped!${NC}"
        echo "    - Compute charges:  STOPPED (no cost)"
        echo "    - Storage charges:  ~\$1.60/month (20GB EBS)"
        echo "    - Elastic IP:       ~\$3.60/month (while instance is stopped)"
        echo ""
        echo "    To start it back:   ./deploy.sh start"
        ;;
    start)
        check_deps aws
        if [ ! -d terraform/.terraform ]; then
            echo -e "${RED}Error: Terraform not initialized. Run './deploy.sh infra' first.${NC}"
            exit 1
        fi
        INSTANCE_ID=$(cd terraform && terraform output -raw instance_id 2>/dev/null) || true
        REGION=$(cd terraform && terraform output -raw aws_region 2>/dev/null) || true
        if [ -z "$INSTANCE_ID" ]; then
            echo -e "${RED}Error: Could not get instance ID from Terraform state.${NC}"
            exit 1
        fi
        # Check current state
        STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
            --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)
        if [ "$STATE" = "running" ]; then
            echo -e "${YELLOW}Instance $INSTANCE_ID is already running.${NC}"
            exit 0
        fi
        if [ "$STATE" != "stopped" ]; then
            echo -e "${RED}Instance is in state '$STATE', cannot start.${NC}"
            exit 1
        fi
        echo -e "${GREEN}==> Starting EC2 instance $INSTANCE_ID...${NC}"
        aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
        echo "    Waiting for instance to start..."
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
        # Get the Elastic IP (stays the same)
        SERVER_IP=$(grep -oP '^\d+\.\d+\.\d+\.\d+' inventories/cloud.ini | head -1)
        DISPLAY_HOST=$(grep -oP '^server_name:\s*"?\K[^"\s]+' group_vars/all/vars.yml 2>/dev/null || echo "$SERVER_IP")
        # Wait for SSH to be ready
        echo "    Waiting for SSH on $SERVER_IP..."
        for i in $(seq 1 30); do
            if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -i "$(grep -oP 'ansible_ssh_private_key_file=\K\S+' inventories/cloud.ini)" ubuntu@"$SERVER_IP" true 2>/dev/null; then
                break
            fi
            sleep 5
        done
        echo ""
        echo -e "${GREEN}==> Instance started!${NC}"
        echo "    WordPress:  https://$DISPLAY_HOST"
        echo "    phpMyAdmin: https://$DISPLAY_HOST/phpmyadmin/"
        echo "    WP Admin:   https://$DISPLAY_HOST/wp-admin/"
        echo ""
        echo "    Docker containers auto-restart (restart: always)."
        echo "    No need to re-deploy unless you changed configuration."
        ;;
    destroy)
        echo -e "${YELLOW}What do you want to destroy?${NC}"
        echo "  1) vagrant    - Destroy local Vagrant VM"
        echo "  2) cloud      - Stop stack on cloud VPS (keep VM)"
        echo "  3) infra      - Destroy cloud VM with Terraform"
        read -rp "Choose [1/2/3]: " choice
        case "$choice" in
            1)
                check_deps vagrant
                echo -e "${GREEN}==> Destroying Vagrant VM...${NC}"
                vagrant destroy -f
                echo -e "${GREEN}==> Vagrant VM destroyed.${NC}"
                ;;
            2)
                check_deps ansible-playbook
                if [ ! -f inventories/cloud.ini ]; then
                    echo -e "${RED}Error: inventories/cloud.ini not found.${NC}"
                    exit 1
                fi
                echo -e "${GREEN}==> Stopping stack on cloud VPS...${NC}"
                ansible -i inventories/cloud.ini web -m shell \
                    -a "cd /opt/cloud-1 && docker compose down -v" \
                    --become $VAULT_ARGS
                echo -e "${GREEN}==> Cloud stack stopped and volumes removed.${NC}"
                ;;
            3)
                check_deps terraform
                echo -e "${GREEN}==> Destroying cloud infrastructure...${NC}"
                cd terraform
                terraform destroy
                cd ..
                rm -f inventories/cloud.ini
                echo -e "${GREEN}==> Infrastructure destroyed.${NC}"
                ;;
            *)
                echo -e "${RED}Invalid choice.${NC}"
                exit 1
                ;;
        esac
        ;;
    vault-setup)
        check_deps ansible-vault
        if ansible-vault view group_vars/all/vault.yml $VAULT_ARGS > /dev/null 2>&1; then
            echo -e "${YELLOW}vault.yml is already encrypted.${NC}"
            echo "  To edit: ansible-vault edit group_vars/all/vault.yml $VAULT_ARGS"
            exit 0
        fi
        ansible-vault encrypt group_vars/all/vault.yml $VAULT_ARGS
        echo -e "${GREEN}==> group_vars/all/vault.yml encrypted successfully!${NC}"
        ;;
    *)
        usage
        ;;
esac

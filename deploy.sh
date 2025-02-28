#!/bin/bash
set -e

# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Check for jq which is required
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed. Please install jq first.${NC}"
    echo "On macOS: brew install jq"
    echo "On Ubuntu/Debian: sudo apt-get install jq"
    echo "On RHEL/CentOS: sudo yum install jq"
    exit 1
fi

# Check for AWS CLI
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is required but not installed. Please install AWS CLI first.${NC}"
    echo "Visit: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

# Check for kubectl
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl is required but not installed. Please install kubectl first.${NC}"
    echo "Visit: https://kubernetes.io/docs/tasks/tools/"
    exit 1
fi

echo -e "${GREEN}Welcome to iperf3 Kubernetes Cluster Deployment${NC}"
echo "This script will deploy an iperf3 benchmark cluster on AWS EKS"

# Check for config file
if [ ! -f "config.json" ]; then
    echo -e "${YELLOW}config.json not found. Creating from template...${NC}"
    cp config.json.template config.json
    echo -e "${YELLOW}Please edit config.json with your AWS and cluster settings and run this script again.${NC}"
    exit 0
fi

# Load configuration
echo -e "${GREEN}Loading configuration from config.json...${NC}"
CONFIG=$(cat config.json)

# Extract AWS configuration
AWS_REGION=$(echo $CONFIG | jq -r '.aws.region')
CLUSTER_NAME=$(echo $CONFIG | jq -r '.aws.cluster_name')
VPC_ID=$(echo $CONFIG | jq -r '.aws.vpc_id')
SUBNET_IDS=$(echo $CONFIG | jq -r '.aws.subnet_ids | join(",")')
CLUSTER_VERSION=$(echo $CONFIG | jq -r '.aws.cluster_version')
NODE_INSTANCE_TYPE=$(echo $CONFIG | jq -r '.aws.node_instance_type')
NODE_MIN_SIZE=$(echo $CONFIG | jq -r '.aws.node_min_size')
NODE_MAX_SIZE=$(echo $CONFIG | jq -r '.aws.node_max_size')

# Extract Kubernetes configuration
NAMESPACE=$(echo $CONFIG | jq -r '.kubernetes.namespace')

# Extract PostgreSQL configuration
POSTGRES_VERSION=$(echo $CONFIG | jq -r '.postgres.version')
PG_DB=$(echo $CONFIG | jq -r '.postgres.db_name')
PG_USER=$(echo $CONFIG | jq -r '.postgres.user')
PG_PASSWORD=$(echo $CONFIG | jq -r '.postgres.password')
POSTGRES_PASSWORD_BASE64=$(echo -n $PG_PASSWORD | base64)

# Extract Docker configuration
DOCKER_REGISTRY=$(echo $CONFIG | jq -r '.docker.registry')

# Extract iperf3 configuration
IPERF3_SCHEDULE=$(echo $CONFIG | jq -r '.iperf3.schedule')
IPERF3_SERVER_IPS=$(echo $CONFIG | jq -r '.iperf3.server_ips | join(",")')

# Prompt user before starting
echo -e "${YELLOW}You are about to deploy an iperf3 benchmark cluster with the following settings:${NC}"
echo "AWS Region: $AWS_REGION"
echo "Cluster Name: $CLUSTER_NAME"
echo "Namespace: $NAMESPACE"

read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}Deployment cancelled.${NC}"
    exit 1
fi

# Check AWS authentication
echo -e "${GREEN}Checking AWS authentication...${NC}"
aws sts get-caller-identity > /dev/null 2>&1 || { echo -e "${RED}AWS authentication failed. Please run 'aws configure' first.${NC}"; exit 1; }

# If VPC ID is empty or subnets are empty, offer to create them
if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "null" ] || [ "$SUBNET_IDS" == "" ] || [ "$SUBNET_IDS" == "null" ]; then
    echo -e "${YELLOW}VPC ID or subnet IDs not specified in config.json.${NC}"
    read -p "Do you want to create a new VPC with public subnets? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Creating new VPC and subnets...${NC}"
        # Create VPC with 3 public subnets
        VPC_CREATION=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --region $AWS_REGION)
        VPC_ID=$(echo $VPC_CREATION | jq -r '.Vpc.VpcId')
        
        # Enable DNS support and hostnames
        aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support "{\"Value\":true}" --region $AWS_REGION
        aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames "{\"Value\":true}" --region $AWS_REGION
        
        # Tag the VPC
        aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=$CLUSTER_NAME-vpc --region $AWS_REGION
        
        # Create an Internet Gateway
        IGW_ID=$(aws ec2 create-internet-gateway --region $AWS_REGION | jq -r '.InternetGateway.InternetGatewayId')
        aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $AWS_REGION
        
        # Create subnets in different AZs
        AZS=($(aws ec2 describe-availability-zones --region $AWS_REGION | jq -r '.AvailabilityZones[0:3].ZoneName'))
        SUBNET_IDS=""
        
        for i in {0..2}; do
            SUBNET_CREATION=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.$i.0/24 --availability-zone ${AZS[$i]} --region $AWS_REGION)
            SUBNET_ID=$(echo $SUBNET_CREATION | jq -r '.Subnet.SubnetId')
            
            # Enable auto-assign public IP
            aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID --map-public-ip-on-launch --region $AWS_REGION
            
            # Tag the subnet
            aws ec2 create-tags --resources $SUBNET_ID --tags Key=Name,Value=$CLUSTER_NAME-subnet-$i --region $AWS_REGION
            
            # Add to comma-separated list
            if [ -z "$SUBNET_IDS" ]; then
                SUBNET_IDS="$SUBNET_ID"
            else
                SUBNET_IDS="$SUBNET_IDS,$SUBNET_ID"
            fi
        done
        
        # Create route table and add route to Internet Gateway
        RTB_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --region $AWS_REGION | jq -r '.RouteTable.RouteTableId')
        aws ec2 create-route --route-table-id $RTB_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID --region $AWS_REGION
        
        # Associate route table with subnets
        for SUBNET in ${SUBNET_IDS//,/ }; do
            aws ec2 associate-route-table --route-table-id $RTB_ID --subnet-id $SUBNET --region $AWS_REGION
        done
        
        # Update config.json with new VPC and subnet IDs
        CONFIG=$(echo $CONFIG | jq --arg vpc "$VPC_ID" '.aws.vpc_id = $vpc')
        SUBNET_ARRAY=$(echo $SUBNET_IDS | sed 's/,/","/g')
        SUBNET_ARRAY="[\"$SUBNET_ARRAY\"]"
        CONFIG=$(echo $CONFIG | jq --argjson subnets "$SUBNET_ARRAY" '.aws.subnet_ids = $subnets')
        echo $CONFIG > config.json
        
        echo -e "${GREEN}VPC $VPC_ID created with subnets $SUBNET_IDS${NC}"
    else
        echo -e "${RED}VPC ID and subnet IDs are required. Please update config.json with your VPC and subnet details.${NC}"
        exit 1
    fi
fi

# Deploy EKS cluster using CloudFormation
echo -e "${GREEN}Deploying EKS cluster using CloudFormation...${NC}"
SUBNET_ARRAY=$(echo ${SUBNET_IDS//,/ } | xargs -n1 | jq -R . | jq -s .)

aws cloudformation deploy \
    --template-file cloudformation/eks-cluster.yaml \
    --stack-name $CLUSTER_NAME \
    --parameter-overrides \
        ClusterName=$CLUSTER_NAME \
        ClusterVersion=$CLUSTER_VERSION \
        VpcId=$VPC_ID \
        SubnetIds=$SUBNET_ARRAY \
        NodeInstanceType=$NODE_INSTANCE_TYPE \
        NodeAutoScalingGroupMinSize=$NODE_MIN_SIZE \
        NodeAutoScalingGroupMaxSize=$NODE_MAX_SIZE \
        NodeGroupName=$CLUSTER_NAME-nodes \
    --capabilities CAPABILITY_IAM \
    --region $AWS_REGION

# Wait for cluster to be ready
echo -e "${GREEN}Waiting for EKS cluster to be ready...${NC}"
aws eks wait cluster-active --name $CLUSTER_NAME --region $AWS_REGION

# Update kubeconfig for the new cluster
echo -e "${GREEN}Updating kubeconfig...${NC}"
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

# Wait for nodes to be ready
echo -e "${GREEN}Waiting for nodes to be ready...${NC}"
kubectl wait --for=condition=ready nodes --all --timeout=300s

# If server IPs are not specified, get them from the nodes
if [ -z "$IPERF3_SERVER_IPS" ] || [ "$IPERF3_SERVER_IPS" == "null" ]; then
    echo -e "${YELLOW}Server IPs not specified in config.json. Using node IPs...${NC}"
    NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
    IPERF3_SERVER_IPS=$(echo $NODE_IPS | tr ' ' ',')
    
    # Update config.json with node IPs
    SERVER_IP_ARRAY=$(echo $IPERF3_SERVER_IPS | sed 's/,/","/g')
    SERVER_IP_ARRAY="[\"$SERVER_IP_ARRAY\"]"
    CONFIG=$(echo $CONFIG | jq --argjson ips "$SERVER_IP_ARRAY" '.iperf3.server_ips = $ips')
    echo $CONFIG > config.json
    
    echo -e "${GREEN}Using node IPs as server IPs: $IPERF3_SERVER_IPS${NC}"
fi

# Create temporary directory for rendered templates
TEMP_DIR=$(mktemp -d)

# Process and apply Kubernetes manifests with variables substituted
echo -e "${GREEN}Applying Kubernetes manifests...${NC}"

# Process each YAML file
for file in k8s/*.yaml; do
    filename=$(basename "$file")
    # Skip postgres-init-config.yaml as it will be applied separately
    if [ "$filename" != "postgres-init-config.yaml" ]; then
        sed -e "s/\${NAMESPACE}/$NAMESPACE/g" \
            -e "s/\${POSTGRES_VERSION}/$POSTGRES_VERSION/g" \
            -e "s/\${PG_DB}/$PG_DB/g" \
            -e "s/\${PG_USER}/$PG_USER/g" \
            -e "s/\${POSTGRES_PASSWORD_BASE64}/$POSTGRES_PASSWORD_BASE64/g" \
            -e "s/\${DOCKER_REGISTRY}/$DOCKER_REGISTRY/g" \
            -e "s/\${IPERF3_SCHEDULE}/$IPERF3_SCHEDULE/g" \
            -e "s/\${IPERF3_SERVER_IPS}/$IPERF3_SERVER_IPS/g" \
            "$file" > "$TEMP_DIR/$filename"
    fi
done

# Apply namespace first
kubectl apply -f "$TEMP_DIR/namespace.yaml"

# Apply secrets
kubectl apply -f "$TEMP_DIR/secrets.yaml"

# Process postgres-init-config.yaml manually to escape SQL
cat << EOF > "$TEMP_DIR/postgres-init-config.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init-scripts
  namespace: $NAMESPACE
data:
  init.sql: |
    CREATE TABLE IF NOT EXISTS throughput_data (
      id SERIAL PRIMARY KEY,
      server VARCHAR(50) NOT NULL,
      timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      json_output TEXT NOT NULL
    );
EOF

# Apply remaining resources
kubectl apply -f "$TEMP_DIR"

# Clean up temporary directory
rm -rf "$TEMP_DIR"

echo -e "${GREEN}Deployment complete!${NC}"
echo ""
echo -e "${YELLOW}To view iperf3 server pods:${NC}"
echo "kubectl get pods -n $NAMESPACE -l app=iperf3-server"
echo ""
echo -e "${YELLOW}To view iperf3 client jobs:${NC}"
echo "kubectl get jobs -n $NAMESPACE"
echo ""
echo -e "${YELLOW}To view PostgreSQL database:${NC}"
echo "kubectl port-forward svc/postgres -n $NAMESPACE 5432:5432"
echo "Then connect to PostgreSQL with:"
echo "psql -h localhost -U $PG_USER -d $PG_DB"
echo ""
echo -e "${YELLOW}To delete the deployment:${NC}"
echo "./cleanup.sh"
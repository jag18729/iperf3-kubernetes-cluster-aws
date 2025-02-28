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

echo -e "${YELLOW}Warning: This script will delete your EKS cluster and all associated resources.${NC}"
read -p "Are you sure you want to continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Cleanup cancelled.${NC}"
    exit 0
fi

# Load configuration
if [ ! -f "config.json" ]; then
    echo -e "${RED}config.json not found. Cannot continue with cleanup.${NC}"
    exit 1
fi

CONFIG=$(cat config.json)
CLUSTER_NAME=$(echo $CONFIG | jq -r '.aws.cluster_name')
AWS_REGION=$(echo $CONFIG | jq -r '.aws.region')
VPC_ID=$(echo $CONFIG | jq -r '.aws.vpc_id')

# Verify AWS authentication
echo -e "${GREEN}Checking AWS authentication...${NC}"
aws sts get-caller-identity > /dev/null 2>&1 || { echo -e "${RED}AWS authentication failed. Please run 'aws configure' first.${NC}"; exit 1; }

# Delete CloudFormation stack
echo -e "${GREEN}Deleting CloudFormation stack...${NC}"
aws cloudformation delete-stack --stack-name $CLUSTER_NAME --region $AWS_REGION

echo -e "${GREEN}Waiting for stack deletion to complete...${NC}"
aws cloudformation wait stack-delete-complete --stack-name $CLUSTER_NAME --region $AWS_REGION

# Clean up any leftover resources
if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "null" ]; then
    read -p "Do you want to delete the VPC and all its resources? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Cleaning up VPC resources...${NC}"
        
        # Get Internet Gateway ID
        IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --region $AWS_REGION | jq -r '.InternetGateways[0].InternetGatewayId')
        
        if [ ! -z "$IGW_ID" ] && [ "$IGW_ID" != "null" ]; then
            echo -e "${GREEN}Detaching and deleting Internet Gateway...${NC}"
            aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $AWS_REGION
            aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $AWS_REGION
        fi
        
        # Delete subnets
        SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --region $AWS_REGION | jq -r '.Subnets[].SubnetId')
        for subnet in $SUBNETS; do
            echo -e "${GREEN}Deleting subnet $subnet...${NC}"
            aws ec2 delete-subnet --subnet-id $subnet --region $AWS_REGION
        done
        
        # Delete route tables
        ROUTE_TABLES=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --region $AWS_REGION | jq -r '.RouteTables[].RouteTableId')
        for rtb in $ROUTE_TABLES; do
            # Skip the main route table
            is_main=$(aws ec2 describe-route-tables --route-table-ids $rtb --region $AWS_REGION | jq -r '.RouteTables[0].Associations[].Main')
            if [ "$is_main" != "true" ]; then
                echo -e "${GREEN}Deleting route table $rtb...${NC}"
                aws ec2 delete-route-table --route-table-id $rtb --region $AWS_REGION
            fi
        done
        
        # Delete security groups
        SECURITY_GROUPS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --region $AWS_REGION | jq -r '.SecurityGroups[].GroupId')
        for sg in $SECURITY_GROUPS; do
            # Skip the default security group
            is_default=$(aws ec2 describe-security-groups --group-ids $sg --region $AWS_REGION | jq -r '.SecurityGroups[0].GroupName')
            if [ "$is_default" != "default" ]; then
                echo -e "${GREEN}Deleting security group $sg...${NC}"
                aws ec2 delete-security-group --group-id $sg --region $AWS_REGION
            fi
        done
        
        # Delete VPC
        echo -e "${GREEN}Deleting VPC $VPC_ID...${NC}"
        aws ec2 delete-vpc --vpc-id $VPC_ID --region $AWS_REGION
        
        # Update config.json to remove VPC and subnet IDs
        CONFIG=$(echo $CONFIG | jq '.aws.vpc_id = ""')
        CONFIG=$(echo $CONFIG | jq '.aws.subnet_ids = []')
        echo $CONFIG > config.json
    fi
fi

echo -e "${GREEN}Cleanup complete!${NC}"
echo "You can now run ./deploy.sh again to redeploy the cluster."
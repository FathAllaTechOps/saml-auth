#!/bin/bash

show_help() {
  echo "Usage: eks [options]"
  echo ""
  echo "Example: eks "
  echo
  echo "Options:"
  echo "  --help    Display this help message"
  echo
  echo "This script allows you to select AWS profiles and regions to update EKS cluster configurations."
  echo "It fetches AWS profiles from ~/.aws/credentials and lists EKS clusters in the selected region."
  echo "You can then choose clusters to update their public access CIDRs to include your current external IP address."
}

# Check if --help is passed as an argument
if [[ "$1" == "--help" ]]; then
  show_help
  exit 0
fi

# Function to fetch AWS profiles from ~/.aws/credentials
get_aws_profiles() {
  if [ -f ~/.aws/credentials ]; then
    grep '^\[.*\]$' ~/.aws/credentials | tr -d '[]'
  else
    echo ""
  fi
}

# Prompt user to choose AWS region
echo "Choose the AWS region where the cluster exists:"
options=("eu-west-1" "eu-central-1")
select aws_region in "${options[@]}"; do
  for option in "${options[@]}"; do
    if [[ "$aws_region" == "$option" ]]; then
      valid=true
      break
    fi
  done
  if [ "$valid" ]; then
    break
  else
    echo "Invalid selection. Please choose a valid AWS region."
  fi
done

# Fetch and display AWS profiles
aws_profiles=$(get_aws_profiles)

if [ -z "$aws_profiles" ]; then
  echo "No AWS CLI profiles found in ~/.aws/credentials. Exiting."
  exit 1
fi

echo "Available AWS CLI profiles:"
select aws_profile in $aws_profiles; do
  if [ -n "$aws_profile" ]; then
    break
  else
    echo "Invalid selection. Please choose a valid AWS CLI profile."
  fi
done

# Fetch the list of clusters in the specified region
clusters=$(aws eks list-clusters --region "$aws_region" --profile "$aws_profile" | jq -r '.clusters[]')

if [ -z "$clusters" ]; then
  echo "No EKS clusters found in region '$aws_region'. Exiting."
  exit 1
fi

# Display the list of clusters and prompt user to choose clusters
echo "Available EKS clusters in region '$aws_region':"
i=1
for cluster in $clusters; do
  echo "$i) $cluster"
  ((i++))
done

read -r -p "Enter the numbers of the clusters you want to update, separated by commas (e.g., 1,2): " selected_clusters

# Confirmation prompt
read -r -p "Are you sure you want to whitelist your IP to the selected clusters in region '$aws_region'? (y/n): " confirm
if [ "$confirm" != "y" ]; then
  echo "Operation canceled. Exiting."
  exit 1
fi

# Fetch external IP address
externalIp=$(dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | tr -d '"')  # Remove double quotes
newCidr="$externalIp/32"

# Update each selected cluster
IFS=',' read -ra cluster_indices <<< "$selected_clusters"
for index in "${cluster_indices[@]}"; do
  cluster_name=$(echo "$clusters" | sed -n "${index}p")
  if [ -n "$cluster_name" ]; then
    # Fetch current publicAccessCidrs
    currentCidrs=$(aws eks describe-cluster --name "$cluster_name" --region "$aws_region" --profile "$aws_profile" | jq -r '.cluster.resourcesVpcConfig.publicAccessCidrs | join(",")')

    # Append the new CIDR
    updatedCidrs="$currentCidrs,$newCidr"

    # Update the EKS cluster with the updated publicAccessCidrs
    aws eks update-cluster-config --name "$cluster_name" --region "$aws_region" --resources-vpc-config publicAccessCidrs="$updatedCidrs" --profile "$aws_profile" > /dev/null 2>&1

    echo "EKS cluster '$cluster_name' in region '$aws_region' has been updated with the external IP address."
  else
    echo "Invalid cluster selection: $index. Skipping."
  fi
done

echo "Operation completed."

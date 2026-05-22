#!/bin/bash

show_help() {
  echo "Usage: eks [options]"
  echo ""
  echo "Options:"
  echo "  --help    Display this help message"
  echo ""
  echo "This script whitelists your current external IP on EKS cluster publicAccessCidrs."
  echo "Supports both AWS SSO profiles (~/.aws/config) and static credential profiles (~/.aws/credentials)."
}

if [[ "$1" == "--help" ]]; then
  show_help
  exit 0
fi

# Collect SSO profiles from ~/.aws/config (tagged with [sso])
get_sso_profiles() {
  if [ ! -f ~/.aws/config ]; then return; fi
  grep '^\[profile ' ~/.aws/config | sed 's/^\[profile //;s/\]$//' | while read -r profile; do
    if grep -A 20 "^\[profile $profile\]" ~/.aws/config | grep -q 'sso_start_url'; then
      echo "$profile [sso]"
    fi
  done
}

# Collect static credential profiles from ~/.aws/credentials (tagged with [creds])
get_credential_profiles() {
  if [ ! -f ~/.aws/credentials ]; then return; fi
  grep '^\[.*\]$' ~/.aws/credentials | tr -d '[]' | while read -r profile; do
    echo "$profile [creds]"
  done
}

# Ensure active session — SSO profiles trigger browser login, credential profiles just validate
ensure_session() {
  local profile=$1
  local profile_type=$2
  if ! aws sts get-caller-identity --profile "$profile" > /dev/null 2>&1; then
    if [[ "$profile_type" == "sso" ]]; then
      echo "SSO session expired for '$profile'. Launching browser login..."
      aws sso login --profile "$profile"
    else
      echo "Error: credentials invalid or expired for profile '$profile'."
      echo "Re-authenticate via saml2aws or rotate your access keys."
      exit 1
    fi
  fi
}

# Prompt user to choose AWS region
echo "Choose the AWS region where the cluster exists:"
options=("eu-west-1" "eu-central-1" "us-east-2" "us-east-1")
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

# Build combined profile list from both sources
mapfile -t all_profiles < <({ get_sso_profiles; get_credential_profiles; })

if [ ${#all_profiles[@]} -eq 0 ]; then
  echo "No AWS profiles found in ~/.aws/config or ~/.aws/credentials. Exiting."
  exit 1
fi

echo "Available AWS profiles:"
select entry in "${all_profiles[@]}"; do
  if [ -n "$entry" ]; then
    break
  else
    echo "Invalid selection. Please choose a valid profile."
  fi
done

# Parse profile name and type from the tagged entry (e.g. "my-profile [sso]")
aws_profile="${entry% \[*\]}"
if [[ "$entry" == *"[sso]"* ]]; then
  profile_type="sso"
else
  profile_type="creds"
fi

ensure_session "$aws_profile" "$profile_type"

# Fetch clusters
clusters=$(aws eks list-clusters --region "$aws_region" --profile "$aws_profile" | jq -r '.clusters[]')

if [ -z "$clusters" ]; then
  echo "No EKS clusters found in region '$aws_region'. Exiting."
  exit 1
fi

echo "Available EKS clusters in region '$aws_region':"
i=1
for cluster in $clusters; do
  echo "$i) $cluster"
  ((i++))
done

read -r -p "Enter the numbers of the clusters you want to update, separated by commas (e.g., 1,2): " selected_clusters

read -r -p "Are you sure you want to whitelist your IP to the selected clusters in region '$aws_region'? (y/n): " confirm
if [ "$confirm" != "y" ]; then
  echo "Operation canceled. Exiting."
  exit 1
fi

# Fetch external IP
externalIp=$(dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | tr -d '"')
newCidr="$externalIp/32"

IFS=',' read -ra cluster_indices <<< "$selected_clusters"
for index in "${cluster_indices[@]}"; do
  cluster_name=$(echo "$clusters" | sed -n "${index}p")
  if [ -n "$cluster_name" ]; then
    currentCidrs=$(aws eks describe-cluster --name "$cluster_name" --region "$aws_region" --profile "$aws_profile" \
      | jq -r '.cluster.resourcesVpcConfig.publicAccessCidrs | join(",")')

    if echo "$currentCidrs" | grep -q "$newCidr"; then
      echo "IP $newCidr already whitelisted on '$cluster_name'. Skipping."
      continue
    fi

    updatedCidrs="$currentCidrs,$newCidr"
    aws eks update-cluster-config --name "$cluster_name" --region "$aws_region" \
      --resources-vpc-config publicAccessCidrs="$updatedCidrs" --profile "$aws_profile" > /dev/null 2>&1

    echo "Updated '$cluster_name' in '$aws_region' with IP $newCidr."
  else
    echo "Invalid cluster selection: $index. Skipping."
  fi
done

echo "Operation completed."

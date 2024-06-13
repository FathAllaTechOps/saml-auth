#!/bin/bash

CONFIG_DIR="$HOME/.saml-auth"
CONFIG_FILE="$CONFIG_DIR/saml_profile.config"
VERSION="v4.0.0"

# Function to load profiles from the configuration file
load_profiles() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        profiles=()
    fi
}

# Function to save profiles to the configuration file
save_profiles() {
    mkdir -p "$CONFIG_DIR"
    echo "profiles=(" > "$CONFIG_FILE"
    for profile in "${profiles[@]}"; do
        echo "    \"$profile\"" >> "$CONFIG_FILE"
    done
    echo ")" >> "$CONFIG_FILE"
}

# Function to handle the 'config' command
config_profiles() {
    echo "Enter the AWS profiles (one per line). Enter an empty line to finish:"
    profiles=()
    while :; do
        read -p "Profile: " profile
        [ -z "$profile" ] && break
        profiles+=("$profile")
    done
    save_profiles
    echo "Profiles saved to $CONFIG_FILE"
}

# Function to display help information
display_help() {
    cat <<EOF
Usage: saml [OPTION]
Options:
  config             Configure the AWS profiles to use for SAML authentication.
  --help             Display this help message and exit.

Example:
  saml config
  saml
  
Description:
  This script helps to authenticate to multiple AWS accounts using SAML.
  It allows you to configure AWS profiles and update Kubeconfig for EKS clusters.

  Commands:
    saml config      Prompts the user to input AWS profiles and saves them to a
                     configuration file (HOME/.saml-auth/saml_profile.config).
    saml --help      Displays this help message.

  Usage Example:
    1. Configure profiles:
       saml config

    2. Authenticate and update kubeconfig for EKS clusters:
       saml

EOF
}

# Function to display version information
display_version() {
    echo "SAML version $VERSION"
}

# Handle the '--help' argument
if [ "$1" == "--help" ]; then
    display_help
    exit 0
fi

# Handle the '--version' argument
if [ "$1" == "--version" ]; then
    display_version
    exit 0
fi

# Handle the 'config' command
if [ "$1" == "config" ]; then
    config_profiles
    exit 0
fi

# Load profiles from the configuration file
load_profiles

if [ ${#profiles[@]} -eq 0 ]; then
    echo "No profiles found. Please run 'saml config' to configure profiles."
    exit 1
fi

# Define your email and password
read -p "Enter the email: " email
read -p "Enter the password: " password

# Display the list of profiles and prompt user to choose profiles
echo "Available AWS Accounts:"
i=1
for profile in "${profiles[@]}"; do
    echo "$i) $profile"
    ((i++))
done

read -p "Enter the numbers of the profiles you want to use, separated by commas (e.g., 1,3,5): " selected_profiles

# Convert the selection to an array of indices
IFS=',' read -ra profile_indices <<< "$selected_profiles"

# Function to replace profile in ~/.saml2aws and log in
login_with_profile() {
    local profile=$1
    echo "Replacing aws_profile with '$profile' in ~/.saml2aws configuration file"
    sed -i '' '/aws_profile/d' ~/.saml2aws
    echo "aws_profile             = $profile" >> ~/.saml2aws

    echo "Logging in with profile '$profile'"

    # Execute saml2aws login using the current profile
    saml2aws login --force --username=$email --password=$password --skip-prompt

    echo "---------------------------------------------"
}

# Loop through each selected profile and log in
for index in "${profile_indices[@]}"; do
    profile=${profiles[$((index-1))]}
    if [ -n "$profile" ]; then
        login_with_profile "$profile"
    else
        echo "Invalid profile selection: $index. Skipping."
    fi
done

echo "Completed replacing all selected profiles and logging in."

# Clear the password variable after use
unset password

regions=(
    "eu-west-1"
    "eu-central-1"
)

# Iterate over each region and selected profile
for region in "${regions[@]}"; do
    for index in "${profile_indices[@]}"; do
        profile=${profiles[$((index-1))]}
        if [ -n "$profile" ]; then
            # Get a list of available EKS clusters for the current profile and region
            clusters=$(aws eks list-clusters --output text --profile "$profile" --region "$region" | awk '{print $2}')
            
            # Iterate over each cluster
            while read -r cluster; do
                # Execute the update-kubeconfig command
                aws eks update-kubeconfig --region "$region" --name "$cluster" --profile "$profile"
                
                # Check if the command was successful
                if [ $? -eq 0 ]; then
                    echo "Updated kubeconfig for cluster $cluster in region $region using profile $profile"
                else
                    echo "Failed to update kubeconfig for cluster $cluster in region $region using profile $profile"
                fi
            done <<< "$clusters"
        fi
    done
done

# Add a note about Production Accounts as a banner
echo "############################################################"
echo "#                                                          #"
echo "#   Note: This step is only for Production Accounts as     #"
echo "#   Lower accounts are opened by default to 0.0.0.0/0.     #"
echo "#                                                          #"
echo "############################################################"

# Get the directory of the current script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Prompt the user to proceed with whitelisting IP to EKS clusters
read -p "Do you want to proceed with whitelisting your IP to EKS Clusters? (yes/no): " proceed

if [ "$proceed" == "yes" ]; then
    # Run the eks.sh script
    "$SCRIPT_DIR/eks.sh"
else
    echo "Whitelisting operation was canceled."
fi



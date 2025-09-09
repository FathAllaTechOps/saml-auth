#!/bin/bash

CONFIG_DIR="$HOME/.saml-auth"
CONFIG_FILE="$CONFIG_DIR/saml_profile.config"
VERSION="v8.0.0"
REGIONS=(
    "eu-west-1"
    "eu-central-1"
)

###########################################
############ HELPER FUNCTIONS #############
###########################################
is_number() {
    local input="$1"
    [[ "$input" =~ ^[0-9]+$ ]]
}

is_comma_separated_numbers() {
    local input="$1"
    [[ "$input" =~ ^[0-9]+(,[0-9]+)*$ ]]
}

is_valid_index() {
    local index="$1"
    local array_size="$2"
    if is_number "$index" && (( index >= 1 && index <= array_size )); then
        return 0
    else
        return 1
    fi
}

print_numbered_list() {
    local array_name=$1
    local header=$2

    echo "$header"
    local i=1
    eval "local arr=(\"\${${array_name}[@]}\")"
    # shellcheck disable=SC2154
    for item in "${arr[@]}"; do
        echo "$i) $item"
        ((i++))
    done
}

###########################################
############ MAIN FUNCTIONS ###############
###########################################

# Function to load profiles from the configuration file
load_profiles() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        profiles=()
    fi

    if [ ${#profiles[@]} -eq 0 ]; then
        echo "No profiles found. Please run 'saml config' to configure profiles."
        exit 1
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
        read -r -p "Profile: " profile
        [ -z "$profile" ] && break
        profiles+=("$profile")
    done
    save_profiles
    echo "Profiles saved to $CONFIG_FILE"
}

# Function to read saved credentials if they exist
read_credentials() {
    # Email
    if [ -z "$email" ]; then
        read -r -p "Enter the email: " email
    else
        echo "Email set to: $email"
        read -r -p "Press Enter to confirm or enter a new email: " new_email
        if [ -n "$new_email" ]; then
            email="$new_email"
        fi
    fi
    export SAML_EMAIL="$email"

    # Password
    if [ -z "$SAML_PASSWORD" ]; then
        read -s -r -p "Enter the password: " SAML_PASSWORD
        export SAML_PASSWORD
    fi
}

# Function to replace profile in ~/.saml2aws and log in
login_with_profile() {
    local profile=$1
    echo "Replacing aws_profile with '$profile' in ~/.saml2aws configuration file"
    sed -i '' '/aws_profile/d' ~/.saml2aws
    echo "aws_profile             = $profile" >> ~/.saml2aws

    echo "Logging in with profile '$profile'"

    read_credentials
    # Execute saml2aws login using the current profile
    saml2aws login --force --username="$SAML_EMAIL" --password="$SAML_PASSWORD" --skip-prompt

    echo "---------------------------------------------"
}

# Function to get array of all kubeconfig contexts
get_all_kubeconfig_contexts() {
    kubectl config get-contexts -o name
}

# Function to switch kubeconfig context based on selected profile and cluster
switch_context_from_profile() {
    local selected_profile="$1"

    if [ -z "$selected_profile" ]; then
        echo "No profile provided to switch_context function."
        return 1
    fi

    echo "Validating authentication for profile: $selected_profile"

    if ! aws sts get-caller-identity --profile "$selected_profile" > /dev/null 2>&1; then
        echo "❌ Failed to validate authentication for profile $selected_profile, Triggering 'saml login'."
        login_with_profile "$selected_profile"
    fi

    while true; do
        echo "Fetching EKS clusters for profile: $selected_profile"
        clusters=()
        for region in "${REGIONS[@]}"; do
            region_clusters=$(aws eks list-clusters --output text --profile "$selected_profile" --region "$region" | awk '{print $2}')
            
            while read -r cluster; do        
            if [ -n "$cluster" ]; then
                clusters+=("$cluster|$region")
            fi
            done <<< "$region_clusters"
        done

        if [ ${#clusters[@]} -eq 0 ]; then
            echo "No clusters found for profile $selected_profile."
            return 1
        fi

        echo "Available EKS Clusters:"
        i=1
        for entry in "${clusters[@]}"; do
            cluster_name="${entry%%|*}"
            cluster_region="${entry##*|}"
            echo "$i) $cluster_name (Region: $cluster_region)"
            ((i++))
        done

        read -r -p "Enter the number of the cluster you want to switch to: " cluster_index

        # Validate Input
        if ! is_number "$cluster_index"; then
            echo "Invalid input. Please enter a number."
            continue
        fi

        if ! is_valid_index "$cluster_index" "${#clusters[@]}"; then
            echo "Invalid selection. Please choose a number between 1 and ${#clusters[@]}."
            continue
        fi

        selected_entry="${clusters[$((cluster_index-1))]}"
        selected_cluster="${selected_entry%%|*}"
        selected_region="${selected_entry##*|}"

        if aws eks update-kubeconfig --region "$selected_region" --name "$selected_cluster" --profile "$selected_profile" --alias "$selected_cluster" > /dev/null 2>&1; then
            echo "✅ Switched kubeconfig context to cluster '$selected_cluster' in region '$selected_region' using profile '$selected_profile'"
            break
        else
            echo "❌ Failed to switch context."
        fi
    done
}

switch_context_from_kubeconfig() {
    local context="$1"
    if kubectl config use-context "$context" > /dev/null 2>&1; then
        echo "✅ Switched kubeconfig context to '$context'"
    else
        echo "❌ Failed to switch kubeconfig context to '$context'"
    fi
}

function update_kubeconfig() {
    local profile="$1"
    for region in "${REGIONS[@]}"; do
        # Get a list of available EKS clusters for the current profile and region
        aws eks list-clusters --output text --profile "$profile" --region "$region" | awk '{print $2}' | while read -r cluster; do
            if aws eks update-kubeconfig --region "$region" --name "$cluster" --profile "$profile" --alias "$cluster" > /dev/null 2>&1; then
                echo "✅ Updated kubeconfig for cluster $cluster in region $region using profile $profile"
            else
                echo "❌ Failed to update kubeconfig for cluster $cluster in region $region using profile $profile"
            fi
        done
    done
}

function whitelist_profiles() {
    # Add a note about Production Accounts as a banner
    echo "############################################################"
    echo "#                                                          #"
    echo "#   Note: This step is only for Production Accounts as     #"
    echo "#   Lower accounts are opened by default to 0.0.0.0/0.     #"
    echo "#                                                          #"
    echo "############################################################"

    # Prompt the user to proceed with whitelisting IP to EKS clusters
    read -r -p "Do you want to proceed with whitelisting your IP to EKS Clusters? (yes/no): " proceed

    if [ "$proceed" == "yes" ]; then
        # Run the eks.sh script
        "eks"
    else
        echo "Whitelisting operation was canceled."
    fi
}

# Function to display help information
display_help() {
    cat <<EOF
Usage: saml [OPTION]
Options:
  config             Configure the AWS profiles to use for SAML authentication.
  context            Switch the kubeconfig context based on selected profile.
  --help             Display this help message and exit.

Example:
  saml config
  saml context
  saml whitelist
  saml
  
Description:
  This script helps to authenticate to multiple AWS accounts using SAML.
  It allows you to configure AWS profiles and update Kubeconfig for EKS clusters.

  Note: When you run 'saml' or 'saml login', it will ask you for your email and password, in case this is not your first time to run the script, you can skip this by entering empty email and password,
  this is because after first login, the tool saml2aws will securly store your credentials on your machine using Keychain Access for MacOS or Keyring for Linux.

  Commands:
    saml config      Prompts the user to input AWS profiles and saves them to a
                     configuration file (HOME/.saml-auth/saml_profile.config).
    saml context     Prompts the user to input AWS profile to use to list all 
                     the EKS clusters and update the kubeconfig.
    saml --help      Displays this help message.

    saml whitelist   Whitelists your IP to EKS Clusters

  Usage Example:
    1. Configure profiles:
       saml config

    2. Switch context:
       saml context

    3. Whitelist IP to EKS Clusters:
       saml whitelist

    4. Authenticate and update kubeconfig for EKS clusters:
       saml

EOF
}

# Function to display version information
display_version() {
    echo "SAML version $VERSION"
}

# Command Arguments Handling
case "$1" in
    --config | -config | -c | config) config_profiles 
        exit 0 ;;
    --help | -help | -h | help) display_help 
        exit 0 ;;
    --version | -version | -v | version) display_version 
        exit 0 ;;
    --whitelist | -whitelist | -w | whitelist) whitelist_profiles 
        exit 0 ;;
esac

###########################################
################# MAIN ####################
###########################################

# Check if required packages are installed
for cmd in saml2aws aws kubectl fzf; do
    if ! command -v $cmd &> /dev/null; then
        echo "❌ Required command '$cmd' not found. Please install it."
        exit 1
    fi
done

# Read selected profiles from the user input
if [ "$1" == "context" ]; then
    ############ Handle Context Switching ################

    # shellcheck disable=SC2034
    actions=("Select context from current kubeconfig" "Select context from profile")
    print_numbered_list actions "Available actions:"
    read -r -p "Choose an option to select a context: " switch_context_action

    if [ "$switch_context_action" == "1" ]; then
        switch_context_profile=$(get_all_kubeconfig_contexts | fzf --prompt="Select kube context: ")
        switch_context_from_kubeconfig "$switch_context_profile"
    else
        # Load profiles from the configuration file
        load_profiles

        # Display the list of profiles and prompt user to choose profiles
        print_numbered_list profiles "Available AWS Accounts:"
        
        read -r -p "Enter the numbers of the profile you want to use (Only One): " switch_context_profile

        # Validate Input
        if ! is_number "$switch_context_profile"; then
            echo "Invalid input. Please enter a number."
            exit 1
        fi
        
        profile=${profiles[$((switch_context_profile-1))]}
        if [ -n "$profile" ]; then
            switch_context_from_profile "$profile"
        else
            echo "Invalid profile selection: $switch_context_profile."
            exit 1
        fi
    fi

else
    ############ Handle Login ################

    # Load profiles from the configuration file
    load_profiles

    # Display the list of profiles and prompt user to choose profiles
    print_numbered_list profiles "Available AWS Accounts:"

    read -r -p "Enter the numbers of the profiles you want to use, separated by commas (e.g., 1,3,5): " login_profiles

    # Validate Input
    if ! is_comma_separated_numbers "$login_profiles"; then
        echo "Invalid input. Please enter a comma seperated number."
        exit 1
    fi
    
    # Convert the selection to an array of indices
    IFS=',' read -ra profile_indices <<< "$login_profiles"

    # Loop through each selected profile and log in
    for index in "${profile_indices[@]}"; do
        profile=${profiles[$((index-1))]}
        if [ -n "$profile" ]; then
            login_with_profile "$profile"
            update_kubeconfig "$profile"
        else
            echo "Invalid profile selection: $index. Skipping."
        fi
    done
fi
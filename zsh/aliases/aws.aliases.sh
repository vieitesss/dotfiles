#!/usr/bin/env bash

prefapp() {
    # Check aws is installed
    if ! command -v aws >/dev/null 2>&1; then
        echo "[error] aws cli not found. Please install aws cli v2 from https://aws.amazon.com/cli/"
        return 1
    fi

    local profile="${1:-prefapp-admin}"
    echo -n "🔄 Logging in to AWS profile: $profile ..."
    if ! aws sso login --profile "$profile" >/dev/null 2>&1; then
        echo -e "\r[info] Login cancelled or failed"
        return 1
    fi

    echo -e "\r✅ Logged in to AWS SSO for profile $profile"
    echo -n "🔄 Exporting AWS credentials ..."
    local credentials_output
    if ! credentials_output=$(aws configure export-credentials --profile "$profile" --format env); then
        echo -e "\r❌ Failed to export credentials for profile $profile"
        return 1
    fi
    eval "$credentials_output"
    echo -e "\r✅ Exported AWS credentials for profile $profile"

    local cluster
    cluster=$(aws eks list-clusters --profile "$profile" --query "clusters[0]" --output text)
    if [[ -z "$cluster" || "$cluster" == "None" ]]; then
        echo -e "ℹ️ No EKS clusters found for profile $profile"
        echo -e "ℹ️ Set the EKS cluster manually using 'aws eks update-kubeconfig --name <cluster-name> --profile $profile'"
        return 1
    fi

    echo -e "✅ Loaded profile $profile credentials"
}

_prefapp_complete() {
    local -a profiles
    profiles=($(grep '^\[profile ' "$HOME/.aws/config" | sed -E 's/^\[profile ([^]]+)\]/\1/'))
    compadd "$@" -- $profiles
}

compdef _prefapp_complete prefapp

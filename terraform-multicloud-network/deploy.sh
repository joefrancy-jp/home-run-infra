#!/usr/bin/env bash
# Usage:   ./deploy.sh <resource> <aws|gcp|azure> <env> [plan|apply|destroy]
# Example: ./deploy.sh network aws dev plan
#
# <resource> is a folder inside environments/<env>/, currently network.
set -euo pipefail

RESOURCE="${1:-}"
CLOUD="${2:-}"
ENV="${3:-}"
ACTION="${4:-plan}"

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "Usage:   $0 <resource> <aws|gcp|azure> <env> [plan|apply|destroy]"
  echo "Example: $0 network aws dev plan"
  echo 'Environments: dev (shared Dev/QA), uat (on-demand load testing), prod'
  exit 1
}

case "$CLOUD" in
  aws|gcp|azure) ;;
  *) usage ;;
esac

if [[ ! "$ENV" =~ ^(dev|uat|prod)$ ]]; then
  echo "env must be dev, uat, or prod"
  usage
fi

case "$ACTION" in
  plan|apply|destroy) ;;
  *) usage ;;
esac

WORK_DIR="$ROOT_DIR/environments/$ENV/$RESOURCE/$CLOUD"
if [[ ! "$RESOURCE" =~ ^[a-z0-9-]+$ || ! -d "$WORK_DIR" ]]; then
  echo "Folder not found: environments/$ENV/$RESOURCE/$CLOUD"
  usage
fi

# State lives under a folder per resource, so network and compute never overwrite each other.
STATE_NAME="${RESOURCE}/${ENV}-home-run-${CLOUD}"

# S3 and Azure use "key" (a file path). GCS uses "prefix" (a folder path).
if [[ "$CLOUD" == "gcp" ]]; then
  BACKEND_ARG="prefix=${STATE_NAME}"
else
  BACKEND_ARG="key=${STATE_NAME}.tfstate"
fi

cd "$WORK_DIR"

echo ">> Resource: $RESOURCE | Cloud: $CLOUD | Env: $ENV | Action: $ACTION | State: $BACKEND_ARG"

# -reconfigure lets you switch between dev/prod in the same folder safely.
terraform init -input=false -reconfigure -backend-config="$BACKEND_ARG"

# terraform.tfvars in this folder is loaded automatically.
terraform "$ACTION" -var="env=$ENV"

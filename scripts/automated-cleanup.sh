#!/usr/bin/env bash
#
# Automated Cleanup for AWS EB Cross-Account IAM Test
# Deletes all resources from both AWS accounts + GitHub repo
#

set -euo pipefail

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   Automated Cleanup - AWS EB Cross-Account IAM Test           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Load credentials
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

if [ ! -f "$PROJECT_ROOT/.env" ]; then
    echo "❌ Error: .env file not found"
    exit 1
fi

source "$PROJECT_ROOT/.env"

# Helper functions
aws_account_a() {
    AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID_A" \
    AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY_A" \
    AWS_REGION="${AWS_REGION_A:-us-east-1}" \
    aws "$@"
}

aws_account_b() {
    AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID_B" \
    AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY_B" \
    AWS_REGION="${AWS_REGION_B:-us-east-1}" \
    aws "$@"
}

ACCOUNT_ID_A=$(aws_account_a sts get-caller-identity --query Account --output text)
ACCOUNT_ID_B=$(aws_account_b sts get-caller-identity --query Account --output text)

echo "Account A: $ACCOUNT_ID_A"
echo "Account B: $ACCOUNT_ID_B"
echo ""

#==============================================================================
# STAGE 1: Delete Elastic Beanstalk Environment (if exists)
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Stage 1: Delete Elastic Beanstalk Environment (Account A)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

ENV_NAME="test-cross-account-iam"

if aws_account_a elasticbeanstalk describe-environments \
    --environment-names "$ENV_NAME" \
    --query 'Environments[0].Status' 2>/dev/null | grep -qv "Terminated"; then

    echo "Terminating environment: $ENV_NAME"
    aws_account_a elasticbeanstalk terminate-environment \
        --environment-name "$ENV_NAME" 2>&1 | sed 's/^/  /'

    echo "  ⏳ Waiting for termination (this may take 5-10 minutes)..."
    aws_account_a elasticbeanstalk wait environment-terminated \
        --environment-names "$ENV_NAME" 2>/dev/null || true
    echo "  ✓ Environment terminated"
else
    echo "  ⚠️  Environment does not exist or already terminated"
fi

echo ""

#==============================================================================
# STAGE 2: Delete Application (Account A)
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Stage 2: Delete Elastic Beanstalk Application (Account A)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

APP_NAME="cross-account-iam-test"

if aws_account_a elasticbeanstalk describe-applications \
    --application-names "$APP_NAME" 2>/dev/null | grep -q "$APP_NAME"; then

    echo "Deleting application: $APP_NAME"
    aws_account_a elasticbeanstalk delete-application \
        --application-name "$APP_NAME" \
        --terminate-env-by-force 2>&1 | sed 's/^/  /' || true
    echo "  ✓ Application deleted"
else
    echo "  ⚠️  Application does not exist"
fi

echo ""

#==============================================================================
# STAGE 3: Delete GitHub Actions IAM Role (Account A)
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Stage 3: Delete GitHub Actions IAM Role (Account A)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

ROLE_NAME="github-actions-eb-test"

if aws_account_a iam get-role --role-name "$ROLE_NAME" 2>/dev/null; then
    echo "Deleting role: $ROLE_NAME"

    # Delete inline policies
    echo "  [1/2] Deleting inline policies"
    aws_account_a iam delete-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-name ElasticBeanstalkTestPolicy 2>/dev/null || true

    # Delete role
    echo "  [2/2] Deleting role"
    aws_account_a iam delete-role --role-name "$ROLE_NAME"
    echo "  ✓ Role deleted"
else
    echo "  ⚠️  Role does not exist"
fi

echo ""

#==============================================================================
# STAGE 4: Delete OIDC Provider (Account A)
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Stage 4: Delete OIDC Provider (Account A)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

OIDC_URL="token.actions.githubusercontent.com"

if OIDC_ARN=$(aws_account_a iam list-open-id-connect-providers \
    --query "OpenIDConnectProviderList[?contains(Arn, '$OIDC_URL')].Arn" \
    --output text 2>/dev/null) && [ -n "$OIDC_ARN" ]; then

    echo "Deleting OIDC provider: $OIDC_ARN"
    aws_account_a iam delete-open-id-connect-provider \
        --open-id-connect-provider-arn "$OIDC_ARN"
    echo "  ✓ OIDC provider deleted"
else
    echo "  ⚠️  OIDC provider does not exist"
fi

echo ""

#==============================================================================
# STAGE 5: Delete Victim IAM Roles (Account B)
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Stage 5: Delete Victim IAM Roles (Account B)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Delete instance profile
echo "[1/6] Removing role from instance profile"
aws_account_b iam remove-role-from-instance-profile \
    --instance-profile-name victim-powerful-role \
    --role-name victim-powerful-role 2>/dev/null || true

echo "[2/6] Deleting instance profile"
aws_account_b iam delete-instance-profile \
    --instance-profile-name victim-powerful-role 2>/dev/null || true

echo "[3/6] Detaching AdministratorAccess policy"
aws_account_b iam detach-role-policy \
    --role-name victim-powerful-role \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess 2>/dev/null || true

echo "[4/6] Deleting victim-powerful-role"
aws_account_b iam delete-role \
    --role-name victim-powerful-role 2>/dev/null || true

echo "[5/6] Detaching EB service policies"
aws_account_b iam detach-role-policy \
    --role-name victim-eb-service-role \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkService 2>/dev/null || true
aws_account_b iam detach-role-policy \
    --role-name victim-eb-service-role \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth 2>/dev/null || true

echo "[6/6] Deleting victim-eb-service-role"
aws_account_b iam delete-role \
    --role-name victim-eb-service-role 2>/dev/null || true

echo "  ✓ Victim roles deleted"
echo ""

#==============================================================================
# STAGE 6: Delete GitHub Repository
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Stage 6: Delete GitHub Repository"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

read -p "Delete GitHub repository anatexis-eb-test? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    gh repo delete anatexis-eb-test --yes 2>&1 | sed 's/^/  /' || echo "  ⚠️  Repository not found"
    echo "  ✓ Repository deleted"
else
    echo "  ⚠️  Skipped (keeping repository)"
fi

echo ""

#==============================================================================
# Summary
#==============================================================================

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    Cleanup Complete                            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "All test resources have been removed:"
echo ""
echo "Account A ($ACCOUNT_ID_A):"
echo "  ✓ Elastic Beanstalk environment terminated"
echo "  ✓ Application deleted"
echo "  ✓ GitHub Actions IAM role deleted"
echo "  ✓ OIDC provider deleted"
echo ""
echo "Account B ($ACCOUNT_ID_B):"
echo "  ✓ victim-powerful-role deleted"
echo "  ✓ victim-eb-service-role deleted"
echo ""
echo "You can now re-run the test with ./automated-setup.sh"
echo ""

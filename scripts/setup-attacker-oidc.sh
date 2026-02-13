#!/usr/bin/env bash
#
# Setup GitHub OIDC and IAM Role (Account A: 612470416133)
# Allows GitHub Actions to authenticate to AWS
#

set -euo pipefail

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   Setup GitHub OIDC (Account A)                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Load credentials for Account A
if [ -f "../../../.env" ]; then
    source "../../../.env"
fi

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID_A}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY_A}"
export AWS_REGION="${AWS_REGION_A:-us-east-1}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

if [ "$ACCOUNT_ID" != "612470416133" ]; then
    echo "❌ Error: Not authenticated as Account A (612470416133)"
    echo "   Current account: $ACCOUNT_ID"
    exit 1
fi

echo "✓ Authenticated as Account A: $ACCOUNT_ID"
echo ""

#==============================================================================
# Get GitHub Repository Information
#==============================================================================

echo "GitHub repository information:"
echo ""
read -p "Enter your GitHub username: " GITHUB_USER
read -p "Enter repository name [anatexis-eb-test]: " REPO_NAME
REPO_NAME=${REPO_NAME:-anatexis-eb-test}

REPO_FULL="${GITHUB_USER}/${REPO_NAME}"

echo ""
echo "Will configure OIDC for: $REPO_FULL"
echo ""

#==============================================================================
# Create OIDC Identity Provider
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Creating OIDC Identity Provider"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

OIDC_PROVIDER_URL="token.actions.githubusercontent.com"

# Check if OIDC provider already exists
if aws iam list-open-id-connect-providers | grep -q "$OIDC_PROVIDER_URL"; then
    echo "⚠️  OIDC provider already exists"
    OIDC_PROVIDER_ARN=$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?contains(Arn, '$OIDC_PROVIDER_URL')].Arn" --output text)
    echo "   ARN: $OIDC_PROVIDER_ARN"
else
    echo "Creating OIDC identity provider..."

    # Get GitHub's OIDC thumbprint
    THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

    OIDC_PROVIDER_ARN=$(aws iam create-open-id-connect-provider \
        --url "https://${OIDC_PROVIDER_URL}" \
        --client-id-list "sts.amazonaws.com" \
        --thumbprint-list "$THUMBPRINT" \
        --query 'OpenIDConnectProviderArn' \
        --output text)

    echo "✓ OIDC provider created"
    echo "   ARN: $OIDC_PROVIDER_ARN"
fi

echo ""

#==============================================================================
# Create IAM Role for GitHub Actions
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Creating IAM Role for GitHub Actions"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Create trust policy
cat > /tmp/github-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${REPO_FULL}:*"
        }
      }
    }
  ]
}
EOF

ROLE_NAME="github-actions-eb-test"

# Create role
if aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null; then
    echo "⚠️  Role $ROLE_NAME already exists"
    echo "   Updating trust policy..."

    aws iam update-assume-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-document file:///tmp/github-trust-policy.json

    echo "✓ Trust policy updated"
else
    echo "Creating role: $ROLE_NAME"

    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document file:///tmp/github-trust-policy.json \
        --description "GitHub Actions role for EB cross-account test"

    echo "✓ Role created"
fi

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

echo "   ARN: $ROLE_ARN"
echo ""

#==============================================================================
# Attach Permissions to Role
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Attaching Permissions"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Create inline policy for EB, S3, and IAM PassRole
cat > /tmp/eb-permissions.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticbeanstalk:*",
        "s3:*",
        "ec2:Describe*",
        "autoscaling:Describe*",
        "cloudformation:Describe*",
        "cloudformation:GetTemplate",
        "cloudformation:ListStackResources",
        "iam:PassRole",
        "iam:GetRole",
        "iam:ListInstanceProfiles"
      ],
      "Resource": "*"
    }
  ]
}
EOF

echo "Attaching inline policy: ElasticBeanstalkTestPolicy"
aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name ElasticBeanstalkTestPolicy \
    --policy-document file:///tmp/eb-permissions.json

echo "✓ Permissions attached"
echo ""

#==============================================================================
# Summary
#==============================================================================

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    Setup Complete                              ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "GitHub OIDC Configuration:"
echo ""
echo "1. OIDC Provider ARN:"
echo "   $OIDC_PROVIDER_ARN"
echo ""
echo "2. GitHub Actions Role ARN:"
echo "   $ROLE_ARN"
echo ""
echo "3. Allowed Repository:"
echo "   $REPO_FULL"
echo ""
echo "This role can now be assumed by GitHub Actions workflows in"
echo "the $REPO_FULL repository."
echo ""
echo "Next step: Update .github/workflows/test-cross-account-iam.yml"
echo "with the role ARN above, then push to GitHub."
echo ""

# Save configuration
cat > /tmp/github-oidc-config.txt << EOF
GITHUB_ROLE_ARN=$ROLE_ARN
GITHUB_REPO=$REPO_FULL
EOF

echo "Configuration saved to /tmp/github-oidc-config.txt"
echo ""
echo "To use in workflow, add this step:"
echo ""
echo "  - name: Configure AWS Credentials"
echo "    uses: aws-actions/configure-aws-credentials@v4"
echo "    with:"
echo "      role-to-assume: $ROLE_ARN"
echo "      aws-region: us-east-1"

#!/usr/bin/env bash
#
# Fully Automated Setup for AWS EB Cross-Account IAM Test
# Creates all resources in both AWS accounts + GitHub repo
#
# Usage: ./automated-setup.sh YOUR_GITHUB_USERNAME
#

set -euo pipefail

GITHUB_USER="${1:-}"
REPO_NAME="anatexis-eb-test"

if [ -z "$GITHUB_USER" ]; then
    echo "Usage: $0 YOUR_GITHUB_USERNAME"
    echo ""
    echo "Example: $0 yourusername"
    exit 1
fi

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   Automated AWS EB Cross-Account IAM Security Test Setup      ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "GitHub User: $GITHUB_USER"
echo "Repository: $REPO_NAME"
echo ""

# Load credentials from .env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

if [ ! -f "$PROJECT_ROOT/.env" ]; then
    echo "❌ Error: .env file not found at $PROJECT_ROOT/.env"
    echo "Expected: $PROJECT_ROOT/.env"
    echo "Current dir: $(pwd)"
    exit 1
fi

source "$PROJECT_ROOT/.env"

# Validate we have all required credentials
REQUIRED_VARS=(
    "AWS_ACCESS_KEY_ID_A"
    "AWS_SECRET_ACCESS_KEY_A"
    "AWS_ACCESS_KEY_ID_B"
    "AWS_SECRET_ACCESS_KEY_B"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "❌ Missing: $var in .env"
        exit 1
    fi
done

echo "✓ Credentials loaded from .env"
echo ""

# Set default regions
AWS_REGION_A="${AWS_REGION_A:-us-east-1}"
AWS_REGION_B="${AWS_REGION_B:-us-east-1}"

REPO_FULL="${GITHUB_USER}/${REPO_NAME}"

#==============================================================================
# Helper function to run AWS CLI with specific account credentials
#==============================================================================

aws_account_a() {
    AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID_A" \
    AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY_A" \
    AWS_REGION="$AWS_REGION_A" \
    aws "$@"
}

aws_account_b() {
    AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID_B" \
    AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY_B" \
    AWS_REGION="$AWS_REGION_B" \
    aws "$@"
}

#==============================================================================
# STAGE 1: Verify Account Access
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Stage 1: Verify AWS Account Access"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

ACCOUNT_ID_A=$(aws_account_a sts get-caller-identity --query Account --output text)
ACCOUNT_ID_B=$(aws_account_b sts get-caller-identity --query Account --output text)

echo "Account A (Attacker): $ACCOUNT_ID_A"
echo "Account B (Victim):   $ACCOUNT_ID_B"

if [ "$ACCOUNT_ID_A" == "$ACCOUNT_ID_B" ]; then
    echo "❌ Error: Both accounts are the same! Need 2 different AWS accounts."
    exit 1
fi

echo "✓ Two different AWS accounts verified"
echo ""

#==============================================================================
# STAGE 2: Create Victim IAM Roles (Account B)
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Stage 2: Create Victim IAM Roles (Account B)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# EC2 trust policy
cat > /tmp/ec2-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

# Create IAM role
echo "[1/6] Creating IAM role: victim-powerful-role"
if aws_account_b iam get-role --role-name victim-powerful-role 2>/dev/null; then
    echo "  ⚠️  Role exists, skipping"
else
    aws_account_b iam create-role \
        --role-name victim-powerful-role \
        --assume-role-policy-document file:///tmp/ec2-trust-policy.json \
        --description "Victim role for cross-account IAM test" >/dev/null
    echo "  ✓ Created"
fi

# Attach policy
echo "[2/6] Attaching AdministratorAccess policy"
aws_account_b iam attach-role-policy \
    --role-name victim-powerful-role \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess \
    2>/dev/null || true
echo "  ✓ Attached"

# Create instance profile
echo "[3/6] Creating instance profile"
if aws_account_b iam get-instance-profile --instance-profile-name victim-powerful-role 2>/dev/null; then
    echo "  ⚠️  Instance profile exists"
else
    aws_account_b iam create-instance-profile \
        --instance-profile-name victim-powerful-role >/dev/null
    echo "  ✓ Created"
fi

# Add role to instance profile
echo "[4/6] Adding role to instance profile"
aws_account_b iam add-role-to-instance-profile \
    --instance-profile-name victim-powerful-role \
    --role-name victim-powerful-role \
    2>/dev/null || echo "  ⚠️  Already added"
echo "  ✓ Done"

# EB service role trust policy
cat > /tmp/eb-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "elasticbeanstalk.amazonaws.com"},
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {"sts:ExternalId": "elasticbeanstalk"}
    }
  }]
}
EOF

# Create EB service role
echo "[5/6] Creating EB service role"
if aws_account_b iam get-role --role-name victim-eb-service-role 2>/dev/null; then
    echo "  ⚠️  Role exists"
else
    aws_account_b iam create-role \
        --role-name victim-eb-service-role \
        --assume-role-policy-document file:///tmp/eb-trust-policy.json \
        --description "Victim EB service role" >/dev/null
    echo "  ✓ Created"
fi

# Attach EB policies
echo "[6/6] Attaching EB service policies"
aws_account_b iam attach-role-policy \
    --role-name victim-eb-service-role \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkService \
    2>/dev/null || true
aws_account_b iam attach-role-policy \
    --role-name victim-eb-service-role \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth \
    2>/dev/null || true
echo "  ✓ Attached"

INSTANCE_PROFILE_ARN="arn:aws:iam::${ACCOUNT_ID_B}:instance-profile/victim-powerful-role"
SERVICE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID_B}:role/victim-eb-service-role"

echo ""
echo "✅ Victim roles created:"
echo "   Instance Profile: $INSTANCE_PROFILE_ARN"
echo "   Service Role:     $SERVICE_ROLE_ARN"
echo ""

#==============================================================================
# STAGE 3: Create GitHub OIDC Provider (Account A)
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Stage 3: Create GitHub OIDC Provider (Account A)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

OIDC_PROVIDER_URL="token.actions.githubusercontent.com"
THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

echo "[1/1] Creating OIDC provider"
if aws_account_a iam list-open-id-connect-providers | grep -q "$OIDC_PROVIDER_URL"; then
    echo "  ⚠️  OIDC provider exists"
    OIDC_PROVIDER_ARN=$(aws_account_a iam list-open-id-connect-providers \
        --query "OpenIDConnectProviderList[?contains(Arn, '$OIDC_PROVIDER_URL')].Arn" \
        --output text)
else
    OIDC_PROVIDER_ARN=$(aws_account_a iam create-open-id-connect-provider \
        --url "https://${OIDC_PROVIDER_URL}" \
        --client-id-list "sts.amazonaws.com" \
        --thumbprint-list "$THUMBPRINT" \
        --query 'OpenIDConnectProviderArn' \
        --output text)
    echo "  ✓ Created"
fi

echo "  ARN: $OIDC_PROVIDER_ARN"
echo ""

#==============================================================================
# STAGE 4: Create GitHub Actions IAM Role (Account A)
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Stage 4: Create GitHub Actions IAM Role (Account A)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

ROLE_NAME="github-actions-eb-test"

# Trust policy
cat > /tmp/github-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "${OIDC_PROVIDER_ARN}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:${REPO_FULL}:*"
      }
    }
  }]
}
EOF

echo "[1/2] Creating IAM role: $ROLE_NAME"
if aws_account_a iam get-role --role-name "$ROLE_NAME" 2>/dev/null; then
    echo "  ⚠️  Role exists, updating trust policy"
    aws_account_a iam update-assume-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-document file:///tmp/github-trust-policy.json
else
    aws_account_a iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document file:///tmp/github-trust-policy.json \
        --description "GitHub Actions role for EB test" >/dev/null
    echo "  ✓ Created"
fi

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID_A}:role/${ROLE_NAME}"

# Permissions policy
cat > /tmp/eb-permissions.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "elasticbeanstalk:*",
      "s3:*",
      "ec2:Describe*",
      "autoscaling:Describe*",
      "cloudformation:*",
      "iam:PassRole",
      "iam:GetRole",
      "iam:ListInstanceProfiles"
    ],
    "Resource": "*"
  }]
}
EOF

echo "[2/2] Attaching permissions policy"
aws_account_a iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name ElasticBeanstalkTestPolicy \
    --policy-document file:///tmp/eb-permissions.json
echo "  ✓ Attached"

echo ""
echo "✅ GitHub Actions role created:"
echo "   ARN: $ROLE_ARN"
echo ""

#==============================================================================
# STAGE 5: Create GitHub Repository
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Stage 5: Create GitHub Repository"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cd "$SCRIPT_DIR/.."

# Update workflow with correct role ARN
echo "[1/3] Updating workflow with role ARN"
sed -i.bak "s|role-to-assume:.*|role-to-assume: ${ROLE_ARN}|" .github/workflows/test-cross-account-iam.yml
rm -f .github/workflows/test-cross-account-iam.yml.bak
echo "  ✓ Updated"

# Update workflow with victim ARNs
echo "[2/3] Updating workflow with victim IAM ARNs"
sed -i.bak "s|arn:aws:iam::[0-9]*:instance-profile/victim-powerful-role|${INSTANCE_PROFILE_ARN}|" .github/workflows/test-cross-account-iam.yml
sed -i.bak "s|arn:aws:iam::[0-9]*:role/victim-eb-service-role|${SERVICE_ROLE_ARN}|" .github/workflows/test-cross-account-iam.yml
rm -f .github/workflows/test-cross-account-iam.yml.bak
echo "  ✓ Updated"

# Initialize git if needed
if [ ! -d .git ]; then
    echo "[3/3] Initializing git repository"
    git init
    git add .
    git commit -m "AWS EB cross-account IAM security test"
    echo "  ✓ Initialized"
fi

# Create GitHub repo
echo "[4/4] Creating GitHub repository: $REPO_FULL"
if gh repo view "$REPO_FULL" 2>/dev/null; then
    echo "  ⚠️  Repository already exists"
    echo "  Pushing updates..."
    git remote remove origin 2>/dev/null || true
    git remote add origin "https://github.com/${REPO_FULL}.git"
    git push -f origin main 2>&1 | sed 's/^/  /'
else
    gh repo create "$REPO_NAME" --public --source=. --remote=origin --push 2>&1 | sed 's/^/  /'
    echo "  ✓ Created"
fi

echo ""
echo "✅ Repository created: https://github.com/${REPO_FULL}"
echo ""

#==============================================================================
# STAGE 6: Summary & Next Steps
#==============================================================================

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    Setup Complete!                             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "All resources created:"
echo ""
echo "Account A (Attacker - $ACCOUNT_ID_A):"
echo "  ✓ OIDC Provider: $OIDC_PROVIDER_ARN"
echo "  ✓ GitHub Role:   $ROLE_ARN"
echo ""
echo "Account B (Victim - $ACCOUNT_ID_B):"
echo "  ✓ Instance Profile: $INSTANCE_PROFILE_ARN"
echo "  ✓ Service Role:     $SERVICE_ROLE_ARN"
echo ""
echo "GitHub Repository:"
echo "  ✓ URL: https://github.com/${REPO_FULL}"
echo "  ✓ Workflow: .github/workflows/test-cross-account-iam.yml"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Next Steps:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. Trigger the workflow:"
echo "   gh workflow run test-cross-account-iam.yml"
echo ""
echo "2. Watch the test run:"
echo "   gh run watch"
echo ""
echo "3. Or view in browser:"
echo "   gh repo view --web"
echo "   (Click Actions tab)"
echo ""
echo "The workflow will attempt to deploy an Elastic Beanstalk environment"
echo "using victim's IAM roles from Account B."
echo ""
echo "If deployment SUCCEEDS → VULNERABILITY FOUND! 🎉"
echo "If deployment FAILS → AWS properly validates same-account IAM ✅"
echo ""

# Save configuration
cat > /tmp/eb-test-config.txt << EOF
ACCOUNT_A=$ACCOUNT_ID_A
ACCOUNT_B=$ACCOUNT_ID_B
GITHUB_ROLE_ARN=$ROLE_ARN
INSTANCE_PROFILE_ARN=$INSTANCE_PROFILE_ARN
SERVICE_ROLE_ARN=$SERVICE_ROLE_ARN
GITHUB_REPO=$REPO_FULL
EOF

echo "Configuration saved to: /tmp/eb-test-config.txt"
echo ""

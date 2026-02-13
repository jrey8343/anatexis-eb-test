#!/usr/bin/env bash
#
# Setup Victim IAM Roles (Account B: 142531840183)
# Creates IAM roles that attacker will try to inject
#

set -euo pipefail

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   Setup Victim IAM Roles (Account B)                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Load credentials for Account B
if [ -f "../../../.env" ]; then
    source "../../../.env"
fi

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID_B}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY_B}"
export AWS_REGION="${AWS_REGION_B:-us-east-1}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

if [ "$ACCOUNT_ID" != "142531840183" ]; then
    echo "❌ Error: Not authenticated as Account B (142531840183)"
    echo "   Current account: $ACCOUNT_ID"
    exit 1
fi

echo "✓ Authenticated as Account B: $ACCOUNT_ID"
echo ""

#==============================================================================
# Create EC2 Instance Role with AdministratorAccess
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Creating IAM Instance Profile (victim-powerful-role)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Create trust policy for EC2
cat > /tmp/ec2-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create IAM role
if aws iam get-role --role-name victim-powerful-role 2>/dev/null; then
    echo "⚠️  Role victim-powerful-role already exists, skipping creation"
else
    echo "Creating IAM role: victim-powerful-role"
    aws iam create-role \
        --role-name victim-powerful-role \
        --assume-role-policy-document file:///tmp/ec2-trust-policy.json \
        --description "Victim role for cross-account IAM injection test"

    echo "✓ Role created"
fi

# Attach AdministratorAccess policy
echo "Attaching AdministratorAccess policy..."
aws iam attach-role-policy \
    --role-name victim-powerful-role \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess \
    2>/dev/null || echo "  (Policy already attached)"

echo "✓ Policy attached"

# Create instance profile
if aws iam get-instance-profile --instance-profile-name victim-powerful-role 2>/dev/null; then
    echo "⚠️  Instance profile already exists, skipping creation"
else
    echo "Creating instance profile..."
    aws iam create-instance-profile \
        --instance-profile-name victim-powerful-role

    echo "✓ Instance profile created"
fi

# Add role to instance profile
echo "Adding role to instance profile..."
aws iam add-role-to-instance-profile \
    --instance-profile-name victim-powerful-role \
    --role-name victim-powerful-role \
    2>/dev/null || echo "  (Role already added)"

echo "✓ Role added to instance profile"

INSTANCE_PROFILE_ARN="arn:aws:iam::${ACCOUNT_ID}:instance-profile/victim-powerful-role"

echo ""
echo "✅ Instance Profile ARN:"
echo "   $INSTANCE_PROFILE_ARN"
echo ""

#==============================================================================
# Create Elastic Beanstalk Service Role
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Creating Elastic Beanstalk Service Role"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Create trust policy for Elastic Beanstalk
cat > /tmp/eb-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "elasticbeanstalk.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "elasticbeanstalk"
        }
      }
    }
  ]
}
EOF

# Create service role
if aws iam get-role --role-name victim-eb-service-role 2>/dev/null; then
    echo "⚠️  Role victim-eb-service-role already exists, skipping creation"
else
    echo "Creating service role: victim-eb-service-role"
    aws iam create-role \
        --role-name victim-eb-service-role \
        --assume-role-policy-document file:///tmp/eb-trust-policy.json \
        --description "Victim EB service role for cross-account test"

    echo "✓ Service role created"
fi

# Attach EB service policy
echo "Attaching AWSElasticBeanstalkService policy..."
aws iam attach-role-policy \
    --role-name victim-eb-service-role \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkService \
    2>/dev/null || echo "  (Policy already attached)"

# Also attach enhanced health monitoring policy
echo "Attaching AWSElasticBeanstalkEnhancedHealth policy..."
aws iam attach-role-policy \
    --role-name victim-eb-service-role \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth \
    2>/dev/null || echo "  (Policy already attached)"

echo "✓ Policies attached"

SERVICE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/victim-eb-service-role"

echo ""
echo "✅ Service Role ARN:"
echo "   $SERVICE_ROLE_ARN"
echo ""

#==============================================================================
# Summary
#==============================================================================

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    Setup Complete                              ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Victim IAM Roles Created in Account B (142531840183):"
echo ""
echo "1. Instance Profile ARN:"
echo "   $INSTANCE_PROFILE_ARN"
echo ""
echo "2. Service Role ARN:"
echo "   $SERVICE_ROLE_ARN"
echo ""
echo "These ARNs will be used in the test GitHub workflow to attempt"
echo "cross-account IAM role injection."
echo ""
echo "Next step: Run setup-attacker-oidc.sh to configure Account A"
echo ""

# Save ARNs to file for workflow
cat > /tmp/victim-role-arns.txt << EOF
INSTANCE_PROFILE_ARN=$INSTANCE_PROFILE_ARN
SERVICE_ROLE_ARN=$SERVICE_ROLE_ARN
EOF

echo "ARNs saved to /tmp/victim-role-arns.txt"

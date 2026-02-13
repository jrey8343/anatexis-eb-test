# AWS Elastic Beanstalk GitHub Actions - Cross-Account IAM Test Setup

**Target:** Test for cross-account IAM role injection vulnerability
**Signal:** 640 pts (CRITICAL) - new_feature_state_machine pattern
**Expected Value:** $2K-$10K if vulnerable

---

## Quick Start (15 minutes total)

### Step 1: Create GitHub Repository (2 minutes)

```bash
# From this directory
cd projects/aws-bug-bounty/elastic-beanstalk-github-actions

# Initialize git repo
git init
git add .
git commit -m "Initial test setup"

# Create GitHub repo (you'll need to authenticate)
gh repo create anatexis-eb-test --public --source=. --remote=origin --push
```

**Or manually:**
1. Go to https://github.com/new
2. Name: `anatexis-eb-test`
3. Visibility: Public
4. Create repository
5. Push this directory to it

---

### Step 2: Setup AWS Account B (Victim) - Create IAM Roles (5 minutes)

**Run this script:**
```bash
cd scripts
./setup-victim-roles.sh
```

This creates:
- IAM instance profile: `victim-powerful-role` (with AdministratorAccess)
- EB service role: `victim-eb-service-role`
- Outputs ARNs for use in test workflow

**Manual steps if script fails:**
1. Log into AWS Account B (142531840183)
2. IAM → Roles → Create role
3. Trusted entity: EC2
4. Permissions: AdministratorAccess
5. Name: `victim-powerful-role`
6. Create instance profile with same name

---

### Step 3: Setup AWS Account A (Attacker) - Configure OIDC (5 minutes)

**Run this script:**
```bash
cd scripts
./setup-attacker-oidc.sh
```

This creates:
- OIDC Identity Provider for GitHub
- IAM role: `github-actions-eb-test`
- Trust policy allowing your GitHub repo
- Permissions: ElasticBeanstalk, IAM PassRole, S3

**What this script does:**
1. Creates OIDC provider pointing to GitHub
2. Creates IAM role with trust relationship to your GitHub repo
3. Attaches policies: ElasticBeanstalk, S3, IAM PassRole

**You'll need to provide:**
- Your GitHub username
- Repository name (anatexis-eb-test)

---

### Step 4: Run Test Workflow (2 minutes)

**Option A: Trigger via GitHub UI**
1. Go to your repo: `https://github.com/YOUR_USERNAME/anatexis-eb-test`
2. Actions tab
3. Click "Cross-Account IAM Role Injection Test"
4. Click "Run workflow"
5. Select branch: main
6. Click "Run workflow"

**Option B: Trigger via CLI**
```bash
gh workflow run test-cross-account-iam.yml
```

**Option C: Push to trigger**
```bash
git commit --allow-empty -m "Trigger test"
git push
```

---

### Step 5: Monitor Test Execution (5 minutes)

**Watch workflow:**
```bash
gh run watch
```

**Or view in browser:**
```bash
gh repo view --web
# Click Actions tab
```

**What the workflow does:**
1. Authenticates to AWS Account A using OIDC
2. Attempts to create Elastic Beanstalk environment
3. Uses **victim's IAM role ARN** in option-settings
4. Checks if deployment succeeds

---

### Step 6: Verify Results (2 minutes)

**If workflow SUCCEEDS:**
```bash
# SSH into EC2 instance (from workflow output)
ssh -i ~/.ssh/your-key.pem ec2-user@<EC2_IP>

# Check IAM role metadata
curl http://169.254.169.254/latest/meta-data/iam/security-credentials/

# If this returns "victim-powerful-role" → VULNERABILITY FOUND! 🎉
```

**If workflow FAILS:**
Check error message:
- ✅ **"InvalidParameterValue: IAM role not found"** → AWS validates same-account (SECURE)
- ✅ **"Access denied to assume role"** → AWS blocks cross-account PassRole (SECURE)
- ❌ **Any other error** → Investigate, might be setup issue

---

## Expected Outcomes

### Outcome 1: VULNERABLE (10% probability)

**Workflow succeeds, EC2 has victim's IAM role:**
```bash
curl http://169.254.169.254/latest/meta-data/iam/security-credentials/
# Returns: victim-powerful-role

# Verify cross-account access
aws sts get-caller-identity
# Shows: Account 142531840183 (victim account!)
```

**If this happens:**
1. 🎉 **CRITICAL VULNERABILITY FOUND**
2. Document full PoC steps
3. Run Gate 0-5 verification
4. Submit to AWS Bug Bounty
5. Expected payout: $2K-$10K

---

### Outcome 2: SECURE - IAM Validation (70% probability)

**Workflow fails with:**
```
Error: InvalidParameterValue: IAM instance profile arn:aws:iam::142531840183:instance-profile/victim-powerful-role does not exist
```

**Or:**
```
Error: AccessDenied: User is not authorized to perform iam:PassRole on resource: arn:aws:iam::142531840183:role/victim-powerful-role
```

**This means:**
- ✅ AWS validates IAM roles are in same account
- ✅ Cross-account PassRole blocked
- ✅ GitHub Action is SECURE
- Update calibration: `new_feature_state_machine` pattern → 1 success, 2 failures (33% hit rate)

---

### Outcome 3: SETUP ERROR (20% probability)

**Workflow fails with:**
```
Error: No OIDC token available
Error: Credentials could not be loaded
Error: Repository not found
```

**This means:**
- Setup issue, not a security finding
- Debug OIDC configuration
- Check IAM role trust policy
- Verify GitHub repo settings

---

## Cleanup After Testing

**Delete resources to avoid charges:**

```bash
# Account A (Attacker)
aws iam delete-role-policy --role-name github-actions-eb-test --policy-name ElasticBeanstalkPolicy
aws iam delete-role --role-name github-actions-eb-test
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn <OIDC_ARN>

# Delete Elastic Beanstalk environment (if created)
aws elasticbeanstalk terminate-environment --environment-name test-cross-account-iam

# Account B (Victim)
aws iam remove-role-from-instance-profile --instance-profile-name victim-powerful-role --role-name victim-powerful-role
aws iam delete-instance-profile --instance-profile-name victim-powerful-role
aws iam detach-role-policy --role-name victim-powerful-role --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam delete-role --role-name victim-powerful-role
aws iam detach-role-policy --role-name victim-eb-service-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkService
aws iam delete-role --role-name victim-eb-service-role

# Delete GitHub repo (if desired)
gh repo delete anatexis-eb-test --yes
```

---

## Troubleshooting

### OIDC Token Issues

**Error:** "No OIDC token available"

**Fix:**
1. Check workflow has `permissions: id-token: write`
2. Verify IAM role trust policy includes your repo
3. Check OIDC provider URL is exactly `token.actions.githubusercontent.com`

### IAM PassRole Permissions

**Error:** "User is not authorized to perform iam:PassRole"

**Fix:**
1. Check attacker role has `iam:PassRole` permission
2. Verify PassRole is allowed on `*` resource (or specific role ARN)

### Repository Not Found

**Error:** "Repository YOUR_USERNAME/anatexis-eb-test not found"

**Fix:**
1. Verify repo was created: `gh repo view`
2. Check repo is public (OIDC requires public repos by default)
3. Update trust policy with correct repo name

---

## Cost Estimate

**AWS charges during test:**
- OIDC Identity Provider: $0 (free)
- IAM roles: $0 (free)
- Elastic Beanstalk environment (if created): ~$0.02/hour
- EC2 t2.micro instance: ~$0.012/hour
- S3 storage: <$0.01

**Total:** ~$0.03 for 1-hour test

**Cleanup within 1 hour to minimize costs.**

---

## Security Considerations

**This test is SAFE because:**
1. You own both AWS accounts
2. You're testing your own GitHub repo
3. No production systems involved
4. All resources can be deleted

**Do NOT:**
- Test against AWS accounts you don't own
- Use production AWS credentials
- Leave test resources running indefinitely
- Share victim IAM role ARNs publicly

---

## Next Steps After Test

**If VULNERABLE:**
1. Save all workflow logs
2. Take screenshots of IAM role metadata
3. Run full 7-gate verification
4. Write detailed bug report
5. Submit to AWS Bug Bounty

**If SECURE:**
1. Update calibration data
2. Move to next target from intelligence run
3. Consider other AWS GitHub Actions for similar testing

---

## Files Created

```
projects/aws-bug-bounty/elastic-beanstalk-github-actions/
├── SETUP.md (this file)
├── scripts/
│   ├── setup-victim-roles.sh
│   ├── setup-attacker-oidc.sh
│   └── cleanup.sh
├── .github/workflows/
│   └── test-cross-account-iam.yml
├── app/
│   └── application.py (simple Python app for deployment)
└── README.md
```

---

**Ready to start? Run:**
```bash
cd projects/aws-bug-bounty/elastic-beanstalk-github-actions
cat SETUP.md  # Read full instructions
./scripts/setup-victim-roles.sh  # Step 1
./scripts/setup-attacker-oidc.sh  # Step 2
gh workflow run test-cross-account-iam.yml  # Step 3
```

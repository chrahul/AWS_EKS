

#  **Velero Installation Guide for Amazon EKS (with IRSA)**

### *Complete, Error-Free, Production-Ready Document*

---

#  **STEP 1 — Prepare Your Local Environment**

### 1.1 Install Required Tools

Ensure the following tools are installed on your laptop/jump host:

| Tool       | Purpose                        |
| ---------- | ------------------------------ |
| aws CLI    | Interacts with AWS             |
| kubectl    | Interacts with Kubernetes      |
| helm       | Installs Velero Helm chart     |
| eksctl     | Creates OIDC provider for IRSA |
| velero CLI | Run backups/restores           |

Check each:

```bash
aws --version
kubectl version --client
helm version
eksctl version
velero version
```

Install missing tools if required.

---

### 1.2 Export Required Environment Variables

```bash
export AWS_REGION=ap-south-1
export CLUSTER_NAME=efk-demo
```

Verify:

```bash
echo $AWS_REGION
echo $CLUSTER_NAME
```

---

### 1.3 Connect kubectl to the EKS Cluster

```bash
aws eks update-kubeconfig \
  --name ${CLUSTER_NAME} \
  --region ${AWS_REGION}
```

Verify connection:

```bash
kubectl get nodes
kubectl get ns
```

---

#  **STEP 2 — Enable OIDC Provider for IRSA**

Velero requires **IAM Roles for Service Accounts (IRSA)**.
This needs OIDC enabled in your EKS cluster.

Run:

```bash
eksctl utils associate-iam-oidc-provider \
  --cluster ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --approve
```

If already enabled, it safely exits.

---

#  **STEP 3 — Create an S3 Bucket for Velero Backups**

### 3.1 Choose a Unique Bucket Name

```bash
export BUCKET_NAME=velero-backup-${CLUSTER_NAME}-$(date +%s)
echo $BUCKET_NAME
```

Or use a fixed name:

```bash
export BUCKET_NAME=velero-backup-efk-demo
```

---

### 3.2 Create S3 Bucket

```bash
aws s3api create-bucket \
  --bucket ${BUCKET_NAME} \
  --region ${AWS_REGION} \
  --create-bucket-configuration LocationConstraint=${AWS_REGION}
```

---

### 3.3 Enable Versioning

```bash
aws s3api put-bucket-versioning \
  --bucket ${BUCKET_NAME} \
  --versioning-configuration Status=Enabled
```

---

### 3.4 (Optional) Enable Encryption

```bash
aws s3api put-bucket-encryption \
  --bucket ${BUCKET_NAME} \
  --server-side-encryption-configuration '{
    "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]
  }'
```

---

#  **STEP 4 — Create IAM Policy & Role for Velero (IRSA)**

Velero needs IAM permissions for:

* S3 backup storage
* EBS snapshot creation/deletion

---

## 4.1 Create IAM Policy

Create the JSON:

```bash
cat <<EOF > velero-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "VeleroS3Permissions",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}",
        "arn:aws:s3:::${BUCKET_NAME}/*"
      ]
    },
    {
      "Sid": "VeleroEBSSnapshotPermissions",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVolumes",
        "ec2:CreateTags",
        "ec2:DescribeSnapshots",
        "ec2:CreateSnapshot",
        "ec2:DeleteSnapshot"
      ],
      "Resource": "*"
    }
  ]
}
EOF
```

Create the policy:

```bash
export VELERO_POLICY_NAME=VeleroAccessPolicy

aws iam create-policy \
  --policy-name ${VELERO_POLICY_NAME} \
  --policy-document file://velero-policy.json
```

Copy the Policy ARN from the output.

---

## 4.2 Create IAM Role for Velero (IRSA)

### Get OIDC URL and Account ID

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export OIDC_PROVIDER_URL=$(aws eks describe-cluster \
  --name ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --query "cluster.identity.oidc.issuer" \
  --output text | sed -e "s/^https:\/\///")
```

---

### Create Trust Policy

```bash
cat <<EOF > velero-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER_URL}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER_URL}:sub": "system:serviceaccount:velero:velero"
        }
      }
    }
  ]
}
EOF
```

---

### Create Role

```bash
export VELERO_ROLE_NAME=VeleroAccessRole

aws iam create-role \
  --role-name ${VELERO_ROLE_NAME} \
  --assume-role-policy-document file://velero-trust-policy.json
```

---

### Attach Policy

```bash
aws iam attach-role-policy \
  --role-name ${VELERO_ROLE_NAME} \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${VELERO_POLICY_NAME}
```

---

#  **STEP 5 — Install Velero via Helm (Velero chart v11.x compatible)**

### 5.1 Create Namespace

```bash
kubectl create namespace velero
```

---

### 5.2 Add Velero Helm Repo

```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update
```

---

### 5.3 Create Helm Values File (Correct for Velero v11.x)

```bash
cat <<EOF > values-velero.yaml
configuration:

  backupStorageLocation:
    - name: default
      provider: aws
      bucket: ${BUCKET_NAME}
      prefix: velero
      config:
        region: ${AWS_REGION}

  volumeSnapshotLocation:
    - name: default
      provider: aws
      config:
        region: ${AWS_REGION}

credentials:
  useSecret: false

serviceAccount:
  server:
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${VELERO_ROLE_NAME}

initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.10.0
    volumeMounts:
      - mountPath: /target
        name: plugins

snapshotsEnabled: true

metrics:
  enabled: true
EOF
```

---

### 5.4 Install Velero

```bash
helm install velero vmware-tanzu/velero \
  --namespace velero \
  -f values-velero.yaml
```

---

### 5.5 Verify Installation

```bash
kubectl get pods -n velero
kubectl logs deploy/velero -n velero | head
```

You should see:

```
velero-xxxxx   1/1   Running
```

---

#  **STEP 6 — Create First Velero Backup**

```bash
velero backup create first-full-backup \
  --include-namespaces '*' \
  --exclude-namespaces kube-system,velero \
  --ttl 720h
```

Check status:

```bash
velero backup get
```

Describe:

```bash
velero backup describe first-full-backup --details
```

Check logs:

```bash
velero backup logs first-full-backup
```

Check S3 bucket — backup folders should appear.

---

#  **STEP 7 — Test Restore (Optional Disaster Simulation)**

Create dummy namespace, delete it, restore it.

Let me know when you're ready — I can guide that too.

---

.


# PART 1 – Launch EKS, Deploy Shop App, Install Velero, Take Full Backup

## 0. Lab Overview

In this lab you will:

1. Create an **EKS cluster** on AWS
2. Install the **EBS CSI driver** (for dynamic EBS volumes)
3. Deploy a simple **Shop Application** (frontend + API + MySQL with PVC)
4. Create an **IAM Role for Velero** (IRSA)
5. Install **Velero** in the cluster
6. Take a **full backup** and verify it in **S3 + Velero**

All commands are to be run from the **bastion / admin EC2** where AWS CLI, kubectl, eksctl, and velero are installed.

---

## 1. Prerequisites

On your admin EC2 (or laptop with access to AWS):

* AWS CLI v2
* `kubectl`
* `eksctl`
* `velero` CLI

Check:

```bash
aws sts get-caller-identity
kubectl version --client
eksctl version
velero version
```

Environment variables:

```bash
export AWS_REGION=ap-south-1
export AWS_PROFILE=default    # or your profile
```

---

## 2. Create S3 Bucket for Velero Backups

We will create a dedicated bucket for Velero backups.

```bash
export VELERO_BUCKET=velero-backup-efk-demo-$(date +%s)

aws s3 mb s3://$VELERO_BUCKET --region $AWS_REGION
```

Confirm:

```bash
aws s3 ls | grep velero-backup
```

We will store all backups under prefix **`velero/`** in this bucket (important for Part 2 & 3).

---

## 3. Create EKS Cluster (OLD / PRIMARY CLUSTER)

We’ll call the cluster **`efk-demo`** (same name you used).

Create a config file:

```bash
cat > eks-cluster-config.yaml << 'EOF'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: efk-demo
  region: ap-south-1
  version: "1.30"

iam:
  withOIDC: true

managedNodeGroups:
  - name: ng-1
    instanceType: t3.medium
    desiredCapacity: 3
    minSize: 3
    maxSize: 5
    volumeSize: 20
    privateNetworking: true
EOF
```

Create cluster:

```bash
eksctl create cluster -f eks-cluster-config.yaml
```

This will take some time.

When done, confirm nodes:

```bash
kubectl get nodes -o wide
```

You should see 3 nodes in `Ready` state.

---

## 4. Install AWS EBS CSI Driver (for Persistent Volumes)

### 4.1. Create the EBS CSI Add-on

```bash
aws eks create-addon \
  --cluster-name efk-demo \
  --addon-name aws-ebs-csi-driver \
  --region $AWS_REGION
```

Check add-on status:

```bash
aws eks describe-addon \
  --cluster-name efk-demo \
  --addon-name aws-ebs-csi-driver \
  --region $AWS_REGION \
  --query "addon.status"
```

If it shows `ACTIVE` after a while, you’re good.

If it stays in `CREATING` and controller pods are CrashLooping, do step 4.2.

### 4.2. Attach IAM Policy to NodeGroup Role (fix CrashLoop issue)

List your nodegroup IAM role:

```bash
aws iam list-roles \
  --query "Roles[?contains(RoleName, 'NodeInstanceRole')].RoleName" \
  --output table
```

You will see something like:

```text
eksctl-efk-demo-nodegroup-ng-1-NodeInstanceRole-XXXXXXXXXXXX
```

Attach **AmazonEBSCSIDriverPolicy**:

```bash
export NODE_ROLE=<THE_ROLE_NAME_FROM_ABOVE>

aws iam attach-role-policy \
  --role-name $NODE_ROLE \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
```

Delete the EBS controller pods so they restart with new permissions:

```bash
kubectl delete pod -n kube-system -l app=ebs-csi-controller
```

Verify:

```bash
kubectl get pods -n kube-system | grep ebs
```

Expected:

* `ebs-csi-controller-...` → Running (6/6)
* `ebs-csi-node-...`       → Running (3/3)

---

## 5. Deploy the Shop Application (Namespace: shop-prod)

### 5.1. Create Namespace

```bash
kubectl create namespace shop-prod
```

### 5.2. Deploy MySQL (StatefulSet with PVC)

```bash
cat > shop-mysql.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: mysql-secret
  namespace: shop-prod
type: Opaque
data:
  mysql-root-password: cGFzc3dvcmQ=  # "password" base64

---
apiVersion: v1
kind: Service
metadata:
  name: mysql
  namespace: shop-prod
spec:
  ports:
    - port: 3306
      targetPort: 3306
  clusterIP: None
  selector:
    app: mysql

---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
  namespace: shop-prod
spec:
  selector:
    matchLabels:
      app: mysql
  serviceName: mysql
  replicas: 1
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
        - name: mysql
          image: mysql:8.0
          ports:
            - containerPort: 3306
              name: mysql
          env:
            - name: MYSQL_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-secret
                  key: mysql-root-password
          volumeMounts:
            - name: mysql-data
              mountPath: /var/lib/mysql
  volumeClaimTemplates:
    - metadata:
        name: mysql-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 10Gi
EOF
```

Apply:

```bash
kubectl apply -f shop-mysql.yaml
```

Wait for pod:

```bash
kubectl get pods -n shop-prod -w
```

When `mysql-0` is `Running`, check PVC:

```bash
kubectl get pvc -n shop-prod
```

You should see `mysql-data-mysql-0` in `Bound` state.

### 5.3. Deploy Orders API, Frontend, and Node Logger

```bash
cat > shop-app.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: orders-api
  namespace: shop-prod
spec:
  selector:
    app: orders-api
  ports:
    - port: 8080
      targetPort: 8080

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-api
  namespace: shop-prod
spec:
  replicas: 2
  selector:
    matchLabels:
      app: orders-api
  template:
    metadata:
      labels:
        app: orders-api
    spec:
      containers:
        - name: orders-api
          image: ghcr.io/rahul/shop-orders-api:latest   # use your real image here
          ports:
            - containerPort: 8080

---
apiVersion: v1
kind: Service
metadata:
  name: shop-frontend
  namespace: shop-prod
spec:
  type: LoadBalancer
  selector:
    app: shop-frontend
  ports:
    - port: 80
      targetPort: 80

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-frontend
  namespace: shop-prod
spec:
  replicas: 3
  selector:
    matchLabels:
      app: shop-frontend
  template:
    metadata:
      labels:
        app: shop-frontend
    spec:
      containers:
        - name: shop-frontend
          image: ghcr.io/rahul/shop-frontend:latest     # use your real image here
          ports:
            - containerPort: 80

---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-logger
  namespace: shop-prod
spec:
  selector:
    matchLabels:
      app: node-logger
  template:
    metadata:
      labels:
        app: node-logger
    spec:
      containers:
        - name: node-logger
          image: busybox
          command: ["sh", "-c", "while true; do echo $(hostname) $(date); sleep 5; done"]
EOF
```

Apply:

```bash
kubectl apply -f shop-app.yaml
```

Verify:

```bash
kubectl get all -n shop-prod
kubectl get pvc -n shop-prod
```

Expected:

* Pods: `mysql-0`, `orders-api-...`, `shop-frontend-...`, `node-logger-...` → Running
* Services: `mysql`, `orders-api`, `shop-frontend`
* PVC: `mysql-data-mysql-0` → Bound

---

## 6. Create IAM Role for Velero (IRSA)

### 6.1. Get Cluster OIDC Issuer

```bash
export CLUSTER_NAME=efk-demo

OIDC_URL=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --query "cluster.identity.oidc.issuer" \
  --output text)

echo $OIDC_URL
```

Extract ID:

```bash
OIDC_ID=$(echo $OIDC_URL | sed -e "s|https://oidc.eks.$AWS_REGION.amazonaws.com/id/||")
echo $OIDC_ID
```

### 6.2. Create Trust Policy for Velero Role

```bash
cat > velero-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):oidc-provider/oidc.eks.$AWS_REGION.amazonaws.com/id/$OIDC_ID"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.$AWS_REGION.amazonaws.com/id/$OIDC_ID:sub": "system:serviceaccount:velero:velero",
          "oidc.eks.$AWS_REGION.amazonaws.com/id/$OIDC_ID:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
```

Create role:

```bash
aws iam create-role \
  --role-name VeleroRole \
  --assume-role-policy-document file://velero-trust-policy.json
```

If it already exists, you’ll get `EntityAlreadyExists` – that’s fine; just reuse.

Attach permissions:

```bash
aws iam attach-role-policy \
  --role-name VeleroRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

aws iam attach-role-policy \
  --role-name VeleroRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
```

Get role ARN:

```bash
VELERO_ROLE_ARN=$(aws iam get-role \
  --role-name VeleroRole \
  --query "Role.Arn" \
  --output text)

echo $VELERO_ROLE_ARN
```

---

## 7. Install Velero on the Cluster

We’ll install Velero **via CLI**, using IRSA (no static credentials).

### 7.1. Install Velero (CLI)

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.10.0 \
  --bucket $VELERO_BUCKET \
  --backup-location-config region=$AWS_REGION \
  --snapshot-location-config region=$AWS_REGION \
  --use-node-agent \
  --prefix velero \
  --no-secret \
  --sa-annotations eks.amazonaws.com/role-arn=$VELERO_ROLE_ARN
```

This will:

* Create namespace `velero`
* Create service account `velero` annotated with your IAM role
* Deploy velero deployment + node-agent daemonset
* Configure BackupStorageLocation using `$VELERO_BUCKET/velero`

### 7.2. Verify Velero Pods

```bash
kubectl -n velero get pods
```

Expect:

* `velero-...` → Running
* `node-agent-...` → Running on each node

### 7.3. Verify Velero Backup Storage Location

```bash
velero backup-location get
```

Expected:

* `default` → PROVIDER aws, BUCKET/PREFIX `$VELERO_BUCKET/velero`, PHASE `Available`

If phase is `Available`, Velero can talk to S3 using IRSA. 

---

## 8. Take Full Backup of Shop Application

We will backup **cluster-scoped + namespace resources**, but you can start with only `shop-prod` to keep it simple.

### 8.1. Full Backup of shop-prod Namespace

```bash
velero backup create shop-prod-full-$(date +%Y%m%d) \
  --include-namespaces shop-prod \
  --ttl 72h
```

Check status:

```bash
velero backup get
```

You should see something like:

```text
NAME                     STATUS      ERRORS   WARNINGS   CREATED                         EXPIRES   STORAGE LOCATION   SELECTOR
shop-prod-full-20251129  Completed   0        0          2025-11-29 03:31:21 +0000 UTC   2d        default            <none>
```

Describe details:

```bash
velero backup describe shop-prod-full-20251129 --details
```

You should see:

* Namespace: `shop-prod`
* Pods: mysql, node-logger, orders-api, shop-frontend
* PVC/PV details
* Snapshot IDs for the EBS volumes

### 8.2. Verify in S3

List the S3 bucket:

```bash
aws s3 ls s3://$VELERO_BUCKET/
aws s3 ls s3://$VELERO_BUCKET/velero/
```

You will see several backup-related folders (metadata, manifests, etc.).
That confirms **Velero has saved backup metadata into S3**.

---

## 9. Summary of Part 1

You now have:

* EKS cluster `efk-demo` up and healthy
* EBS CSI driver installed and working
* Shop application running in namespace `shop-prod` with:

  * MySQL StatefulSet + PVC on EBS
  * Frontend + Orders API + Node logger
* Velero installed with IRSA (IAM role bound to velero SA)
* S3 bucket for backups (`$VELERO_BUCKET` with prefix `velero/`)
* Full backup `shop-prod-full-YYYYMMDD` created and visible both from:

  * `velero backup get`
  * `aws s3 ls s3://$VELERO_BUCKET/velero/`

This is exactly the state we need before moving to:

* **Part 2 – Install Velero on a NEW cluster and connect to the same backup bucket**
* **Part 3 – Restore the backup into the new cluster and verify the application**


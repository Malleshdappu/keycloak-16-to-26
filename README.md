# Keycloak 16 to Keycloak 26 Migration Guide for MOSIP 1.2.x

## Overview

This guide provides the steps to migrate Keycloak 16 to Keycloak 26.7.4 in an existing MOSIP 1.2.x environment while retaining the existing Keycloak URL, realm, users and client configurations.

Keycloak 26 will be deployed in a separate namespace with a separate database to support rollback if required.

## Prerequisites

- Existing MOSIP environment with Keycloak 16.
- Kubernetes cluster access.
- Helm, kubectl, curl, jq and Python 3 in your local terminal.
- Keycloak administrator credentials.
- Access to the MOSIP infrastructure repository.

## Step 1: Backup existing Keycloak

Take a backup of the existing Keycloak secrets, realms, users and PostgreSQL database.

Follow the existing [MOSIP IAM documentation](https://github.com/mosip/mosip-infra/tree/v1.2.1.1/deployment/v3/external/iam) for exporting Keycloak realms, users and secrets.

Create a backup directory:

```bash
mkdir -p ~/keycloak16-bkp
```

Ensure the following exported files are available:

```text
keycloak16-bkp/
├── mosip-realm.json
├── mosip-users-0.json
└── mosip-users-1.json
```

Also, back up the existing Gateway and VirtualService configurations.

```bash
kubectl get gateway keycloak -n keycloak -o yaml > keycloak16-gateway.yaml
kubectl get virtualservice keycloak -n keycloak -o yaml > keycloak16-virtualservice.yaml
```

## Step 2: Install Keycloak 26

Refer to the [MOSIP IAM deployment documentation](https://github.com/mosip/mosip-infra/tree/v1.2.1.1/deployment/v3/external/iam).

Navigate to the IAM deployment directory with the respective branch or tag.

```bash
cd mosip-infra/deployment/v3/external/iam
```

### 2.1 Update `install.sh`

```bash
vim install.sh
```

Update the namespace:

```bash
NS=keycloak26
```

Update the Helm installation command:

```bash
helm -n "$NS" install "$SERVICE_NAME" mosip/keycloak \
  --version "7.1.18" \
  --set image.registry=quay.io \
  --set image.repository=keycloak/keycloak \
  --set image.tag=26.7.4 \
  --set image.pullPolicy=Always \
  -f values.yaml \
  --wait
```

### 2.2 Update `values.yaml`

```bash
vim values.yaml
```

Add or update the following configurations:

```yaml
command:
  - /opt/keycloak/bin/kc.sh

args:
  - start
  - --http-enabled=true
  - --http-relative-path=/auth

extraEnvVars:
  - name: KC_DB
    value: postgres

  - name: KC_DB_URL
    value: jdbc:postgresql://keycloak-postgresql:5432/bitnami_keycloak

  - name: KC_DB_USERNAME
    value: bn_keycloak

  - name: KC_DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: keycloak-postgresql
        key: password

  - name: KC_BOOTSTRAP_ADMIN_USERNAME
    value: admin

  - name: KC_BOOTSTRAP_ADMIN_PASSWORD
    valueFrom:
      secretKeyRef:
        name: keycloak
        key: admin-password

  - name: KC_HOSTNAME_STRICT
    value: "false"

  - name: KC_HTTP_ENABLED
    value: "true"

  - name: KC_PROXY_HEADERS
    value: "xforwarded"
```

### 2.3 Execute the installation script

```bash
./install.sh
```

Verify the pods:

```bash
kubectl get pods -n keycloak26
```

Verify the Keycloak version:

```bash
kubectl exec -n keycloak26 keycloak-0 -- /opt/keycloak/bin/kc.sh --version
```

**Expected output:**

```text
Keycloak 26.7.4
```

## Step 3: Disable existing Keycloak 16

Once Keycloak 26 is successfully installed, verify its Gateway and VirtualService before switching traffic.

```bash
kubectl get gateway,virtualservice -n keycloak26
kubectl scale statefulset keycloak -n keycloak --replicas=0
```

> **Note:** If Keycloak is running as a Deployment, use `deployment` instead of `statefulset`.

To avoid routing conflicts between Keycloak 16 and Keycloak 26, disable the existing Keycloak Gateway.

```bash
kubectl patch gateway keycloak -n keycloak \
  --type=merge \
  -p '{"spec":{"selector":{"istio":"ingressgateway-disabled"}}}'
```

Access the Keycloak landing page using the existing URL:

```text
https://iam.<environment-domain>/auth/
```

Verify the Keycloak Admin Console is accessible.

> **Note:** Do not delete the existing Keycloak 16 deployment, database, secrets or PVCs.

## Step 4: Import Keycloak realm and users

Place the `migrate-keycloak16-to-26.sh` script in the directory containing the exported realm and user files.

```bash
cd ~/keycloak16-bkp
```

Ensure the following files are available:

```text
mosip-realm.json
mosip-users-0.json
mosip-users-1.json
migrate-keycloak16-to-26.sh
```

Execute the migration script:

```bash
chmod +x migrate-keycloak16-to-26.sh
./migrate-keycloak16-to-26.sh "https://iam.<environment-domain>/auth"
```

Example:

```bash
./migrate-keycloak16-to-26.sh https://iam.dst-stage.mosip.net/auth
```

Enter the Keycloak administrator username and password when prompted.

Review the generated `realm-changes.diff` before confirming the import.

**Expected output:**

```text
MIGRATION COUNT AND CLIENT VERIFICATION: SUCCESS

Migration verification completed.
```

> **Note:** The script verifies normal users and service accounts separately. It currently supports the `mosip` realm and two user export files.

## Step 5: Configure OpenID client scope

Configure the `openid` client scope for MOSIP 1.2.x compatibility with Keycloak 26 to support AuthManager validation through the OpenID Connect UserInfo endpoint.

Execute the script:

```bash
chmod +x configure-openid-all-clients.sh
./configure-openid-all-clients.sh "https://iam.<environment-domain>/auth" mosip
```

The script creates the `openid` client scope if it does not exist, assigns it as Default to eligible existing clients and configures automatic assignment for newly created OIDC clients.

**Expected output:**

```text
[SUCCESS] OpenID client scope configuration completed.
[SUCCESS] Realm-level Default scope verified.
[INFO] Newly created OIDC clients will inherit openid.
[INFO] No Keycloak restart is required.
```

The script can be executed multiple times without duplicating existing client scope assignments.

## Step 6: Verify the migration

After completing the migration, verify the following:

**Verification checklist**

- [ ] Keycloak 26 pods are running.
- [ ] Existing Keycloak URL is accessible.
- [ ] MOSIP realm and users are available.
- [ ] Clients, client secrets and role mappings are retained.
- [ ] Service accounts are available.
- [ ] OpenID client scope is configured as Default.
- [ ] Existing user login is working.
- [ ] MOSIP AuthManager and UserInfo endpoint are working.
- [ ] MOSIP services are communicating successfully.
- [ ] Custom themes and authorization policies are compatible.

## Step 7: Rollback (if required)

If any critical issues occur, disable the Keycloak 26 Gateway.

```bash
kubectl patch gateway keycloak -n keycloak26 \
  --type=merge \
  -p '{"spec":{"selector":{"istio":"ingressgateway-disabled"}}}'
```

Scale up the existing Keycloak 16:

```bash
kubectl scale statefulset keycloak -n keycloak --replicas=1
```

Once the pods are ready, restore the existing Gateway selector:

```bash
kubectl patch gateway keycloak -n keycloak \
  --type=merge \
  -p '{"spec":{"selector":{"istio":"ingressgateway-internal"}}}'
```

Verify the Keycloak URL and MOSIP service functionality.


#!/usr/bin/env bash
set -euo pipefail

KC_URL="${1:?Usage: $0 <keycloak-base-url> [realm]}"
KC_URL="${KC_URL%/}"
REALM="${2:-mosip}"

for cmd in curl jq mktemp; do
  command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }
done

read -rp 'Keycloak admin username: ' ADMIN_USER
read -rsp 'Keycloak admin password: ' ADMIN_PASS
echo
TOKEN=''
TOKEN_EXP=0
ADDED=0
SKIPPED=0
FAILED=0
VERIFIED=0
REFRESHES=0
CREATED=0
DESCRIPTION_UPDATED=0
SCOPE_DESCRIPTION='Keycloak 26 compatibility scope for MOSIP 1.2.x. Ensures openid is included in token scopes by default to support MOSIP AuthManager validation through the OpenID Connect UserInfo endpoint.'
trap 'unset TOKEN ADMIN_PASS' EXIT

get_token() {
  local tmp code exp
  tmp=$(mktemp)
  code=$(curl -sS -o "$tmp" -w '%{http_code}' -X POST \
    "$KC_URL/realms/master/protocol/openid-connect/token" \
    --data-urlencode 'client_id=admin-cli' \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=$ADMIN_USER" \
    --data-urlencode "password=$ADMIN_PASS") || { rm -f "$tmp"; return 1; }
  if [[ "$code" != 200 ]]; then
    echo "Admin authentication failed (HTTP $code)" >&2
    jq -r '.error_description // .error // empty' "$tmp" 2>/dev/null >&2 || true
    rm -f "$tmp"; return 1
  fi
  TOKEN=$(jq -r '.access_token // empty' "$tmp")
  exp=$(jq -r '.expires_in // 60' "$tmp")
  rm -f "$tmp"
  [[ -n "$TOKEN" ]] || return 1
  [[ "$exp" =~ ^[0-9]+$ ]] || exp=60
  TOKEN_EXP=$(($(date +%s) + exp))
  echo "Admin token obtained (lifetime: ${exp}s)" >&2
}

api() {
  local method="$1" url="$2" payload="${3:-}" attempt code tmp hdr now
  for attempt in 1 2; do
    now=$(date +%s)
    if [[ -z "$TOKEN" || "$now" -ge $((TOKEN_EXP - 15)) ]]; then
      echo 'Refreshing admin token before request (near expiry)...' >&2
      get_token || return 1
      ((REFRESHES+=1))
    fi
    tmp=$(mktemp); hdr=$(mktemp)
    local args=(-sS -o "$tmp" -D "$hdr" -w '%{http_code}' -X "$method" -H "Authorization: Bearer $TOKEN")
    if [[ -n "$payload" ]]; then
      args+=(-H 'Content-Type: application/json' --data "$payload")
    fi
    code=$(curl "${args[@]}" "$url") || { rm -f "$tmp" "$hdr"; return 1; }
    if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
      cat "$tmp"; rm -f "$tmp" "$hdr"; return 0
    fi
    echo "HTTP $code: $method $url" >&2
    jq -r 'if type=="object" then (.error_description // .error // empty) else empty end' "$tmp" 2>/dev/null >&2 || true
    grep -i '^www-authenticate:' "$hdr" | tr -d '\r' >&2 || true
    rm -f "$tmp" "$hdr"
    if [[ "$code" == 401 && "$attempt" == 1 ]]; then
      echo '401 received; obtaining a new token and retrying once...' >&2
      get_token || return 1
      ((REFRESHES+=1))
    else
      return 1
    fi
  done
  return 1
}

get_token || exit 1
SCOPES=$(api GET "$KC_URL/admin/realms/$REALM/client-scopes") || exit 1
SCOPE_ID=$(jq -r '[.[] | select(.name=="openid" and .protocol=="openid-connect")][0].id // empty' <<< "$SCOPES")
if [[ -z "$SCOPE_ID" ]]; then
  echo "The 'openid' client scope does not exist in realm '$REALM'."
  read -rp 'Create it now? (yes/no): ' ANSWER
  [[ "$ANSWER" == yes ]] || { echo 'Cancelled'; exit 0; }
  echo 'Creating openid scope...'
  api POST "$KC_URL/admin/realms/$REALM/client-scopes" \
    '{"name":"openid","protocol":"openid-connect","description":"Keycloak 26 compatibility scope for MOSIP 1.2.x. Ensures openid is included in token scopes by default to support MOSIP AuthManager validation through the OpenID Connect UserInfo endpoint.","attributes":{"include.in.token.scope":"true","display.on.consent.screen":"false"}}' >/dev/null || exit 1
  CREATED=1
  SCOPES=$(api GET "$KC_URL/admin/realms/$REALM/client-scopes") || exit 1
  SCOPE_ID=$(jq -r '[.[] | select(.name=="openid" and .protocol=="openid-connect")][0].id // empty' <<< "$SCOPES")
  [[ -n "$SCOPE_ID" ]] || { echo 'Scope creation could not be verified' >&2; exit 1; }
  echo "CREATED and VERIFIED scope: openid ($SCOPE_ID)"
else
  echo "EXISTS: openid scope ($SCOPE_ID)"
  SCOPE_JSON=$(api GET "$KC_URL/admin/realms/$REALM/client-scopes/$SCOPE_ID") || exit 1
  CURRENT_DESCRIPTION=$(jq -r '.description // ""' <<< "$SCOPE_JSON")
  if [[ "$CURRENT_DESCRIPTION" != "$SCOPE_DESCRIPTION" ]]; then
    echo "Current description: ${CURRENT_DESCRIPTION:-<empty>}"
    echo "Proposed description: $SCOPE_DESCRIPTION"
    read -rp 'Update the existing openid scope description? (yes/no): ' ANSWER
    if [[ "$ANSWER" == yes ]]; then
      UPDATED_SCOPE=$(jq --arg description "$SCOPE_DESCRIPTION" '.description = $description' <<< "$SCOPE_JSON")
      api PUT "$KC_URL/admin/realms/$REALM/client-scopes/$SCOPE_ID" "$UPDATED_SCOPE" >/dev/null || exit 1
      CHECK_SCOPE=$(api GET "$KC_URL/admin/realms/$REALM/client-scopes/$SCOPE_ID") || exit 1
      [[ "$(jq -r '.description // ""' <<< "$CHECK_SCOPE")" == "$SCOPE_DESCRIPTION" ]] || {
        echo 'ERROR: Scope description update could not be verified' >&2
        exit 1
      }
      DESCRIPTION_UPDATED=1
      echo 'UPDATED and VERIFIED: openid scope description'
    else
      echo 'SKIP: existing scope description left unchanged'
    fi
  else
    echo 'VERIFIED: openid scope description already matches'
  fi
fi

CLIENTS=$(api GET "$KC_URL/admin/realms/$REALM/clients?max=1000") || exit 1
# Configure openid as a realm-level default client scope
# Ensures newly created OIDC clients inherit openid automatically

echo "Checking realm-level openid default scope..."

REALM_DEFAULT_SCOPES=$(api GET \
  "$KC_URL/admin/realms/$REALM/default-default-client-scopes") || exit 1

if jq -e --arg id "$SCOPE_ID" \
  'any(.[]; .id == $id)' \
  <<< "$REALM_DEFAULT_SCOPES" >/dev/null; then

  echo "SKIP: openid is already a realm-level default scope"

else

  echo "Assigning openid as a realm-level default scope..."

  api PUT \
    "$KC_URL/admin/realms/$REALM/default-default-client-scopes/$SCOPE_ID" \
    >/dev/null || exit 1

fi

# Verify realm-level default assignment

REALM_DEFAULT_SCOPES=$(api GET \
  "$KC_URL/admin/realms/$REALM/default-default-client-scopes") || exit 1

if jq -e --arg id "$SCOPE_ID" \
  'any(.[]; .id == $id)' \
  <<< "$REALM_DEFAULT_SCOPES" >/dev/null; then

  echo "VERIFIED: openid is a realm-level default scope"
  echo "New OIDC clients will inherit openid automatically"

else

  echo "FAILED: Realm-level default scope verification" >&2
  exit 1

fi
CLIENT_LIST=$(jq -r '
  .[] | select(.protocol=="openid-connect") |
  select(.clientId as $c | ["account","account-console","admin-cli","broker","realm-management","security-admin-console"] | index($c) | not) |
  [.clientId,.id] | @tsv
' <<< "$CLIENTS")
[[ -n "$CLIENT_LIST" ]] || { echo 'No eligible clients found'; exit 0; }
echo 'Clients to process:'
printf '%s\n' "$CLIENT_LIST" | cut -f1
echo
read -rp 'Assign openid as Default to all listed clients? (yes/no): ' ANSWER
[[ "$ANSWER" == yes ]] || { echo 'Cancelled'; exit 0; }

while IFS=$'\t' read -r CLIENT_ID CLIENT_UUID; do
  [[ -n "$CLIENT_UUID" ]] || continue
  echo "Processing: $CLIENT_ID"
  if ! CURRENT=$(api GET "$KC_URL/admin/realms/$REALM/clients/$CLIENT_UUID/default-client-scopes"); then
    echo "FAILED: $CLIENT_ID (read)"; ((FAILED+=1)); continue
  fi
  if jq -e --arg id "$SCOPE_ID" 'any(.[]; .id==$id)' <<< "$CURRENT" >/dev/null; then
    echo "SKIP: $CLIENT_ID (already assigned)"; ((SKIPPED+=1))
  else
    if api PUT "$KC_URL/admin/realms/$REALM/clients/$CLIENT_UUID/default-client-scopes/$SCOPE_ID" >/dev/null; then
      echo "ADDED: $CLIENT_ID"; ((ADDED+=1))
    else
      echo "FAILED: $CLIENT_ID (assignment)"; ((FAILED+=1)); continue
    fi
  fi
  if CHECK=$(api GET "$KC_URL/admin/realms/$REALM/clients/$CLIENT_UUID/default-client-scopes") && \
    jq -e --arg id "$SCOPE_ID" 'any(.[]; .id==$id)' <<< "$CHECK" >/dev/null; then
    echo "VERIFIED: $CLIENT_ID"; ((VERIFIED+=1))
  else
    echo "FAILED: $CLIENT_ID (verification)"; ((FAILED+=1))
  fi
done <<< "$CLIENT_LIST"
# ============================================================
# Final OpenID Client Scope Configuration Summary
# ============================================================

TOTAL_CLIENTS=$(printf '%s\n' "$CLIENT_LIST" | awk 'NF' | wc -l)

# Client scope creation status
if [[ "$CREATED" -eq 1 ]]; then
  SCOPE_STATUS="Created successfully"
  DESCRIPTION_STATUS="Configured during scope creation"
else
  SCOPE_STATUS="Already exists"

  if [[ "$DESCRIPTION_UPDATED" -eq 1 ]]; then
    DESCRIPTION_STATUS="Updated successfully"
  else
    DESCRIPTION_STATUS="Existing description retained"
  fi
fi

# Verify realm-level default scope
REALM_SCOPE_STATUS="Verification failed"
FUTURE_CLIENT_STATUS="Not verified"

if REALM_DEFAULT_SCOPES=$(api GET \
  "$KC_URL/admin/realms/$REALM/default-default-client-scopes"); then

  if jq -e --arg id "$SCOPE_ID" \
    'any(.[]; .id == $id)' \
    <<< "$REALM_DEFAULT_SCOPES" >/dev/null; then

    REALM_SCOPE_STATUS="Default"
    FUTURE_CLIENT_STATUS="Automatic assignment enabled"

  else

    REALM_SCOPE_STATUS="Not assigned as Default"
    FUTURE_CLIENT_STATUS="Manual assignment required"

  fi
fi

# Determine execution result
if [[ "$FAILED" -eq 0 &&
      "$VERIFIED" -eq "$TOTAL_CLIENTS" &&
      "$REALM_SCOPE_STATUS" == "Default" ]]; then

  FINAL_STATUS="SUCCESS"

else

  FINAL_STATUS="FAILED"

fi

# Display final summary
echo
echo "================================================================"
echo "            KEYCLOAK OPENID CONFIGURATION SUMMARY"
echo "================================================================"

printf "%-35s : %s\n" "Keycloak URL" "$KC_URL"
printf "%-35s : %s\n" "Realm" "$REALM"
printf "%-35s : %s\n" "Client scope name" "openid"
printf "%-35s : %s\n" "Client scope status" "$SCOPE_STATUS"
printf "%-35s : %s\n" "Scope description" "$DESCRIPTION_STATUS"
printf "%-35s : %s\n" "Realm-level scope type" "$REALM_SCOPE_STATUS"

echo "----------------------------------------------------------------"
echo "                  CLIENT ASSIGNMENT DETAILS"
echo "----------------------------------------------------------------"

printf "%-35s : %d\n" "Total eligible clients" "$TOTAL_CLIENTS"
printf "%-35s : %d\n" "Newly assigned clients" "$ADDED"
printf "%-35s : %d\n" "Previously assigned clients" "$SKIPPED"
printf "%-35s : %d\n" "Successfully verified clients" "$VERIFIED"
printf "%-35s : %d\n" "Failed operations" "$FAILED"

echo "----------------------------------------------------------------"

printf "%-35s : %s\n" "Future OIDC clients" "$FUTURE_CLIENT_STATUS"
printf "%-35s : %s\n" "Keycloak restart required" "No"
printf "%-35s : %s\n" "Final configuration status" "$FINAL_STATUS"

echo "================================================================"

if [[ "$FINAL_STATUS" == "SUCCESS" ]]; then

  echo
  echo "[SUCCESS] OpenID client scope configuration completed."

  if [[ "$CREATED" -eq 1 ]]; then
    echo "[SUCCESS] OpenID client scope created successfully."
  else
    echo "[SUCCESS] Existing OpenID client scope retained."
  fi

  if [[ "$ADDED" -gt 0 ]]; then
    echo "[SUCCESS] OpenID assigned to $ADDED new clients."
  fi

  if [[ "$SKIPPED" -gt 0 ]]; then
    echo "[INFO] $SKIPPED clients were already configured."
  fi

  echo "[SUCCESS] All $VERIFIED eligible clients verified."
  echo "[SUCCESS] Realm-level Default scope verified."
  echo "[INFO] Newly created OIDC clients will inherit openid."
  echo "[INFO] No Keycloak restart is required."

else

  echo
  echo "[ERROR] OpenID configuration verification failed."
  echo "[INFO] Review the failed operations reported above."
  echo "[INFO] The script can be rerun to complete configuration."
  exit 1

fi

echo "================================================================"

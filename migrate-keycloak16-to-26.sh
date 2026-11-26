
#!/usr/bin/env bash
set -euo pipefail
umask 077

# ============================================================
# Keycloak 16 to Keycloak 26 - MOSIP Realm Migration
# ============================================================

usage() {
  echo "Usage: $0 <keycloak-base-url> [export-directory]"
  echo "Example: $0 https://iam.example.org/auth ~/keycloak16-bkp"
}

[[ $# -ge 1 && $# -le 2 ]] || {
  usage
  exit 2
}

BASE="${1%/}"
DIR="${2:-.}"
REALM="mosip"

TOKEN=""
TOKEN_EXPIRY=0

# ------------------------------------------------------------
# Check dependencies
# ------------------------------------------------------------

for bin in curl jq diff mktemp; do
  command -v "$bin" >/dev/null || {
    echo "Missing dependency: $bin" >&2
    exit 1
  }
done

# ------------------------------------------------------------
# Validate input files
# ------------------------------------------------------------

for f in mosip-realm.json mosip-users-0.json mosip-users-1.json; do
  [[ -s "$DIR/$f" ]] || {
    echo "Missing input: $DIR/$f" >&2
    exit 1
  }

  jq -e . "$DIR/$f" >/dev/null
done

jq -e '.realm == "mosip" and (.clients | type == "array")' \
  "$DIR/mosip-realm.json" >/dev/null

TMP=$(mktemp -d)

cleanup() {
  unset ADMIN_PASSWORD TOKEN AUTH_RESPONSE
  rm -rf "$TMP"
}

trap cleanup EXIT

# ------------------------------------------------------------
# Admin credentials
# ------------------------------------------------------------

read -rp "Keycloak admin username: " ADMIN_USER
read -rsp "Keycloak admin password: " ADMIN_PASSWORD
echo

# ------------------------------------------------------------
# Generate a fresh admin access token
# ------------------------------------------------------------

get_token() {
  local response expires issued

  issued=$(date +%s)

  response=$(curl --fail-with-body -sS \
    -X POST "$BASE/realms/master/protocol/openid-connect/token" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode 'client_id=admin-cli' \
    --data-urlencode "username=$ADMIN_USER" \
    --data-urlencode "password=$ADMIN_PASSWORD") || {
      echo "Admin authentication failed." >&2
      exit 1
    }

  TOKEN=$(jq -er '.access_token | select(length > 0)' \
    <<< "$response")

  expires=$(jq -er '.expires_in | numbers' <<< "$response")

  TOKEN_EXPIRY=$((issued + expires))

  echo "Admin access token generated. Validity: ${expires}s"
}

# ------------------------------------------------------------
# Renew token before expiration
# ------------------------------------------------------------

ensure_token() {
  local now
  now=$(date +%s)

  if [[ -z "$TOKEN" ]] || (( now + 15 >= TOKEN_EXPIRY )); then
    get_token
  fi
}

# ------------------------------------------------------------
# Authenticated GET request
# Automatically retry once on HTTP 401
# ------------------------------------------------------------

api_get() {
  local endpoint="$1"
  local output="$2"
  local status

  ensure_token >&2

  status=$(curl -sS \
    -o "$output" \
    -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$BASE$endpoint") || return 1

  if [[ "$status" == "401" ]]; then
    echo "Admin token expired. Generating fresh token." >&2

    get_token >&2

    status=$(curl -sS \
      -o "$output" \
      -w '%{http_code}' \
      -H "Authorization: Bearer $TOKEN" \
      "$BASE$endpoint") || return 1
  fi

  if [[ "$status" != "200" ]]; then
    echo "GET $endpoint failed (HTTP $status)" >&2
    return 1
  fi
}

# ------------------------------------------------------------
# Merge exported user files
# ------------------------------------------------------------

jq -se '
  if (
    length == 2 and
    all(.[]; .realm == "mosip" and (.users | type) == "array")
  )
  then {users: [.[].users[]]}
  else error("Expected two mosip user exports")
  end
' "$DIR/mosip-users-0.json" \
  "$DIR/mosip-users-1.json" > "$TMP/users.json"

# Verify user records are unchanged

diff -q \
  <(jq -sS '[.[].users[]] | sort_by(.username)' \
    "$DIR/mosip-users-0.json" \
    "$DIR/mosip-users-1.json") \
  <(jq -S '.users | sort_by(.username)' \
    "$TMP/users.json") >/dev/null

# Check usernames and duplicates

jq -e '
  all(.users[]; (.username | type) == "string") and
  (
    ([.users[].username] | length) ==
    ([.users[].username] | unique | length)
  )
' "$TMP/users.json" >/dev/null || {
  echo "Invalid or duplicate usernames detected." >&2
  exit 1
}

# ------------------------------------------------------------
# Calculate expected counts separately
# ------------------------------------------------------------

TOTAL_USERS=$(jq '.users | length' "$TMP/users.json")

EXPECTED_USERS=$(jq '
  [.users[] |
    select((.serviceAccountClientId // "") == "")
  ] | length
' "$TMP/users.json")

EXPECTED_SA=$(jq '
  [.users[] |
    select((.serviceAccountClientId // "") != "")
  ] | length
' "$TMP/users.json")

jq -r '
  .users[] |
  select((.serviceAccountClientId // "") != "") |
  .serviceAccountClientId
' "$TMP/users.json" | sort -u > "$TMP/expected-sa.txt"

echo
echo "=============================================="
echo "Source Keycloak 16 Export Summary"
echo "=============================================="
echo "Total exported records : $TOTAL_USERS"
echo "Normal users           : $EXPECTED_USERS"
echo "Service accounts       : $EXPECTED_SA"
echo "=============================================="

# ------------------------------------------------------------
# Check whether target realm already exists
# ------------------------------------------------------------

get_token

STATUS=$(curl -sS \
  -o /dev/null \
  -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" \
  "$BASE/admin/realms/$REALM")

case "$STATUS" in
  200)
    echo "Realm '$REALM' already exists."
    echo "Skipping import. Running verification only."
    REALM_EXISTS=true
    ;;

  404)
    echo "Realm '$REALM' does not exist."
    REALM_EXISTS=false
    ;;

  *)
    echo "Cannot check realm (HTTP $STATUS)." >&2
    exit 1
    ;;
esac

# ------------------------------------------------------------
# Prepare and import only if realm does not exist
# ------------------------------------------------------------

if [[ "$REALM_EXISTS" == "false" ]]; then

  # Remove JavaScript policies and directly dependent
  # resource/scope permissions.
  # Stop on unsupported policy references.

  jq -e '
    .clients |= map(
      if (.authorizationSettings? | type) == "object" then
        .authorizationSettings |= (
          (.policies // []) as $all

          | [$all[] |
              select(.type == "js") |
              .name
            ] as $jsnames

          | .policies = [
              $all[]
              | . as $p

              | (.config.applyPolicies? // "[]") as $raw

              | (
                  if ($raw | type) == "string"
                  then ($raw | fromjson?)
                  else $raw
                  end
                ) as $refs

              | if $refs == null then
                  error("Invalid applyPolicies in " +
                    ($p.name // "unnamed"))
                else .
                end

              | if ($refs | type) != "array" then
                  error("Unexpected applyPolicies type")
                else .
                end

              | (
                  [$refs[] |
                    select(
                      . as $ref |
                      $jsnames |
                      index($ref) != null
                    )
                  ] | length
                ) as $hits

              | if .type == "js" then
                  empty

                elif $hits > 0 and
                  (.type == "resource" or .type == "scope")
                then
                  empty

                elif $hits > 0 then
                  error("Unsupported dependent policy: " +
                    (.name // "unnamed"))

                else .
                end
            ]
        )
      else .
      end
    )
  ' "$DIR/mosip-realm.json" > "$TMP/realm.json"

  # Embed all exported users, including service accounts

  jq -e --slurpfile u "$TMP/users.json" '
    .realm = "mosip" |
    .users = $u[0].users
  ' "$TMP/realm.json" > "$TMP/import.json"

  # Generate reviewable migration artifacts

  cp "$TMP/realm.json" "$DIR/mosip-realm-kc26.json"
  cp "$TMP/users.json" "$DIR/mosip-users-kc26.json"

  diff -u \
    <(jq -S . "$DIR/mosip-realm.json") \
    <(jq -S . "$TMP/realm.json") \
    > "$DIR/realm-changes.diff" || test "$?" -eq 1

  chmod 600 \
    "$DIR/mosip-realm-kc26.json" \
    "$DIR/mosip-users-kc26.json" \
    "$DIR/realm-changes.diff"

  echo
  echo "Prepared migration files:"
  echo "$DIR/mosip-realm-kc26.json"
  echo "$DIR/mosip-users-kc26.json"
  echo "$DIR/realm-changes.diff"

  echo
  echo "Prepared $TOTAL_USERS user records."
  echo "Normal users     : $EXPECTED_USERS"
  echo "Service accounts : $EXPECTED_SA"
  echo
  echo "Review realm-changes.diff before importing."

  read -rp "Create realm '$REALM' on $BASE now? [y/N]: " CONFIRM

  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Import cancelled. Prepared files retained."
    exit 0
  fi

  # Always generate a fresh token immediately before import

  get_token

  echo "Importing MOSIP realm and users..."

  HTTP=$(curl -sS \
    -o "$TMP/create-response" \
    -w '%{http_code}' \
    -X POST "$BASE/admin/realms" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    --data-binary @"$TMP/import.json") || {
      echo "Import request failed or connection was interrupted." >&2
      echo "Check whether the realm exists before retrying." >&2
      exit 1
    }

  if [[ "$HTTP" != "201" && "$HTTP" != "204" ]]; then
    echo "Realm creation failed (HTTP $HTTP)." >&2
    cat "$TMP/create-response" >&2
    echo >&2
    exit 1
  fi

  echo "Realm '$REALM' created successfully (HTTP $HTTP)."

else

  echo "Existing realm will not be modified."

fi

# ------------------------------------------------------------
# Generate fresh token for post-import verification
# ------------------------------------------------------------

get_token

echo
echo "Starting migration verification..."

VERIFY_FAILED=0

# ------------------------------------------------------------
# Verify realm
# ------------------------------------------------------------

api_get "/admin/realms/$REALM" "$TMP/verify-realm.json"

jq -e --arg realm "$REALM" \
  '.realm == $realm' "$TMP/verify-realm.json" >/dev/null || {
    echo "Realm verification failed." >&2
    exit 1
  }

echo "Realm verification: PASSED"

# ------------------------------------------------------------
# Verify normal user count
# ------------------------------------------------------------

api_get \
  "/admin/realms/$REALM/users/count" \
  "$TMP/user-count.json"

USER_COUNT=$(jq -er 'select(type == "number")' \
  "$TMP/user-count.json")

if [[ "$USER_COUNT" == "$EXPECTED_USERS" ]]; then
  echo "Normal user count verification: PASSED"
else
  echo "Normal user count verification: FAILED"
  VERIFY_FAILED=1
fi

# ------------------------------------------------------------
# Retrieve clients with pagination
# ------------------------------------------------------------

FIRST=0
PAGE_SIZE=100
echo '[]' > "$TMP/clients.json"

while true; do

  api_get \
    "/admin/realms/$REALM/clients?first=$FIRST&max=$PAGE_SIZE" \
    "$TMP/client-page.json"

  PAGE_COUNT=$(jq -er '
    if type == "array" then length
    else error("Invalid client response")
    end
  ' "$TMP/client-page.json")

  jq -s '.[0] + .[1]' \
    "$TMP/clients.json" \
    "$TMP/client-page.json" > "$TMP/clients-next.json"

  mv "$TMP/clients-next.json" "$TMP/clients.json"

  if (( PAGE_COUNT < PAGE_SIZE )); then
    break
  fi

  FIRST=$((FIRST + PAGE_COUNT))

done

CLIENT_COUNT=$(jq 'length' "$TMP/clients.json")

# ------------------------------------------------------------
# Verify service-account-enabled clients
# ------------------------------------------------------------

jq -r '
  .[] |
  select(.serviceAccountsEnabled == true) |
  .clientId
' "$TMP/clients.json" | sort -u > "$TMP/actual-sa.txt"

ACTUAL_SA=$(jq '
  [.[] |
    select(.serviceAccountsEnabled == true)
  ] | length
' "$TMP/clients.json")

if [[ "$ACTUAL_SA" == "$EXPECTED_SA" ]] &&
   diff -q "$TMP/expected-sa.txt" \
           "$TMP/actual-sa.txt" >/dev/null; then

  echo "Service account client verification: PASSED"

else

  echo "Service account client verification: FAILED"

  diff -u "$TMP/expected-sa.txt" \
          "$TMP/actual-sa.txt" || true

  VERIFY_FAILED=1

fi

# ------------------------------------------------------------
# Verify actual service account users
# ------------------------------------------------------------

VERIFIED_SA=0

while IFS=$'\t' read -r SA_USERNAME SA_CLIENT; do

  [[ -n "$SA_CLIENT" ]] || continue

  CLIENT_UUID=$(jq -r --arg client "$SA_CLIENT" '
    [.[] | select(.clientId == $client)] |
    if length == 1 then .[0].id else empty end
  ' "$TMP/clients.json")

  if [[ -z "$CLIENT_UUID" ]]; then
    echo "Missing client: $SA_CLIENT"
    VERIFY_FAILED=1
    continue
  fi

  if api_get \
    "/admin/realms/$REALM/clients/$CLIENT_UUID/service-account-user" \
    "$TMP/service-account.json" &&
    jq -e --arg username "$SA_USERNAME" '
      .username == $username and
      (.id | type == "string")
    ' "$TMP/service-account.json" >/dev/null; then

    VERIFIED_SA=$((VERIFIED_SA + 1))

  else

    echo "Service account verification failed: $SA_USERNAME"
    VERIFY_FAILED=1

  fi

done < <(
  jq -r '
    .users[] |
    select((.serviceAccountClientId // "") != "") |
    [.username, .serviceAccountClientId] |
    @tsv
  ' "$TMP/users.json"
)

# ------------------------------------------------------------
# Verify exported client names
# ------------------------------------------------------------

jq -r '.clients[].clientId' \
  "$DIR/mosip-realm.json" |
  sort -u > "$TMP/expected-clients.txt"

jq -r '.[].clientId' \
  "$TMP/clients.json" |
  sort -u > "$TMP/actual-clients.txt"

comm -23 \
  "$TMP/expected-clients.txt" \
  "$TMP/actual-clients.txt" > "$TMP/missing-clients.txt"

if [[ -s "$TMP/missing-clients.txt" ]]; then

  echo "Missing exported clients:"
  cat "$TMP/missing-clients.txt"
  VERIFY_FAILED=1

else

  echo "Exported client verification: PASSED"

fi

# ------------------------------------------------------------
# Final migration summary
# ------------------------------------------------------------

echo
echo "=================================================="
echo "         KEYCLOAK MIGRATION SUMMARY"
echo "=================================================="
echo "Target URL                  : $BASE"
echo "Realm                       : $REALM"
echo "Total exported records      : $TOTAL_USERS"
echo "Expected normal users       : $EXPECTED_USERS"
echo "Imported normal users       : $USER_COUNT"
echo "Expected service accounts   : $EXPECTED_SA"
echo "Service-account clients     : $ACTUAL_SA"
echo "Verified service accounts   : $VERIFIED_SA"
echo "Total accounted records     : $((USER_COUNT + VERIFIED_SA))"
echo "Total target clients        : $CLIENT_COUNT"
echo "=================================================="

if [[ "$VERIFY_FAILED" == "0" ]] &&
   [[ "$VERIFIED_SA" == "$EXPECTED_SA" ]]; then

  echo "MIGRATION COUNT AND CLIENT VERIFICATION: SUCCESS"

else

  echo "MIGRATION VERIFICATION: WARNING"
  echo "Review the mismatches reported above."
  exit 1

fi

# ------------------------------------------------------------
# Display imported theme configuration
# ------------------------------------------------------------

echo
echo "Imported realm theme configuration:"

jq '{
  loginTheme,
  adminTheme,
  accountTheme,
  emailTheme
}' "$TMP/verify-realm.json"

echo
echo "NOTE: Custom themes must be compatible with Keycloak 26."
echo "NOTE: Review removed JavaScript authorization policies."
echo "NOTE: Test existing user and client authentication."
echo
echo "Migration verification completed."


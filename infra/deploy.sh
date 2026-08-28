#!/usr/bin/env bash
# Deploy (or update) one todo list.
#
#   ./infra/deploy.sh          -> uses infra/config.work.env
#   ./infra/deploy.sh home     -> uses infra/config.home.env
#
# Safe to re-run: every step is create-or-update. First run for a new name
# generates the config file with fresh secrets and stops so you can edit it.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:-work}"
CFG="infra/config.$NAME.env"
say()  { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$1"; }
sha256_hex() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }

# ---------- 0. preflight ----------
for t in aws node npm zip curl; do
  command -v "$t" >/dev/null 2>&1 || die "'$t' is not installed."
done

if [ ! -f "$CFG" ]; then
  [ -f infra/config.example.env ] || die "missing infra/config.example.env"
  PW=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 20 || true)
  SECRET=$(openssl rand -hex 32)
  sed -e "s|^PASSWORD=.*|PASSWORD=$PW|" \
      -e "s|^TOKEN_SECRET=.*|TOKEN_SECRET=$SECRET|" \
      infra/config.example.env > "$CFG"
  chmod 600 "$CFG"
  cat <<MSG

Created $CFG with a fresh passphrase and token secret.

  Now edit it — at minimum PROFILE and EMAIL — then run:
      ./infra/deploy.sh $NAME

  Your passphrase for this list: $PW
MSG
  exit 0
fi

set -a; . "$CFG"; set +a
for v in REGION APP EMAIL TIMEZONE SWEEP PASSWORD TOKEN_SECRET; do
  [ -n "${!v:-}" ] || die "$v is not set in $CFG"
done
case "$EMAIL" in you@example.com|"") die "set a real EMAIL in $CFG";; esac
PROFILE="${PROFILE:-}"
FRONTDOOR="${FRONTDOOR:-auto}"

AWSP=(aws ${PROFILE:+--profile "$PROFILE"})
AWSR=("${AWSP[@]}" --region "$REGION" --output json)
TABLE="$APP"; FUNC="$APP"; ROLE="$APP-lambda"; RULE="$APP-sweep"

say "Target account"
IDENT=$("${AWSP[@]}" sts get-caller-identity --output text 2>/dev/null) \
  || die "no working AWS credentials for profile '${PROFILE:-default}'. Run: aws configure${PROFILE:+ --profile $PROFILE}"
ACCT=$(echo "$IDENT" | cut -f1); ARN=$(echo "$IDENT" | cut -f2)
echo "  $ACCT  ($ARN)"
echo "  profile=${PROFILE:-default}  region=$REGION  app=$APP"

# Guard against deploying one list into the other's account.
if [ -n "${ACCOUNT:-}" ]; then
  [ "$ACCOUNT" = "$ACCT" ] || die "$CFG is pinned to account $ACCOUNT but these credentials are for $ACCT.
   Fix PROFILE in $CFG, or edit ACCOUNT if you really moved this list."
else
  printf '\nACCOUNT=%s\n' "$ACCT" >> "$CFG"
  echo "  pinned $CFG to this account"
fi

# ---------- 1. DynamoDB ----------
say "DynamoDB table $TABLE"
if "${AWSR[@]}" dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
  echo "  exists"
else
  "${AWSR[@]}" dynamodb create-table --table-name "$TABLE" \
    --attribute-definitions AttributeName=id,AttributeType=S \
    --key-schema AttributeName=id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  "${AWSR[@]}" dynamodb wait table-exists --table-name "$TABLE"
  echo "  created"
fi

# ---------- 2. IAM role ----------
say "IAM role $ROLE"
if "${AWSP[@]}" iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  echo "  exists"
else
  "${AWSP[@]}" iam create-role --role-name "$ROLE" --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},
                  "Action":"sts:AssumeRole"}]}' >/dev/null
  echo "  created"
fi
"${AWSP[@]}" iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
"${AWSP[@]}" iam put-role-policy --role-name "$ROLE" --policy-name app-access \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Effect\":\"Allow\",
       \"Action\":[\"dynamodb:GetItem\",\"dynamodb:PutItem\",\"dynamodb:UpdateItem\",
                   \"dynamodb:DeleteItem\",\"dynamodb:Scan\",\"dynamodb:Query\"],
       \"Resource\":\"arn:aws:dynamodb:$REGION:$ACCT:table/$TABLE\"},
      {\"Effect\":\"Allow\",\"Action\":[\"ses:SendEmail\"],
       \"Resource\":\"arn:aws:ses:$REGION:$ACCT:identity/*\"}]}"
ROLE_ARN="arn:aws:iam::$ACCT:role/$ROLE"

# ---------- 3. package ----------
say "Packaging"
[ -d lambda/node_modules/web-push ] || {
  echo "  installing dependencies…"
  (cd lambda && npm install --omit=dev --no-audit --no-fund >/dev/null)
}
rm -rf build build.zip && mkdir -p build
cp lambda/index.mjs lambda/page.html lambda/sw.js lambda/manifest.webmanifest \
   lambda/icon.png lambda/package.json build/
cp -r lambda/node_modules build/
(cd build && zip -qr ../build.zip .)
echo "  build.zip $(du -h build.zip | cut -f1)"

# ---------- 3b. web push keys ----------
CHANNELS="${CHANNELS:-email}"
case ",$CHANNELS," in
  *,push,*)
    if [ -z "${VAPID_PUBLIC:-}" ] || [ -z "${VAPID_PRIVATE:-}" ]; then
      say "Generating VAPID keys"
      KEYS=$(cd lambda && node -e \
        'const k=require("web-push").generateVAPIDKeys();console.log(k.publicKey);console.log(k.privateKey)')
      VAPID_PUBLIC=$(printf '%s' "$KEYS" | sed -n 1p)
      VAPID_PRIVATE=$(printf '%s' "$KEYS" | sed -n 2p)
      # Fill the template's empty slots if they are there, else append.
      if grep -q '^VAPID_PUBLIC=' "$CFG"; then
        sed -i.bak -e "s|^VAPID_PUBLIC=.*|VAPID_PUBLIC=$VAPID_PUBLIC|" \
                   -e "s|^VAPID_PRIVATE=.*|VAPID_PRIVATE=$VAPID_PRIVATE|" "$CFG" && rm -f "$CFG.bak"
      else
        { echo; echo "VAPID_PUBLIC=$VAPID_PUBLIC"; echo "VAPID_PRIVATE=$VAPID_PRIVATE"; } >> "$CFG"
      fi
      echo "  keypair written to $CFG (rotating it unsubscribes every device)"
    fi
    ;;
esac

PWHASH=$(printf '%s' "$PASSWORD" | sha256_hex)
# Built as JSON rather than the CLI's Key=Value shorthand, which cannot carry the
# comma in a multi-channel CHANNELS value.
TABLE="$TABLE" PWHASH="$PWHASH" TOKEN_SECRET="$TOKEN_SECRET" EMAIL="$EMAIL" \
TIMEZONE="$TIMEZONE" CHANNELS="$CHANNELS" VAPID_PUBLIC="${VAPID_PUBLIC:-}" \
VAPID_PRIVATE="${VAPID_PRIVATE:-}" VAPID_SUBJECT="${VAPID_SUBJECT:-mailto:$EMAIL}" \
node -e '
  const v = {
    TABLE: process.env.TABLE,
    PASSWORD_HASH: process.env.PWHASH,
    TOKEN_SECRET: process.env.TOKEN_SECRET,
    EMAIL_FROM: process.env.EMAIL,
    EMAIL_TO: process.env.EMAIL,
    TIMEZONE: process.env.TIMEZONE,
    CHANNELS: process.env.CHANNELS,
  };
  if (process.env.VAPID_PUBLIC) {
    v.VAPID_PUBLIC = process.env.VAPID_PUBLIC;
    v.VAPID_PRIVATE = process.env.VAPID_PRIVATE;
    v.VAPID_SUBJECT = process.env.VAPID_SUBJECT;
  }
  console.log(JSON.stringify({ Variables: v }));' > build/env.json
ENVFILE="file://build/env.json"

# ---------- 4. Lambda ----------
say "Lambda $FUNC"
if "${AWSR[@]}" lambda get-function --function-name "$FUNC" >/dev/null 2>&1; then
  "${AWSR[@]}" lambda update-function-code --function-name "$FUNC" --zip-file fileb://build.zip >/dev/null
  "${AWSR[@]}" lambda wait function-updated --function-name "$FUNC"
  "${AWSR[@]}" lambda update-function-configuration --function-name "$FUNC" \
    --environment "$ENVFILE" --timeout 15 --memory-size 512 >/dev/null
  "${AWSR[@]}" lambda wait function-updated --function-name "$FUNC"
  echo "  updated"
else
  created=no
  for i in 1 2 3 4 5 6; do
    if "${AWSR[@]}" lambda create-function --function-name "$FUNC" \
        --runtime nodejs22.x --handler index.handler --role "$ROLE_ARN" \
        --zip-file fileb://build.zip --timeout 15 --memory-size 512 \
        --environment "$ENVFILE" >/dev/null 2>&1; then
      created=yes; echo "  created"; break
    fi
    echo "  waiting for the new IAM role to propagate ($i/6)…"; sleep 8
  done
  [ "$created" = yes ] || die "could not create the Lambda. Re-run; if it persists, check your permissions."
  "${AWSR[@]}" lambda wait function-active-v2 --function-name "$FUNC"
fi
FUNC_ARN=$("${AWSR[@]}" lambda get-function --function-name "$FUNC" \
  --query Configuration.FunctionArn --output text)

# ---------- 5. public endpoint ----------
# Two options. A Lambda Function URL needs no gateway and is free forever, but
# some org-managed accounts block anonymous invokes (see README). An API Gateway
# HTTP API always works. FRONTDOOR=auto probes the cheap one and falls back.
ensure_function_url() {
  "${AWSR[@]}" lambda get-function-url-config --function-name "$FUNC" >/dev/null 2>&1 || {
    "${AWSR[@]}" lambda create-function-url-config --function-name "$FUNC" --auth-type NONE >/dev/null
    "${AWSR[@]}" lambda add-permission --function-name "$FUNC" --statement-id public-url \
      --action lambda:InvokeFunctionUrl --principal '*' --function-url-auth-type NONE >/dev/null 2>&1 || true
  }
  "${AWSR[@]}" lambda get-function-url-config --function-name "$FUNC" --query FunctionUrl --output text
}
drop_function_url() {
  "${AWSR[@]}" lambda delete-function-url-config --function-name "$FUNC" >/dev/null 2>&1 || true
  "${AWSR[@]}" lambda remove-permission --function-name "$FUNC" --statement-id public-url >/dev/null 2>&1 || true
}
probe() {  # 200 within ~40s?
  for i in 1 2 3 4 5; do
    [ "$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$1")" = 200 ] && return 0
    sleep 8
  done
  return 1
}
ensure_api() {
  local id
  id=$("${AWSR[@]}" apigatewayv2 get-apis --query "Items[?Name=='$APP'].ApiId | [0]" --output text)
  if [ "$id" = None ] || [ -z "$id" ]; then
    id=$("${AWSR[@]}" apigatewayv2 create-api --name "$APP" --protocol-type HTTP \
      --target "$FUNC_ARN" --query ApiId --output text)
  fi
  # Source ARN must be <api-id>/* — narrower patterns such as /*/*/* fail to match
  # root-path requests on a $default route and surface as an opaque 500.
  "${AWSR[@]}" lambda add-permission --function-name "$FUNC" --statement-id apigw-invoke \
    --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:$REGION:$ACCT:$id/*" >/dev/null 2>&1 || true
  "${AWSR[@]}" apigatewayv2 get-api --api-id "$id" --query ApiEndpoint --output text
}

say "Public endpoint (FRONTDOOR=$FRONTDOOR)"
EXISTING_API=$("${AWSR[@]}" apigatewayv2 get-apis --query "Items[?Name=='$APP'].ApiId | [0]" --output text)
URL=""
case "$FRONTDOOR" in
  url)
    URL=$(ensure_function_url); echo "  Lambda Function URL"
    probe "$URL" || warn "that URL is not answering 200 — this account may block anonymous
    Function URL invokes. Set FRONTDOOR=apigw in $CFG and re-run."
    ;;
  apigw)
    URL=$(ensure_api); echo "  API Gateway HTTP API"; drop_function_url
    ;;
  auto)
    if [ "$EXISTING_API" != None ] && [ -n "$EXISTING_API" ]; then
      URL=$(ensure_api); echo "  API Gateway HTTP API (keeping the endpoint you already use)"
    else
      CAND=$(ensure_function_url)
      if probe "$CAND"; then
        URL="$CAND"; echo "  Lambda Function URL works — no gateway needed"
      else
        echo "  Function URL blocked in this account; falling back to API Gateway"
        drop_function_url; URL=$(ensure_api)
      fi
    fi
    ;;
  *) die "FRONTDOOR must be auto, url or apigw (got '$FRONTDOOR')";;
esac
echo "  $URL"

# ---------- 6. SES ----------
say "SES sender $EMAIL"
if "${AWSR[@]}" sesv2 get-email-identity --email-identity "$EMAIL" >/dev/null 2>&1; then
  VERIFIED=$("${AWSR[@]}" sesv2 get-email-identity --email-identity "$EMAIL" \
    --query VerifiedForSendingStatus --output text)
  if [ "$VERIFIED" = True ]; then
    echo "  verified"
  else
    warn "NOT verified yet — reminder emails will fail until you click the link in the
    'Amazon Web Services – Email Address Verification' message sent to $EMAIL."
  fi
else
  "${AWSR[@]}" sesv2 create-email-identity --email-identity "$EMAIL" >/dev/null
  warn "verification email sent to $EMAIL — click the link in it, then re-run this
    script to confirm. Reminder emails fail until then."
fi

# ---------- 7. reminder schedule ----------
say "Schedule $RULE ($SWEEP)"
RULE_ARN=$("${AWSR[@]}" events put-rule --name "$RULE" --schedule-expression "$SWEEP" \
  --state ENABLED --query RuleArn --output text)
"${AWSR[@]}" lambda add-permission --function-name "$FUNC" --statement-id sweep-invoke \
  --action lambda:InvokeFunction --principal events.amazonaws.com \
  --source-arn "$RULE_ARN" >/dev/null 2>&1 || true
cat > build/targets.json <<JSON
[{"Id":"sweep","Arn":"$FUNC_ARN","Input":"{\"op\":\"sweep\"}"}]
JSON
"${AWSR[@]}" events put-targets --rule "$RULE" --targets file://build/targets.json >/dev/null
echo "  ok"

say "Done — '$NAME' list is live"
echo "  URL:        $URL"
echo "  Passphrase: $PASSWORD"
echo "  Config:     $CFG"

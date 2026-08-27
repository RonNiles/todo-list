#!/usr/bin/env bash
# Delete every resource one deploy created, including all todos in it.
#
#   ./infra/destroy.sh          -> the 'work' list
#   ./infra/destroy.sh home     -> the 'home' list
#
# Leaves the config file, the verified SES identity, and CloudWatch logs alone.
set -uo pipefail
cd "$(dirname "$0")/.."

NAME="${1:-work}"
CFG="infra/config.$NAME.env"
[ -f "$CFG" ] || { echo "no such config: $CFG" >&2; exit 1; }
set -a; . "$CFG"; set +a
PROFILE="${PROFILE:-}"
AWSP=(aws ${PROFILE:+--profile "$PROFILE"})
AWSR=("${AWSP[@]}" --region "$REGION" --output json)

ACCT=$("${AWSP[@]}" sts get-caller-identity --query Account --output text) || exit 1
if [ -n "${ACCOUNT:-}" ] && [ "$ACCOUNT" != "$ACCT" ]; then
  echo "refusing: $CFG is pinned to account $ACCOUNT, credentials are for $ACCT" >&2
  exit 1
fi

echo "About to delete '$NAME' ($APP) from account $ACCT in $REGION."
echo "This destroys the DynamoDB table and every todo in it."
read -rp "Type the app name to confirm [$APP]: " ok
[ "$ok" = "$APP" ] || { echo "aborted"; exit 1; }

API_ID=$("${AWSR[@]}" apigatewayv2 get-apis --query "Items[?Name=='$APP'].ApiId | [0]" --output text)
[ "$API_ID" != None ] && [ -n "$API_ID" ] && "${AWSR[@]}" apigatewayv2 delete-api --api-id "$API_ID"
"${AWSR[@]}" events remove-targets --rule "$APP-sweep" --ids sweep >/dev/null 2>&1
"${AWSR[@]}" events delete-rule --name "$APP-sweep" >/dev/null 2>&1
"${AWSR[@]}" lambda delete-function --function-name "$APP" >/dev/null 2>&1
"${AWSR[@]}" dynamodb delete-table --table-name "$APP" >/dev/null 2>&1
"${AWSP[@]}" iam delete-role-policy --role-name "$APP-lambda" --policy-name app-access >/dev/null 2>&1
"${AWSP[@]}" iam detach-role-policy --role-name "$APP-lambda" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null 2>&1
"${AWSP[@]}" iam delete-role --role-name "$APP-lambda" >/dev/null 2>&1
echo "deleted. (SES identity and /aws/lambda/$APP logs left in place)"

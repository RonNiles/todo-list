#!/usr/bin/env bash
# Talk to a deployed list from the shell.
#
#   ./infra/api.sh [name] <command> [args]
#
# 'name' defaults to 'work' and picks infra/config.<name>.env, so the same
# commands reach either list. Run with no arguments for help.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=work
KNOWN=" url token list json raw add done rm table sweep env logs state push testpush help -h --help "
if [ $# -gt 0 ] && [ -n "$1" ] && [[ "$KNOWN" != *" $1 "* ]]; then
  NAME="$1"; shift
  [ -f "infra/config.$NAME.env" ] || {
    echo "no such list: '$NAME' (expected infra/config.$NAME.env)" >&2
    echo "available: $(ls infra/config.*.env 2>/dev/null | sed 's|.*/config\.||; s|\.env$||' \
      | grep -v '^example$' | tr '\n' ' ')" >&2
    exit 1; }
fi
CMD="${1:-help}"; [ $# -gt 0 ] && shift

CFG="infra/config.$NAME.env"
[ -f "$CFG" ] || { echo "no such config: $CFG" >&2; exit 1; }
set -a; . "$CFG"; set +a
PROFILE="${PROFILE:-}"
AWSR=(aws ${PROFILE:+--profile "$PROFILE"} --region "$REGION" --output json)
TOKFILE=".token.$NAME"

# ---------- endpoint ----------
endpoint() {
  local u
  u=$("${AWSR[@]}" lambda get-function-url-config --function-name "$APP" \
        --query FunctionUrl --output text 2>/dev/null) || u=""
  if [ -z "$u" ] || [ "$u" = None ]; then
    local id
    id=$("${AWSR[@]}" apigatewayv2 get-apis --query "Items[?Name=='$APP'].ApiId | [0]" --output text)
    [ "$id" = None ] && { echo "no endpoint found for $APP" >&2; exit 1; }
    u=$("${AWSR[@]}" apigatewayv2 get-api --api-id "$id" --query ApiEndpoint --output text)
  fi
  echo "${u%/}"
}
URL="${TODO_URL:-$(endpoint)}"

# ---------- auth ----------
login() {
  local t
  t=$(curl -s -X POST "$URL/api" -H 'content-type: application/json' \
        -d "{\"op\":\"login\",\"password\":\"$PASSWORD\"}" \
      | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
          const j=JSON.parse(s||"{}"); if(!j.token){console.error("login failed:",j.error||s);process.exit(1)}
          console.log(j.token)})')
  printf '%s' "$t" > "$TOKFILE"; chmod 600 "$TOKFILE"; printf '%s' "$t"
}
token() { [ -s "$TOKFILE" ] && cat "$TOKFILE" || login; }

# One retry so an expired cached token refreshes itself instead of erroring.
call() {
  local body="$1" out
  out=$(curl -s -X POST "$URL/api" -H 'content-type: application/json' \
          -H "authorization: Bearer $(token)" -d "$body")
  if [ "$out" = '{"error":"unauthorized"}' ]; then
    rm -f "$TOKFILE"
    out=$(curl -s -X POST "$URL/api" -H 'content-type: application/json' \
            -H "authorization: Bearer $(token)" -d "$body")
  fi
  printf '%s' "$out"
}

pretty() { node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    let j; try{ j=JSON.parse(s) }catch{ console.log(s); return }
    const todos = j.todos || (j.todo?[j.todo]:null);
    if(!todos){ console.log(JSON.stringify(j,null,2)); return }
    if(!todos.length){ console.log("(empty)"); return }
    const key = t => t.remindAt ? Date.parse(t.remindAt) : 8.64e15;
    todos.sort((a,b)=> (a.done?1:0)-(b.done?1:0) || key(a)-key(b));
    const now = Date.now();
    const when = t => {
      if(!t.remindAt) return "";
      const d = new Date(t.remindAt);
      const s = d.toLocaleString([], {month:"short",day:"numeric",hour:"numeric",minute:"2-digit"});
      return (!t.done && d < now ? "! " : "  ") + s + (t.notified ? " (sent)" : "");
    };
    const w = Math.max(...todos.map(t=>when(t).length), 4);
    for(const t of todos){
      console.log([
        t.done ? "[x]" : "[ ]",
        t.id.slice(0,8),
        when(t).padEnd(w),
        t.text + (t.notes ? "  — " + t.notes : ""),
      ].join("  "));
    }
    const open = todos.filter(t=>!t.done).length;
    console.log(`\n${todos.length} item(s), ${open} open`);
  });'
}

case "$CMD" in
  url)    echo "$URL";;
  token)  token; echo;;
  list)   call '{"op":"list"}' | pretty;;
  json)   call '{"op":"list"}' | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.stringify(JSON.parse(s),null,2)))';;
  raw)    [ $# -ge 1 ] || { echo 'usage: raw '"'"'{"op":"list"}'"'"'' >&2; exit 1; }
          call "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.stringify(JSON.parse(s),null,2))}catch{console.log(s)}})';;
  add)    [ $# -ge 1 ] || { echo 'usage: add "text" ["2026-09-01 17:00"]' >&2; exit 1; }
          B=$(TEXT="$1" WHEN="${2:-}" node -e '
            const when = process.env.WHEN
              ? new Date(process.env.WHEN.replace(" ","T")).toISOString() : null;
            console.log(JSON.stringify({op:"create", text:process.env.TEXT, remindAt:when}));')
          call "$B" | pretty;;
  done)   [ $# -ge 1 ] || { echo "usage: done <id-prefix>" >&2; exit 1; }
          ID=$(call '{"op":"list"}' | ID="$1" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
            const m=JSON.parse(s).todos.filter(t=>t.id.startsWith(process.env.ID));
            if(m.length!==1){console.error(m.length?"ambiguous prefix":"no match");process.exit(1)}
            console.log(m[0].id)})')
          call "{\"op\":\"update\",\"id\":\"$ID\",\"done\":true}" | pretty;;
  rm)     [ $# -ge 1 ] || { echo "usage: rm <id-prefix>" >&2; exit 1; }
          ID=$(call '{"op":"list"}' | ID="$1" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
            const m=JSON.parse(s).todos.filter(t=>t.id.startsWith(process.env.ID));
            if(m.length!==1){console.error(m.length?"ambiguous prefix":"no match");process.exit(1)}
            console.log(m[0].id)})')
          call "{\"op\":\"delete\",\"id\":\"$ID\"}"; echo;;
  push)   call '{"op":"pushStatus"}' | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
            const j=JSON.parse(s);
            console.log("push:  " + (j.enabled ? "enabled" : "disabled (CHANNELS has no push, or no VAPID keys)"));
            if (j.enabled) console.log("devices subscribed: " + j.subs);})';;
  testpush) call '{"op":"testPush"}' | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(s))'; echo;;
  table)  "${AWSR[@]}" dynamodb scan --table-name "$APP";;
  sweep)  OUT=$(mktemp)
          "${AWSR[@]}" lambda invoke --function-name "$APP" \
            --cli-binary-format raw-in-base64-out --payload '{"op":"sweep"}' "$OUT" >/dev/null
          cat "$OUT"; echo; rm -f "$OUT";;
  env)    "${AWSR[@]}" lambda get-function-configuration --function-name "$APP" \
            --query 'Environment.Variables' ;;
  logs)   aws ${PROFILE:+--profile "$PROFILE"} --region "$REGION" \
            logs tail "/aws/lambda/$APP" --since "${1:-30m}" --follow;;
  state)  echo "list:      $NAME ($CFG)"
          echo "account:   ${ACCOUNT:-?}  region: $REGION  app: $APP"
          echo "endpoint:  $URL"
          echo -n "http:      "; curl -s -o /dev/null -w '%{http_code} in %{time_total}s\n' "$URL/"
          echo -n "items:     "; "${AWSR[@]}" dynamodb describe-table --table-name "$APP" \
            --query 'Table.ItemCount' --output text
          echo -n "ses:       "; "${AWSR[@]}" sesv2 get-email-identity --email-identity "$EMAIL" \
            --query VerifiedForSendingStatus --output text 2>/dev/null || echo "not registered"
          echo -n "schedule:  "; "${AWSR[@]}" events list-rules --name-prefix "$APP-sweep" \
            --query 'Rules[0].[ScheduleExpression,State]' --output text
          echo; echo "open items:"; call '{"op":"list"}' | pretty;;
  help|*)
    cat <<EOF
usage: ./infra/api.sh [list-name] <command>     (list-name defaults to 'work')

inspect
  state              one-page summary: endpoint, item count, SES, schedule, items
  list               todos as a table
  json               todos as raw JSON
  table              raw DynamoDB scan (bypasses the API entirely)
  push               whether web push is on, and how many devices subscribed
  env                the Lambda's environment variables
  logs [since]       tail CloudWatch logs, e.g. logs 1h
  url                print the endpoint
  token              print a bearer token (cached in $TOKFILE)

change
  add "text" ["2026-09-01 17:00"]
  done <id-prefix>
  rm <id-prefix>
  raw '{"op":"clearDone"}'          any API call, verbatim
  sweep                            force the reminder run now
  testpush                         send a test notification to every device
EOF
    ;;
esac

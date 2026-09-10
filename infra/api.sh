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
KNOWN=" url token list json raw add done rm cancel uncancel table sweep env logs state push testpush every series stop help -h --help "
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
AWSR=(aws ${PROFILE:+--profile "$PROFILE"} --region "$REGION" --output json --no-cli-pager)
TOKFILE=".token.$NAME"
ENDPOINTFILE=".endpoint.$NAME"

# ---------- endpoint ----------
# deploy.sh writes the current URL to ENDPOINTFILE on every deploy, so this
# discovery (a handful of slow `aws` calls) only runs before that file exists.
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
if [ -n "${TODO_URL:-}" ]; then
  URL="$TODO_URL"
elif [ -s "$ENDPOINTFILE" ]; then
  URL=$(cat "$ENDPOINTFILE")
else
  URL=$(endpoint); printf '%s' "$URL" > "$ENDPOINTFILE"
fi

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

# Resolve an id prefix to exactly one id. Pass anything as $2 to search the
# cancelled archive too — uncancel needs that, the others deliberately do not.
resolve_id() {
  local list='{"op":"list"}'
  [ -n "${2:-}" ] && list='{"op":"list","includeCancelled":true}'
  call "$list" | ID="$1" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const m=JSON.parse(s).todos.filter(t=>t.id.startsWith(process.env.ID));
    if(m.length!==1){console.error(m.length?"ambiguous prefix":"no match");process.exit(1)}
    console.log(m[0].id)})'
}

# Series ids are "series#<uuid>"; match against the part after the prefix so
# short hex prefixes work the same way todo ids do.
resolve_series_id() {
  call '{"op":"seriesList"}' | ID="$1" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const m=JSON.parse(s).series.filter(x=>x.id.replace(/^series#/,"").startsWith(process.env.ID));
    if(m.length!==1){console.error(m.length?"ambiguous prefix":"no match");process.exit(1)}
    console.log(m[0].id)})'
}

pretty() { node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    let j; try{ j=JSON.parse(s) }catch{ console.log(s); return }
    const todos = j.todos || (j.todo?[j.todo]:null);
    if(!todos){ console.log(JSON.stringify(j,null,2)); return }
    if(!todos.length){ console.log("(empty)"); return }
    const key = t => t.remindAt ? Date.parse(t.remindAt) : 8.64e15;
    const rank = t => t.cancelled ? 2 : t.done ? 1 : 0;
    todos.sort((a,b)=> rank(a)-rank(b) || key(a)-key(b));
    const now = Date.now();
    const when = t => {
      if(!t.remindAt) return "";
      const d = new Date(t.remindAt);
      const s = d.toLocaleString([], {month:"short",day:"numeric",hour:"numeric",minute:"2-digit"});
      return (!t.done && d < now ? "! " : "  ") + s + (t.notified ? " (sent)" : "");
    };
    const stamp = (label, iso) => "  (" + label + " " +
      new Date(iso).toLocaleString([], {month:"short",day:"numeric",hour:"numeric",minute:"2-digit"}) + ")";
    const doneWhen = t => t.cancelled && t.cancelledAt ? stamp("cancelled", t.cancelledAt)
      : t.doneAt ? stamp("done", t.doneAt) : "";
    const w = Math.max(...todos.map(t=>when(t).length), 4);
    for(const t of todos){
      console.log([
        t.cancelled ? "[-]" : t.done ? "[x]" : "[ ]",
        t.id.slice(0,8),
        when(t).padEnd(w),
        t.text + (t.notes ? "  — " + t.notes : "") + doneWhen(t),
      ].join("  "));
    }
    const open = todos.filter(t=>!t.done && !t.cancelled).length;
    const cancelled = todos.filter(t=>t.cancelled).length;
    console.log(`\n${todos.length} item(s), ${open} open` +
      (cancelled ? `, ${cancelled} cancelled` : ""));
  });'
}

prettySeries() { node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    let j; try{ j=JSON.parse(s) }catch{ console.log(s); return }
    const rows = Array.isArray(j.series) ? j.series : (j.series ? [j.series] : null);
    if(!rows){ console.log(JSON.stringify(j,null,2)); return }
    if(!rows.length){ console.log("(no series)"); return }
    const fmt = iso => iso ? new Date(iso).toLocaleString([], {month:"short",day:"numeric",hour:"numeric",minute:"2-digit"}) : "-";
    for(const s of rows){
      const at = Number.isInteger(s.hour) ? ` @ ${String(s.hour).padStart(2,"0")}:${String(s.minute).padStart(2,"0")}` : "";
      const sched = s.kind === "cron"
        ? `day ${s.dayOfMonth} every ${s.intervalMonths}mo${at}  next ${fmt(s.nextDueAt)}`
        : `${s.afterDays}d after done${at}`;
      console.log([s.kind==="cron"?"[C]":"[A]", s.id.replace(/^series#/,"").slice(0,8),
        sched, s.text + (s.lastTodoId ? "  (last: "+s.lastTodoId.slice(0,8)+")" : "")].join("  "));
    }
    if(j.todo) console.log(`\nspawned: ${j.todo.text}  due ${fmt(j.todo.remindAt)}`);
  });'
}

case "$CMD" in
  url)    echo "$URL";;
  token)  token; echo;;
  list)   call '{"op":"list","includeCancelled":true}' | pretty;;
  json)   call '{"op":"list","includeCancelled":true}' | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.stringify(JSON.parse(s),null,2)))';;
  raw)    [ $# -ge 1 ] || { echo 'usage: raw '"'"'{"op":"list"}'"'"'' >&2; exit 1; }
          call "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.stringify(JSON.parse(s),null,2))}catch{console.log(s)}})';;
  add)    [ $# -ge 1 ] || { echo 'usage: add "text" ["2026-09-01 17:00"]' >&2; exit 1; }
          B=$(TEXT="$1" WHEN="${2:-}" node -e '
            const when = process.env.WHEN
              ? new Date(process.env.WHEN.replace(" ","T")).toISOString() : null;
            console.log(JSON.stringify({op:"create", text:process.env.TEXT, remindAt:when}));')
          call "$B" | pretty;;
  done)   [ $# -ge 1 ] || { echo "usage: done <id-prefix>" >&2; exit 1; }
          ID=$(resolve_id "$1") || exit 1
          call "{\"op\":\"update\",\"id\":\"$ID\",\"done\":true}" | pretty;;
  rm)     [ $# -ge 1 ] || { echo "usage: rm <id-prefix>" >&2; exit 1; }
          ID=$(resolve_id "$1" all) || exit 1
          call "{\"op\":\"delete\",\"id\":\"$ID\"}"; echo;;
  cancel) [ $# -ge 1 ] || { echo "usage: cancel <id-prefix>" >&2; exit 1; }
          ID=$(resolve_id "$1" all) || exit 1   # idempotent: re-cancelling is a no-op
          call "{\"op\":\"update\",\"id\":\"$ID\",\"cancelled\":true}" | pretty;;
  uncancel) [ $# -ge 1 ] || { echo "usage: uncancel <id-prefix>" >&2; exit 1; }
          ID=$(resolve_id "$1" all) || exit 1
          call "{\"op\":\"update\",\"id\":\"$ID\",\"cancelled\":false}" | pretty;;
  push)   call '{"op":"pushStatus"}' | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
            const j=JSON.parse(s);
            console.log("push:  " + (j.enabled ? "enabled" : "disabled (CHANNELS has no push, or no VAPID keys)"));
            if (j.enabled) console.log("devices subscribed: " + j.subs);})';;
  testpush) call '{"op":"testPush"}' | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(s))'; echo;;
  every)  [ $# -ge 2 ] || { echo 'usage: every "text" cron <dayOfMonth> <intervalMonths> [HH:MM] [firstInMonths]' >&2
                            echo '       every "text" after <days> [firstInDays] [HH:MM]' >&2; exit 1; }
          TEXT="$1"; KIND="$2"; shift 2
          case "$KIND" in
            cron)
              [ $# -ge 2 ] || { echo 'usage: every "text" cron <dayOfMonth> <intervalMonths> [HH:MM] [firstInMonths]' >&2; exit 1; }
              DOM="$1"; MONTHS="$2"; HHMM="${3:-09:00}"; FIRST="${4:-}"
              B=$(TEXT="$TEXT" DOM="$DOM" MONTHS="$MONTHS" HHMM="$HHMM" FIRST="$FIRST" node -e '
                const [h,m] = process.env.HHMM.split(":").map(Number);
                const body = {op:"seriesCreate", kind:"cron", text:process.env.TEXT,
                  dayOfMonth:+process.env.DOM, intervalMonths:+process.env.MONTHS, hour:h, minute:m};
                if (process.env.FIRST !== "") body.firstInMonths = +process.env.FIRST;
                console.log(JSON.stringify(body));')
              call "$B" | prettySeries;;
            after)
              [ $# -ge 1 ] || { echo 'usage: every "text" after <days> [firstInDays] [HH:MM]' >&2; exit 1; }
              DAYS="$1"; FIRST="${2:-}"; HHMM="${3:-}"
              B=$(TEXT="$TEXT" DAYS="$DAYS" FIRST="$FIRST" HHMM="$HHMM" node -e '
                const body = {op:"seriesCreate", kind:"after", text:process.env.TEXT, afterDays:+process.env.DAYS};
                if (process.env.FIRST !== "") body.firstInDays = +process.env.FIRST;
                if (process.env.HHMM !== "") {
                  const [h,m] = process.env.HHMM.split(":").map(Number);
                  body.hour = h; body.minute = m;
                }
                console.log(JSON.stringify(body));')
              call "$B" | prettySeries;;
            *) echo "unknown kind '$KIND' (expected cron or after)" >&2; exit 1;;
          esac;;
  series) call '{"op":"seriesList"}' | prettySeries;;
  stop)   [ $# -ge 1 ] || { echo "usage: stop <series-id-prefix>" >&2; exit 1; }
          SID=$(resolve_series_id "$1") || exit 1
          call "{\"op\":\"seriesDelete\",\"id\":\"$SID\"}"; echo;;
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

          TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
          curl -s -o /dev/null -w '%{http_code} in %{time_total}s\n' "$URL/" \
            > "$TMP/http" &
          "${AWSR[@]}" dynamodb describe-table --table-name "$APP" \
            --query 'Table.ItemCount' --output text > "$TMP/items" &
          ( "${AWSR[@]}" sesv2 get-email-identity --email-identity "$EMAIL" \
              --query VerifiedForSendingStatus --output text 2>/dev/null \
              || echo "not registered" ) > "$TMP/ses" &
          "${AWSR[@]}" events list-rules --name-prefix "$APP-sweep" \
            --query 'Rules[0].[ScheduleExpression,State]' --output text > "$TMP/schedule" &
          call '{"op":"list","includeCancelled":true}' > "$TMP/list" &
          wait

          echo -n "http:      "; cat "$TMP/http"
          echo -n "items:     "; cat "$TMP/items"
          echo -n "ses:       "; cat "$TMP/ses"
          echo -n "schedule:  "; cat "$TMP/schedule"
          echo; echo "open items:"; pretty < "$TMP/list";;
  help|*)
    cat <<EOF
usage: ./infra/api.sh [list-name] <command>     (list-name defaults to 'work')

inspect
  state              one-page summary: endpoint, item count, SES, schedule, items
  list               todos as a table
  json               todos as raw JSON
  series             recurring series as a table
  table              raw DynamoDB scan (bypasses the API entirely)
  push               whether web push is on, and how many devices subscribed
  env                the Lambda's environment variables
  logs [since]       tail CloudWatch logs, e.g. logs 1h
  url                print the endpoint
  token              print a bearer token (cached in $TOKFILE)

change
  add "text" ["2026-09-01 17:00"]
  done <id-prefix>
  cancel <id-prefix>               archive it: no reminders, hidden from the web UI
  uncancel <id-prefix>             bring it back
  rm <id-prefix>
  every "text" cron <dayOfMonth> <intervalMonths> [HH:MM] [firstInMonths]
                                    recurring series anchored to a calendar date (HH:MM local, default 09:00);
                                    firstInMonths overrides how far out the very first one is, e.g. blades
                                    due in 2 months even though the series repeats every 3
  every "text" after <days> [firstInDays] [HH:MM]
                                    recurring series anchored to completion of its own last instance;
                                    firstInDays overrides only the very first gap, e.g. a battery with
                                    2 days of charge left on a series that otherwise re-checks every 8;
                                    HH:MM fixes every occurrence's time of day instead of inheriting
                                    whatever time the item happened to get completed at
  stop <series-id-prefix>          delete a series (leaves its last spawned item alone)
  raw '{"op":"clearDone"}'          any API call, verbatim
  sweep                            force the reminder run now
  testpush                         send a test notification to every device
EOF
    ;;
esac

# Private todo list on AWS

A one-person todo list you host yourself: a web page that works on a phone or a
laptop, no app to install, no third party holding your data, and email reminders.

One Lambda serves both the UI and the JSON API, DynamoDB stores the items, and an
EventBridge schedule wakes the Lambda every 5 minutes to send whatever is due.

This repo deploys **any number of independent lists**, each in its own AWS account,
each with its own config file, URL, passphrase, and data:

    ./infra/deploy.sh work     # infra/config.work.env   -> employer's AWS account
    ./infra/deploy.sh home     # infra/config.home.env   -> personal account

Nothing is shared between them but the code.

---

## Deploying the home list from scratch

Start-to-finish on a machine that has never touched your personal AWS account.
Budget about 15 minutes, most of it waiting for AWS.

### 1. Install the tools

You need `aws`, `node` + `npm`, `zip`, `curl`, and `openssl`.

    aws --version && node -v && npm -v && zip -v | head -1 && curl -V | head -1

On Ubuntu/Debian: `sudo apt install zip curl openssl`, Node from
[nodesource](https://github.com/nodesource/distributions) or `nvm`, and the AWS CLI
from [the official installer](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).
On macOS: `brew install awscli node zip`.

### 2. Get credentials for your personal account

If you do not have a personal AWS account yet, create one at
[aws.amazon.com](https://aws.amazon.com/) — it needs a card on file even though this
project stays in the free allowances.

Then, signed in to that account, create an access key for the deploy:

1. IAM → **Users** → *Create user* → name it e.g. `deploy`.
2. Attach the **AdministratorAccess** policy directly. (This is a personal account
   and the script creates IAM roles, so it needs broad permissions. Skip the root
   user — root access keys are a bad idea and AWS discourages them.)
3. Open the new user → **Security credentials** → *Create access key* →
   **Command Line Interface (CLI)**. Copy the key id and secret.

Store them under a named profile so your work credentials stay untouched:

    aws configure --profile home
    # AWS Access Key ID:     AKIA...
    # AWS Secret Access Key: ...
    # Default region name:   us-east-1
    # Default output format: json

Check it points where you expect:

    aws --profile home sts get-caller-identity

### 3. Generate the config

    ./infra/deploy.sh home

The first run makes no AWS calls. It creates `infra/config.home.env` from the
template with a freshly generated passphrase and token secret, prints the
passphrase, and stops.

### 4. Edit the config

Open `infra/config.home.env` and set at least:

    PROFILE=home                    # the profile you just configured
    CHANNELS=push                   # push, email, or both
    EMAIL=you@personal-address.com  # recipient, and the VAPID contact address
    TIMEZONE=America/Los_Angeles    # times shown inside reminder emails

Leave `FRONTDOOR=auto` — see [Front door](#front-door) below. Leave `APP=todo-list`;
it only needs changing if you put two lists in one account.

The file holds your passphrase in plain text, is `chmod 600`, and is gitignored.

### 5. Deploy

    ./infra/deploy.sh home

It prints each resource as it goes and ends with your URL and passphrase. Expect
roughly a minute; creating a brand-new IAM role usually costs one retry while the
role propagates, which the script handles.

### 6. Turn on notifications

**With `CHANNELS=push`** there is nothing to verify — the first deploy generates a
VAPID keypair and writes it back into your config. Open the URL, log in, and tap the
🔔 in the header. On a laptop that is the whole story. On a phone, install it first
(step 8) — iOS only permits web push from a Home Screen app.

The **test** button next to the bell sends a notification immediately, which is the
fastest way to confirm a device is wired up. From a terminal:
`./infra/api.sh home push` lists how many devices are subscribed.

Skip to step 8 unless you also want email.

### 6b. Verify your email address

Only if `CHANNELS` includes `email`. The first deploy registers your address with SES and AWS emails you an
**"Amazon Web Services – Email Address Verification"** message. **Click the link in
it.** Until you do, the app works fine but reminder emails silently fail.

Confirm by re-running the deploy — it is idempotent, and the SES line should now say
`verified`:

    ./infra/deploy.sh home

### 7. Check it end to end

Open the URL, enter the passphrase, add an item with a reminder a couple of minutes
in the past, then force a reminder run rather than waiting:

    aws --profile home --region us-east-1 lambda invoke \
      --function-name todo-list --cli-binary-format raw-in-base64-out \
      --payload '{"op":"sweep"}' /dev/stdout

It prints `{"sent":1,...}` and the email arrives within a few seconds.

### 8. Put it on your phone

Open the URL in mobile Safari or Chrome and use **Add to Home Screen**. It gets its
own icon and opens without browser chrome. On iOS this is also a hard requirement
for web push — open the installed app, then tap the 🔔. The login token lives in `localStorage`
for 45 days per device, so you type the passphrase about eight times a year.

---

## Everyday use

Edit `lambda/page.html` (the whole UI) or `lambda/index.mjs` (handler, API, reminder
sweep), then:

    ./infra/deploy.sh home        # ~30 seconds, same URL

Useful commands — add `--profile home` to each for the personal list:

    aws logs tail /aws/lambda/todo-list --follow          # live logs
    ./infra/destroy.sh home                               # delete everything

## Using the page

Everything is inline — there is no detail view or modal.

| Gesture | Effect |
|---|---|
| type + **Add** | new item; the chips above set an optional reminder before you add |
| tap the checkbox | toggle done |
| tap the text | edit it in place — Enter saves, Esc cancels |
| tap the date chip | set or change the reminder; clear the field to remove it |
| tap **+ note**, or an existing note | edit notes — tap away or ⌘/Ctrl+Enter saves, Esc cancels |
| tap 🔔 in the header | turn notifications on or off for this device |
| tap **×** | delete |
| **Clear** under Completed | delete every completed item |

Notes keep their line breaks and show under the item text, greyed; reminder emails
include them. Overdue items show the date in red, items due today or tomorrow in
amber.

## Poking at it from the shell

`infra/api.sh` handles the login dance and caches the token, so inspecting state is
one command. Like the other scripts it takes a list name, defaulting to `work`:

    ./infra/api.sh state          # one-page summary of the work list
    ./infra/api.sh home state     # same for the home list
    ./infra/api.sh                # full command list

Inspection:

    ./infra/api.sh state       endpoint, HTTP check, item count, SES status, schedule, items
    ./infra/api.sh list        todos as a table
    ./infra/api.sh json        todos as raw JSON
    ./infra/api.sh table       raw DynamoDB scan, bypassing the API
    ./infra/api.sh env         the Lambda's environment variables
    ./infra/api.sh logs 1h     tail CloudWatch logs
    ./infra/api.sh url         print the endpoint
    ./infra/api.sh token       print a bearer token

Changes, for when the browser is not to hand:

    ./infra/api.sh add "Renew domain" "2026-09-01 09:00"
    ./infra/api.sh done 3a70                    # id prefix, must be unambiguous
    ./infra/api.sh rm 3a70
    ./infra/api.sh raw '{"op":"clearDone"}'     # any call, verbatim
    ./infra/api.sh sweep                        # run the reminder pass now

Sample output:

    $ ./infra/api.sh state
    list:      work (infra/config.work.env)
    account:   111122223333  region: us-east-1  app: todo-list
    endpoint:  https://EXAMPLE123.execute-api.us-east-1.amazonaws.com
    http:      200 in 0.398461s
    items:     0
    ses:       True
    schedule:  rate(5 minutes)      ENABLED

    open items:
    [ ]  3a704b50    Aug 27, 9:30 PM  Watch training video
    [x]  9c1f22ab                     Book flights
    [ ]  5e880d3f  ! Aug 26, 2:00 PM  Ping vendor about SLA (sent)

`!` marks overdue, `(sent)` means the reminder email already went out.

The `items:` line comes from DynamoDB's `ItemCount`, which AWS refreshes roughly
every six hours — it lags, and reads 0 on a young table. The list under it is live.

### The API by hand

Two endpoints: `GET /` returns the page, `POST /api` takes a JSON body whose `op`
field selects the operation. Every op except `login` needs a bearer token.

    URL=$(./infra/api.sh url)
    PASS=$(grep '^PASSWORD=' infra/config.work.env | cut -d= -f2)

    TOKEN=$(curl -s -X POST "$URL/api" -H 'content-type: application/json' \
      -d "{\"op\":\"login\",\"password\":\"$PASS\"}" \
      | node -pe 'JSON.parse(require("fs").readFileSync(0)).token')

    curl -s -X POST "$URL/api" -H 'content-type: application/json' \
      -H "authorization: Bearer $TOKEN" -d '{"op":"list"}'

| Body | Returns |
|---|---|
| `{"op":"login","password":"…"}` | `{token, todos, tz}` — the one unauthenticated op |
| `{"op":"list"}` | `{todos:[…]}` |
| `{"op":"create","text":"…","remindAt":"2026-09-01T17:00:00Z","notes":"…"}` | `{todo}` — `remindAt` and `notes` optional |
| `{"op":"update","id":"…", …}` | `{todo}` — send any of `text`, `done`, `remindAt`, `notes` |
| `{"op":"delete","id":"…"}` | `{ok:true}` |
| `{"op":"clearDone"}` | `{removed:n}` |
| `{"op":"pushStatus"}` | `{enabled, key, subs}` — `key` is the VAPID public key |
| `{"op":"subscribe","sub":{…},"device":"…"}` | `{ok:true, subs:n}` — `sub` is `PushSubscription.toJSON()` |
| `{"op":"unsubscribe","endpoint":"…"}` | `{ok:true}` |
| `{"op":"testPush"}` | `{sent:n, removed:n}` |

Failures come back as `{"error":"…"}` with 400 (bad JSON), 401 (bad passphrase or
token), 405 (wrong method) or 500. `remindAt` is any string `new Date()` parses and
is stored as UTC ISO-8601; sending `null` clears it. Setting `remindAt` resets
`notified`, so an item re-fires.

A stored item looks like:

    {
      "id":        "cb2a5519-fac0-400f-a913-e7c4a14764a0",
      "text":      "Submit expense report",
      "notes":     "receipts are in Dropbox",     // optional
      "done":      false,
      "doneAt":    "2026-08-27T21:49:02.412Z",    // only when done
      "remindAt":  "2026-09-02T00:00:00.000Z",    // optional
      "notified":  false,                          // true once emailed
      "createdAt": "2026-08-27T21:48:44.623Z"
    }

The reminder sweep is not reachable over HTTP — it is an internal event shape, so
invoke the Lambda directly:

    aws --region us-east-1 lambda invoke --function-name todo-list \
      --cli-binary-format raw-in-base64-out --payload '{"op":"sweep"}' /dev/stdout

It answers `{"sent":n,"ids":[…]}`.

### Straight at DynamoDB

The table is small enough that a scan is always fine.

    aws --region us-east-1 dynamodb scan --table-name todo-list

    # open items only
    aws --region us-east-1 dynamodb scan --table-name todo-list \
      --filter-expression "done = :d" \
      --expression-attribute-values '{":d":{"BOOL":false}}' \
      --query 'Items[].text.S' --output text

    # just id and text — `text` is a DynamoDB reserved word, hence the #t alias
    aws --region us-east-1 dynamodb scan --table-name todo-list \
      --projection-expression "id, #t" \
      --expression-attribute-names '{"#t":"text"}' \
      --query 'Items[].[id.S, text.S]' --output text

    # one item
    aws --region us-east-1 dynamodb get-item --table-name todo-list \
      --key '{"id":{"S":"3a704b50-f9ff-4217-911a-6f14ebf9f146"}}'

Add `--profile home` for the personal list. Writing directly with `put-item` works
too and the app picks it up on the next refresh, but the API validates and
normalises input, so prefer `api.sh raw` for changes.

## Layout

    lambda/index.mjs          handler: serves the page, the API, and the sweep
    lambda/page.html          the entire UI — vanilla JS, no build step
    lambda/sw.js              service worker: receives pushes, focuses the app
    lambda/manifest.webmanifest, lambda/icon.png   Home Screen install
    infra/api.sh              shell client: inspect and change a live list
    infra/config.example.env  template, committed
    infra/config.<name>.env   your real config: secrets, account pin (gitignored)
    infra/deploy.sh [name]    idempotent create-or-update
    infra/destroy.sh [name]   tear one list down

## How it fits together

| Concern | Choice | Free allowance |
|---|---|---|
| UI + API | one Lambda, `nodejs22.x`, page served from `GET /` | 1M requests/month, always free |
| Front door | Function URL, or API Gateway HTTP API | URL free; HTTP API 1M/month for 12 months, then $1/M |
| Store | DynamoDB, on-demand, partition key `id` | 25 GB, always free |
| Reminders | EventBridge rule → `{"op":"sweep"}` | scheduled rules free |
| Email | SES v2, `EMAIL_FROM` == `EMAIL_TO` | sandbox: 200/day to verified addresses |

At one person's volume — a few thousand requests a month, a handful of emails a day
— every component sits inside an always-free allowance except CloudWatch log storage
and, after twelve months, API Gateway requests. Worst case is cents per month. AWS
has revised free-tier terms more than once, so treat the table as the shape of the
design rather than a promise, and set a billing alarm if you want certainty.

### Notification channels

`CHANNELS` is a comma list of `push`, `email`, or both. The sweep tries every
enabled channel and only marks an item notified if at least one got through, so a
reminder is never silently lost — it retries on the next sweep.

**Web push** goes straight from your Lambda to the device: no third party, no
deliverability, nothing to verify. The first deploy with push enabled generates a
VAPID keypair into your config. Devices subscribe through the 🔔 in the header, and
their subscriptions live in the same DynamoDB table under a `sub#` id prefix.
Browsers answer 404 or 410 once a subscription dies, which is the only signal that a
device is gone, so the sweep prunes on it.

Requirements: HTTPS (you have it), and on **iOS 16.4+ the page must be added to the
Home Screen** — Safari refuses `Notification.requestPermission()` from a normal tab.
Android Chrome and desktop browsers need nothing special. Rotating the VAPID keys
silently unsubscribes every device.

**Email** is worth knowing about before you pick it. SES signs as `amazonses.com`,
so a message with `From: you@yahoo.com` fails DMARC alignment — and yahoo.com
publishes `p=reject`, so Yahoo refuses it. Verifying the address in SES proves you
own it for *receiving*; it cannot authorise you to send *as* Yahoo. The same applies
to any provider with a strict DMARC policy. Either use push, or send from a domain
you control and can DKIM-sign.

### Front door

`FRONTDOOR` in the config picks how the internet reaches the Lambda:

- `auto` *(default)* — creates a Function URL, probes it, and falls back to an API
  Gateway HTTP API if the probe fails. If an HTTP API already exists it keeps using
  it, so your bookmarked URL never changes underneath you.
- `url` — force the Function URL. Cheapest and simplest.
- `apigw` — force API Gateway.

**One of my two accounts requires `apigw`.** A Function URL there returns 403
`AccessDeniedException` and the request never reaches the function — no invocation
appears in CloudWatch — even with `AuthType NONE` and a correct `Principal:"*"`
resource policy, and even for an IAM-signed request from a caller that
`iam simulate-principal-policy` says is allowed `lambda:InvokeFunctionUrl`. That is
an org-level SCP or RCP; the IAM user cannot read it
(`organizations:ListPolicies` is denied). API Gateway ingress is permitted, so the
work list uses that. Both paths deliver the same event shape (payload format 2.0),
so the handler code is identical either way.

Your personal account will almost certainly take the Function URL, and `auto` will
find that without you doing anything.

### Auth

`POST /api {"op":"login","password":...}` compares SHA-256 against the
`PASSWORD_HASH` env var — the plaintext passphrase never leaves your config file —
and returns an HMAC-signed 45-day token that the browser keeps in `localStorage`.
Every other operation requires `Authorization: Bearer`. Wrong passwords cost a
600 ms delay. The endpoint hostname is random and the page is `noindex`.

That is deliberately thin: right for one person's todo list, not for shared or
regulated data. There is no login rate limit beyond that delay; if you want one, add
a throttle to the API Gateway stage or put the Function URL behind CloudFront.

To rotate the passphrase, edit `PASSWORD` in the config and redeploy. Existing
browser sessions survive; changing `TOKEN_SECRET` too logs every device out.

### Reminder semantics

An item may carry one `remindAt`. Every sweep emails the items that are due, not
done, and not yet notified — batched into a single message — then marks them
notified. Editing `remindAt` clears that flag so it fires again. Worst-case lag is
the sweep interval, so with the default `rate(5 minutes)` a 3:03 reminder arrives by
3:05. Tighten it with `SWEEP` in the config.

Polling harder is cheaper than it looks, because the sweep is one scan of a tiny
table and an empty one bills a couple of milliseconds once the container is warm.
Even `rate(1 minute)` — 43,200 invocations a month — stays inside the Lambda request
and compute allowances; the only real charge is DynamoDB read units, around
$0.003/month at that cadence, scaling with how many items you keep. Frequent polling
also keeps the function warm, which takes the ~360 ms cold start off your page loads.

Exact-to-the-second delivery would mean a one-shot EventBridge Scheduler entry per
reminder. That is also free, but it adds an IAM role and a lifecycle to get wrong —
schedules outliving their todo, or a failed delete firing a phantom notification.
Polling has neither failure mode.

### Guardrails

Each config records the account it was first deployed to as `ACCOUNT=`. Later runs
abort if the resolved credentials point somewhere else, so a stale `AWS_PROFILE` or a
forgotten `PROFILE=` line cannot drop your home list into the work account or the
other way round. `destroy.sh` enforces the same pin and makes you type the app name.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `no working AWS credentials for profile 'home'` | profile missing or typo'd — `aws configure --profile home` |
| deploy aborts on the account pin | wrong `PROFILE`, or `AWS_PROFILE` set in your shell |
| reminders never arrive | SES address not verified — re-run deploy and read the SES line |
| reminder email bounced to a *different* address | SES sandbox only delivers to verified addresses; verify it or request production access |
| 403 on the URL, nothing in CloudWatch | org policy blocking Function URLs — set `FRONTDOOR=apigw` |
| 500 on every request through API Gateway | Lambda invoke permission source ARN must be `<api-id>/*` |
| page loads, everything 401s | `TOKEN_SECRET` changed — log in again |
| no 🔔 in the header | `CHANNELS` has no `push`, or the browser lacks Push API support |
| 🔔 does nothing on iPhone | not installed to the Home Screen — Safari blocks push in a normal tab |
| notifications stop after working | subscription expired; tap 🔔 off and on again |
| sweep returns `retrying:true` | nothing was delivered on any channel; item stays pending |

## Privacy note

The work list lives in an employer-managed AWS account, where account
administrators can read the DynamoDB table and the CloudWatch logs. Keep personal
items in the home deployment; that is the point of running two.

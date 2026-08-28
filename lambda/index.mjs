import crypto from "node:crypto";
import { readFileSync } from "node:fs";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient, ScanCommand, PutCommand, UpdateCommand, DeleteCommand,
} from "@aws-sdk/lib-dynamodb";
import { SESv2Client, SendEmailCommand } from "@aws-sdk/client-sesv2";
import webpush from "web-push";

const TABLE = process.env.TABLE;
const PASSWORD_HASH = process.env.PASSWORD_HASH;
const TOKEN_SECRET = process.env.TOKEN_SECRET;
const EMAIL_FROM = process.env.EMAIL_FROM;
const EMAIL_TO = process.env.EMAIL_TO;
const TIMEZONE = process.env.TIMEZONE || "UTC";
const TOKEN_DAYS = 45;

// Delivery channels. Defaults to email so an existing deploy keeps its behaviour.
const CHANNELS = (process.env.CHANNELS || "email").split(",").map((c) => c.trim()).filter(Boolean);
const VAPID_PUBLIC = process.env.VAPID_PUBLIC || "";
const VAPID_PRIVATE = process.env.VAPID_PRIVATE || "";
const PUSH_ON = CHANNELS.includes("push") && !!VAPID_PUBLIC && !!VAPID_PRIVATE;
const EMAIL_ON = CHANNELS.includes("email") && !!EMAIL_FROM;
if (PUSH_ON) {
  webpush.setVapidDetails(process.env.VAPID_SUBJECT || `mailto:${EMAIL_TO}`, VAPID_PUBLIC, VAPID_PRIVATE);
}

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
  marshallOptions: { removeUndefinedValues: true },
});
const ses = new SESv2Client({});
const PAGE = readFileSync(new URL("./page.html", import.meta.url), "utf8");
const SW = readFileSync(new URL("./sw.js", import.meta.url), "utf8");
const MANIFEST = readFileSync(new URL("./manifest.webmanifest", import.meta.url), "utf8");
const ICON = readFileSync(new URL("./icon.png", import.meta.url)).toString("base64");

/* ---------- auth ---------- */

const sha256 = (s) => crypto.createHash("sha256").update(s).digest("hex");
const b64 = (s) => Buffer.from(s).toString("base64url");

function sign(payload) {
  const body = b64(JSON.stringify(payload));
  const mac = crypto.createHmac("sha256", TOKEN_SECRET).update(body).digest("base64url");
  return `${body}.${mac}`;
}

function verify(token) {
  if (typeof token !== "string" || !token.includes(".")) return null;
  const [body, mac] = token.split(".");
  const want = crypto.createHmac("sha256", TOKEN_SECRET).update(body).digest("base64url");
  const a = Buffer.from(mac || ""), b = Buffer.from(want);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  try {
    const payload = JSON.parse(Buffer.from(body, "base64url").toString());
    return payload.exp > Date.now() ? payload : null;
  } catch { return null; }
}

/* ---------- data ---------- */

// Push subscriptions live in the same table under a "sub#" id prefix, so every
// read has to pick a side. The table is tiny; a scan is the right tool.
const SUB = "sub#";

async function scanAll() {
  const items = [];
  let key;
  do {
    const r = await ddb.send(new ScanCommand({ TableName: TABLE, ExclusiveStartKey: key }));
    items.push(...(r.Items || []));
    key = r.LastEvaluatedKey;
  } while (key);
  return items;
}

const allTodos = async () => (await scanAll()).filter((i) => !i.id.startsWith(SUB));
const allSubs = async () => (await scanAll()).filter((i) => i.id.startsWith(SUB));
const subId = (endpoint) =>
  SUB + crypto.createHash("sha256").update(endpoint).digest("hex").slice(0, 32);

const clean = (s, max) => String(s ?? "").replace(/\s+/g, " ").trim().slice(0, max);

// Notes are the one free-text field where line breaks carry meaning, so collapse
// horizontal whitespace only and cap consecutive blank lines.
const cleanNote = (s) => String(s ?? "").replace(/\r\n?/g, "\n")
  .replace(/[^\S\n]+/g, " ").replace(/\n{3,}/g, "\n\n").trim().slice(0, 2000);

function normRemind(v) {
  if (!v) return null;
  const t = new Date(v);
  return Number.isNaN(t.getTime()) ? null : t.toISOString();
}

/* ---------- api ---------- */

async function api(op, body) {
  switch (op) {
    case "list":
      return { todos: await allTodos() };

    case "create": {
      const text = clean(body.text, 500);
      if (!text) return { error: "empty" };
      const item = {
        id: crypto.randomUUID(),
        text,
        notes: cleanNote(body.notes) || undefined,
        done: false,
        remindAt: normRemind(body.remindAt) || undefined,
        notified: false,
        createdAt: new Date().toISOString(),
      };
      await ddb.send(new PutCommand({ TableName: TABLE, Item: item }));
      return { todo: item };
    }

    case "update": {
      if (!body.id) return { error: "no id" };
      const sets = {}, removes = [];
      if ("text" in body) {
        const t = clean(body.text, 500);
        if (!t) return { error: "empty" };
        sets.text = t;
      }
      if ("notes" in body) {
        const n = cleanNote(body.notes);
        n ? (sets.notes = n) : removes.push("notes");
      }
      if ("done" in body) {
        sets.done = !!body.done;
        sets.doneAt = body.done ? new Date().toISOString() : undefined;
        if (!body.done) { delete sets.doneAt; removes.push("doneAt"); }
      }
      if ("remindAt" in body) {
        const r = normRemind(body.remindAt);
        r ? (sets.remindAt = r) : removes.push("remindAt");
        sets.notified = false;
      }

      const names = {}, values = {}, setParts = [], remParts = [];
      for (const [k, v] of Object.entries(sets)) {
        names[`#${k}`] = k; values[`:${k}`] = v; setParts.push(`#${k} = :${k}`);
      }
      for (const k of removes) { names[`#${k}`] = k; remParts.push(`#${k}`); }
      let expr = "";
      if (setParts.length) expr += `SET ${setParts.join(", ")}`;
      if (remParts.length) expr += `${expr ? " " : ""}REMOVE ${remParts.join(", ")}`;
      if (!expr) return { error: "nothing to update" };

      const r = await ddb.send(new UpdateCommand({
        TableName: TABLE,
        Key: { id: body.id },
        UpdateExpression: expr,
        ExpressionAttributeNames: names,
        ...(Object.keys(values).length ? { ExpressionAttributeValues: values } : {}),
        ConditionExpression: "attribute_exists(id)",
        ReturnValues: "ALL_NEW",
      }));
      return { todo: r.Attributes };
    }

    case "delete":
      if (!body.id) return { error: "no id" };
      await ddb.send(new DeleteCommand({ TableName: TABLE, Key: { id: body.id } }));
      return { ok: true };

    case "pushStatus":
      return { enabled: PUSH_ON, key: VAPID_PUBLIC, subs: PUSH_ON ? (await allSubs()).length : 0 };

    case "subscribe": {
      const sub = body.sub;
      if (!sub?.endpoint || !sub?.keys?.p256dh || !sub?.keys?.auth) return { error: "bad subscription" };
      await ddb.send(new PutCommand({ TableName: TABLE, Item: {
        id: subId(sub.endpoint),
        endpoint: sub.endpoint,
        keys: { p256dh: sub.keys.p256dh, auth: sub.keys.auth },
        device: clean(body.device, 200) || undefined,
        createdAt: new Date().toISOString(),
      } }));
      return { ok: true, subs: (await allSubs()).length };
    }

    case "unsubscribe": {
      if (!body.endpoint) return { error: "no endpoint" };
      await ddb.send(new DeleteCommand({ TableName: TABLE, Key: { id: subId(body.endpoint) } }));
      return { ok: true };
    }

    case "testPush":
      return sendPush({
        title: "Todo",
        body: "Push notifications are working.",
        tag: "todo-test",
      });

    case "clearDone": {
      const done = (await allTodos()).filter((t) => t.done);
      for (const t of done) {
        await ddb.send(new DeleteCommand({ TableName: TABLE, Key: { id: t.id } }));
      }
      return { removed: done.length };
    }

    default:
      return { error: "unknown op" };
  }
}

/* ---------- reminder sweep ---------- */

const fmt = (iso) => {
  try {
    return new Intl.DateTimeFormat("en-US", {
      timeZone: TIMEZONE, weekday: "short", month: "short", day: "numeric",
      hour: "numeric", minute: "2-digit",
    }).format(new Date(iso));
  } catch { return iso; }
};

const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

async function sendEmail(due) {
  const subject = due.length === 1
    ? `Todo due: ${due[0].text.slice(0, 80)}`
    : `${due.length} todos due`;
  const indent = (n) => n.split("\n").map((l) => `    ${l}`).join("\n");
  const lines = due.map((t) => `• ${t.text}  (${fmt(t.remindAt)})${t.notes ? `\n${indent(t.notes)}` : ""}`);
  const html = `<div style="font:16px/1.5 -apple-system,Segoe UI,sans-serif">
<p style="margin:0 0 12px">These todos are due:</p>
<ul style="padding-left:20px;margin:0">${due.map((t) =>
    `<li style="margin-bottom:8px"><b>${esc(t.text)}</b><br>
<span style="color:#666;font-size:14px">${esc(fmt(t.remindAt))}</span>${
      t.notes ? `<br><span style="font-size:14px">${esc(t.notes).replace(/\n/g, "<br>")}</span>` : ""}</li>`).join("")}</ul></div>`;

  await ses.send(new SendEmailCommand({
    FromEmailAddress: EMAIL_FROM,
    Destination: { ToAddresses: [EMAIL_TO] },
    Content: { Simple: {
      Subject: { Data: subject },
      Body: { Text: { Data: `These todos are due:\n\n${lines.join("\n")}\n` }, Html: { Data: html } },
    } },
  }));
  return { sent: due.length };
}

// Browsers hand back 404/410 once a subscription is dead — that is the only
// signal we get that a device is gone, so prune on it.
async function sendPush(payload) {
  if (!PUSH_ON) return { sent: 0, reason: "push disabled" };
  const subs = await allSubs();
  if (!subs.length) return { sent: 0, reason: "no subscriptions" };

  const results = await Promise.allSettled(subs.map((s) =>
    webpush.sendNotification(
      { endpoint: s.endpoint, keys: s.keys }, JSON.stringify(payload), { TTL: 12 * 3600 })));

  const stale = [];
  let sent = 0;
  results.forEach((r, i) => {
    if (r.status === "fulfilled") { sent++; return; }
    const code = r.reason?.statusCode;
    if (code === 404 || code === 410) stale.push(subs[i].id);
    else console.error("push failed", code, r.reason?.body || r.reason?.message);
  });
  for (const id of stale) {
    await ddb.send(new DeleteCommand({ TableName: TABLE, Key: { id } }));
  }
  return { sent, removed: stale.length };
}

async function sweep() {
  const now = Date.now();
  const due = (await allTodos()).filter(
    (t) => !t.done && !t.notified && t.remindAt && new Date(t.remindAt).getTime() <= now,
  );
  if (!due.length) return { due: 0 };
  due.sort((a, b) => a.remindAt.localeCompare(b.remindAt));

  const out = { due: due.length };
  let delivered = false;

  if (EMAIL_ON) {
    try { out.email = await sendEmail(due); delivered = true; }
    catch (err) { console.error("email failed", err); out.email = { error: String(err.message || err) }; }
  }
  if (PUSH_ON) {
    try {
      out.push = await sendPush({
        title: due.length === 1 ? due[0].text.slice(0, 80) : `${due.length} todos due`,
        body: due.length === 1
          ? [fmt(due[0].remindAt), due[0].notes].filter(Boolean).join(" — ")
          : due.map((t) => `• ${t.text}`).join("\n"),
        tag: "todo-due",
      });
      if (out.push.sent > 0) delivered = true;
    } catch (err) { console.error("push failed", err); out.push = { error: String(err.message || err) }; }
  }

  // Leave `notified` alone if nothing got through, so the next sweep retries.
  if (!delivered) { out.retrying = true; return out; }

  for (const t of due) {
    await ddb.send(new UpdateCommand({
      TableName: TABLE, Key: { id: t.id },
      UpdateExpression: "SET notified = :true",
      ExpressionAttributeValues: { ":true": true },
    }));
  }
  out.ids = due.map((t) => t.id);
  return out;
}

/* ---------- handler ---------- */

const json = (code, obj) => ({
  statusCode: code,
  headers: { "content-type": "application/json", "cache-control": "no-store" },
  body: JSON.stringify(obj),
});

export const handler = async (event) => {
  if (event?.op === "sweep") return sweep();

  const method = event.requestContext?.http?.method || "GET";
  const path = event.rawPath || "/";

  if (method === "GET" && path === "/sw.js") {
    return {
      statusCode: 200,
      // The scope header lets a worker served from / control the whole origin.
      headers: { "content-type": "text/javascript", "cache-control": "no-store",
                 "service-worker-allowed": "/" },
      body: SW,
    };
  }

  if (method === "GET" && path === "/manifest.webmanifest") {
    return {
      statusCode: 200,
      headers: { "content-type": "application/manifest+json", "cache-control": "max-age=3600" },
      body: MANIFEST,
    };
  }

  if (method === "GET" && path === "/icon.png") {
    return {
      statusCode: 200,
      headers: { "content-type": "image/png", "cache-control": "max-age=86400" },
      body: ICON,
      isBase64Encoded: true,
    };
  }

  if (method === "GET" && path !== "/api") {
    return {
      statusCode: 200,
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
        "referrer-policy": "no-referrer",
        "x-robots-tag": "noindex, nofollow",
      },
      body: PAGE,
    };
  }

  if (method !== "POST") return json(405, { error: "method not allowed" });

  let body = {};
  try {
    const raw = event.isBase64Encoded
      ? Buffer.from(event.body || "", "base64").toString()
      : event.body || "{}";
    body = JSON.parse(raw);
  } catch { return json(400, { error: "bad json" }); }

  if (body.op === "login") {
    const ok = typeof body.password === "string" &&
      crypto.timingSafeEqual(Buffer.from(sha256(body.password)), Buffer.from(PASSWORD_HASH));
    if (!ok) {
      await new Promise((r) => setTimeout(r, 600));
      return json(401, { error: "wrong password" });
    }
    return json(200, {
      token: sign({ exp: Date.now() + TOKEN_DAYS * 864e5 }),
      todos: await allTodos(),
      tz: TIMEZONE,
      push: { enabled: PUSH_ON, key: VAPID_PUBLIC },
    });
  }

  const auth = (event.headers?.authorization || "").replace(/^Bearer /i, "");
  if (!verify(auth)) return json(401, { error: "unauthorized" });

  try {
    return json(200, await api(body.op, body));
  } catch (err) {
    console.error("api error", body.op, err);
    return json(500, { error: "server error" });
  }
};

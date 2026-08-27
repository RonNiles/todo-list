import crypto from "node:crypto";
import { readFileSync } from "node:fs";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient, ScanCommand, PutCommand, UpdateCommand, DeleteCommand,
} from "@aws-sdk/lib-dynamodb";
import { SESv2Client, SendEmailCommand } from "@aws-sdk/client-sesv2";

const TABLE = process.env.TABLE;
const PASSWORD_HASH = process.env.PASSWORD_HASH;
const TOKEN_SECRET = process.env.TOKEN_SECRET;
const EMAIL_FROM = process.env.EMAIL_FROM;
const EMAIL_TO = process.env.EMAIL_TO;
const TIMEZONE = process.env.TIMEZONE || "UTC";
const TOKEN_DAYS = 45;

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
  marshallOptions: { removeUndefinedValues: true },
});
const ses = new SESv2Client({});
const PAGE = readFileSync(new URL("./page.html", import.meta.url), "utf8");

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

async function allTodos() {
  const items = [];
  let key;
  do {
    const r = await ddb.send(new ScanCommand({ TableName: TABLE, ExclusiveStartKey: key }));
    items.push(...(r.Items || []));
    key = r.LastEvaluatedKey;
  } while (key);
  return items;
}

const clean = (s, max) => String(s ?? "").replace(/\s+/g, " ").trim().slice(0, max);

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
        notes: clean(body.notes, 2000) || undefined,
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
        const n = clean(body.notes, 2000);
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

async function sweep() {
  const now = Date.now();
  const due = (await allTodos()).filter(
    (t) => !t.done && !t.notified && t.remindAt && new Date(t.remindAt).getTime() <= now,
  );
  if (!due.length) return { sent: 0 };

  due.sort((a, b) => a.remindAt.localeCompare(b.remindAt));
  const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
  const subject = due.length === 1
    ? `Todo due: ${due[0].text.slice(0, 80)}`
    : `${due.length} todos due`;
  const lines = due.map((t) => `• ${t.text}  (${fmt(t.remindAt)})${t.notes ? `\n    ${t.notes}` : ""}`);
  const html = `<div style="font:16px/1.5 -apple-system,Segoe UI,sans-serif">
<p style="margin:0 0 12px">These todos are due:</p>
<ul style="padding-left:20px;margin:0">${due.map((t) =>
    `<li style="margin-bottom:8px"><b>${esc(t.text)}</b><br>
<span style="color:#666;font-size:14px">${esc(fmt(t.remindAt))}</span>${
      t.notes ? `<br><span style="font-size:14px">${esc(t.notes)}</span>` : ""}</li>`).join("")}</ul></div>`;

  await ses.send(new SendEmailCommand({
    FromEmailAddress: EMAIL_FROM,
    Destination: { ToAddresses: [EMAIL_TO] },
    Content: { Simple: {
      Subject: { Data: subject },
      Body: { Text: { Data: `These todos are due:\n\n${lines.join("\n")}\n` }, Html: { Data: html } },
    } },
  }));

  for (const t of due) {
    await ddb.send(new UpdateCommand({
      TableName: TABLE, Key: { id: t.id },
      UpdateExpression: "SET notified = :true",
      ExpressionAttributeValues: { ":true": true },
    }));
  }
  return { sent: due.length, ids: due.map((t) => t.id) };
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

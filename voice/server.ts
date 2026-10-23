// MDMA voice connector: a small remote MCP server so Claude's voice chat (claude.ai custom
// connector) can save each call as a note on this Mac, search those notes and read files.
// Shareable version of Matt's "My Mac" connector; setup steps are in SETUP.md.
//
//   bun server.ts          serve on 127.0.0.1:PORT at /mcp/<token>
//   bun server.ts --init   create the token if missing and copy the connector URL to the
//                          clipboard (never printed)
//
// Published by Tailscale Funnel (install.sh). The long secret path is the auth; files are
// read-only, limited to the home folder, and secret files are refused.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { z } from "zod";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { readFileSync, appendFileSync, existsSync, mkdirSync, writeFileSync, readdirSync, statSync, realpathSync } from "node:fs";
import { randomBytes } from "node:crypto";

const HOME = homedir();
export const CONFIG_DIR = join(HOME, ".config", "mdma-voice");
const TOKEN_FILE = join(CONFIG_DIR, "token");
const LOG = join(CONFIG_DIR, "connector.log");
const PORT = Number(process.env.PORT ?? 8777);
const NOTIFY = join(HOME, ".hammerspoon", "bin", "claude-notify");
const PATH_ENV = `${HOME}/.bun/bin:${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`;

// config.json: { "name": "Tyler", "notes": "~/Documents/Voice calls" }. Both optional.
export function loadConfig(dir = CONFIG_DIR): { name: string; notes: string } {
  let c: any = {};
  try { c = JSON.parse(readFileSync(join(dir, "config.json"), "utf8")); } catch {}
  const notes = String(c.notes || "~/Documents/Voice calls").replace(/^~(?=$|\/)/, HOME);
  return { name: String(c.name || "the user"), notes };
}

function log(msg: string) {
  try { mkdirSync(CONFIG_DIR, { recursive: true }); appendFileSync(LOG, `${new Date().toISOString()} ${msg}\n`); } catch {}
}

const readToken = () => (existsSync(TOKEN_FILE) ? readFileSync(TOKEN_FILE, "utf8").trim() : "");

// Secret files never leave the Mac, whatever the request.
const SECRET = [/(^|\/)\.env(\.|$)/, /credential/i, /secret/i, /(^|\/)\.ssh\//, /\/Keychains\//, /\/\.config\/mdma-voice\//,
  /\.(pem|key|p12|pfx|keychain-db)$/i, /(^|\/)id_(rsa|ed25519|ecdsa)/, /token/i, /password/i];

export function safePath(p: string, home = HOME): string {
  const abs = resolve(p.replace(/^~(?=$|\/)/, home));
  const real = existsSync(abs) ? realpathSync(abs) : abs;
  if (!real.startsWith(home + "/") && real !== home) throw new Error("Only files inside the home folder can be read.");
  if (SECRET.some((r) => r.test(real))) throw new Error("That file holds secrets, so it can't be read through the connector.");
  return real;
}

const has = (bin: string) => Bun.spawnSync(["/bin/sh", "-c", `command -v ${bin}`], { env: { PATH: PATH_ENV } }).exitCode === 0;

async function run(cmd: string[], timeoutMs = 20000): Promise<string> {
  const p = Bun.spawn(cmd, { stdout: "pipe", stderr: "pipe", env: { ...process.env, PATH: PATH_ENV }, cwd: HOME });
  const timer = setTimeout(() => p.kill(), timeoutMs);
  const out = await new Response(p.stdout).text();
  await p.exited;
  clearTimeout(timer);
  return out;
}

// Write one call note; returns its file name. Exported for tests.
export function writeCallNote(dir: string, call: { title: string; summary: string; said: string; facts?: string[]; todos?: string[] },
  now = new Date(), who = "the user"): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  const day = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
  const hm = `${pad(now.getHours())}${pad(now.getMinutes())}`;
  const title = call.title.replace(/[\/:*?"<>|#^\[\]]/g, "").trim().slice(0, 60) || "Voice call";
  const list = (xs?: string[]) => (xs?.length ? xs.map((x) => `- ${x}`).join("\n") : "- (none)");
  mkdirSync(dir, { recursive: true });
  const name = `${day} ${hm} ${title}.md`;
  const label = who === "the user" ? "What I said" : `What ${who} said`;
  writeFileSync(join(dir, name), [
    "---", `title: ${JSON.stringify(title)}`, `created: ${day}`, "source: voice-chat", "---", "",
    `# ${title}`, "", "## Summary", call.summary, "", "## New facts", list(call.facts), "", "## To-dos", list(call.todos), "",
    `## ${label}`, call.said, "",
  ].join("\n"));
  return name;
}

function buildServer(): McpServer {
  const cfg = loadConfig();
  const who = cfg.name;
  const text = (t: string) => ({ content: [{ type: "text" as const, text: t }] });
  const fail = (e: unknown) => ({ content: [{ type: "text" as const, text: String((e as Error).message ?? e) }], isError: true });
  const server = new McpServer({ name: "my-mac", version: "0.1.0" }, {
    instructions: `${who === "the user" ? "The user's" : `${who}'s`} Mac. At the end of every voice call, call save_call. ` +
      "Use search_notes for past calls and notes; find_files / list_folder / read_file for files on the Mac.",
  });

  server.registerTool("save_call", {
    description: "Run this at the END of every voice call. Saves the call as a searchable note on this Mac " +
      `(${cfg.notes.replace(HOME, "~")}).`,
    inputSchema: {
      title: z.string().describe("What the call was about, under 8 words"),
      summary: z.string().describe("A few sentences: what was discussed and decided"),
      said: z.string().describe(`Everything ${who} said, as close to word for word as you can, in order`),
      facts: z.array(z.string()).optional().describe(`New facts about ${who} worth remembering`),
      todos: z.array(z.string()).optional().describe("Reminders, events or tasks to act on, with dates/times"),
    },
  }, async (call) => {
    try {
      const name = writeCallNote(cfg.notes, call, new Date(), who);
      if (has("qmd")) Bun.spawn(["qmd", "update"], { stdout: "ignore", stderr: "ignore", env: { ...process.env, PATH: PATH_ENV } }).unref();
      if (existsSync(NOTIFY)) Bun.spawn([NOTIFY, "Voice call saved", name.replace(/\.md$/, ""), "--kind", "done", "--quiet"], { stdout: "ignore", stderr: "ignore" }).unref();
      log(`call saved: ${name}`);
      return text(`Saved as "${name}".`);
    } catch (e) { return fail(e); }
  });

  server.registerTool("search_notes", {
    description: "Search the saved voice calls (and, if QMD is installed, every note it indexes). Returns matching files; open one with read_file.",
    inputSchema: { query: z.string().describe("A few distinctive keywords"), limit: z.number().int().min(1).max(20).optional() },
  }, async ({ query, limit }) => {
    try {
      const n = limit ?? 8;
      if (has("qmd")) {
        const hits = JSON.parse((await run(["qmd", "search", query, "--format", "json", "-n", String(n)])) || "[]") as any[];
        if (hits.length) return text(hits.map((h) => `${h.file} — ${h.title}\n${String(h.snippet ?? "").slice(0, 600)}`).join("\n\n"));
      }
      const files = (await run(["mdfind", "-onlyin", cfg.notes, query])).split("\n").filter(Boolean).slice(0, n);
      return text(files.join("\n") || "No matches. Try other keywords.");
    } catch (e) { return fail(e); }
  });

  server.registerTool("find_files", {
    description: "Find files on this Mac by name (Spotlight), inside the home folder.",
    inputSchema: { name: z.string().describe("Part of the file name"), limit: z.number().int().min(1).max(50).optional() },
  }, async ({ name, limit }) => {
    try {
      const out = await run(["mdfind", "-onlyin", HOME, "-name", name]);
      const files = out.split("\n").filter((f) => f && !SECRET.some((r) => r.test(f)) && !f.includes("/node_modules/") && !f.includes("/Library/"));
      return text(files.slice(0, limit ?? 20).join("\n") || "No files found.");
    } catch (e) { return fail(e); }
  });

  server.registerTool("list_folder", {
    description: "List a folder on this Mac (e.g. ~/Desktop, ~/Documents).",
    inputSchema: { path: z.string() },
  }, async ({ path }) => {
    try {
      const dir = safePath(path);
      const rows = readdirSync(dir).filter((n) => !n.startsWith(".")).slice(0, 300).map((n) => {
        try { return statSync(join(dir, n)).isDirectory() ? `${n}/` : n; } catch { return n; }
      });
      return text(rows.join("\n") || "(empty)");
    } catch (e) { return fail(e); }
  });

  server.registerTool("read_file", {
    description: "Read a text file on this Mac (notes, code, documents). Secret files are refused.",
    inputSchema: { path: z.string(), max_chars: z.number().int().min(100).max(100000).optional() },
  }, async ({ path, max_chars }) => {
    try {
      const body = readFileSync(safePath(path), "utf8");
      const cap = max_chars ?? 30000;
      return text(body.length > cap ? body.slice(0, cap) + `\n\n[truncated: ${body.length} chars total]` : body);
    } catch (e) { return fail(e); }
  });

  return server;
}

// The Funnel host for this Mac, e.g. my-mac.tail1234.ts.net.
function publicHost(): string {
  for (const bin of ["tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]) {
    const p = Bun.spawnSync([bin, "status", "--json"], { stdout: "pipe", stderr: "ignore", env: { PATH: PATH_ENV } });
    if (p.exitCode === 0) return JSON.parse(p.stdout.toString()).Self.DNSName.replace(/\.$/, "");
  }
  throw new Error("Tailscale isn't running; see SETUP.md");
}

function init() {
  mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
  let token = readToken();
  if (!token) { token = randomBytes(24).toString("base64url"); writeFileSync(TOKEN_FILE, token + "\n", { mode: 0o600 }); }
  const p = Bun.spawnSync(["pbcopy"], { stdin: Buffer.from(`https://${publicHost()}/mcp/${token}`) });
  console.log(p.exitCode === 0 ? "Connector URL copied to the clipboard." : "pbcopy failed");
}

if (!import.meta.main) {
  // imported (tests): don't serve
} else if (process.argv.includes("--init")) {
  init();
} else {
  const token = readToken();
  if (!token) { console.error("No token yet; run `bun server.ts --init`"); process.exit(1); }
  const secretPath = `/mcp/${token}`;
  Bun.serve({
    port: PORT,
    hostname: "127.0.0.1",
    idleTimeout: 120,
    async fetch(req) {
      const url = new URL(req.url);
      log(`${req.method} ${url.pathname.replace(token, "<token>")}`);
      if (url.pathname === "/health") return new Response("ok");
      if (url.pathname !== secretPath) return new Response("Not found", { status: 404 });
      // Stateless: a fresh server + transport per POST; no SSE stream, so GET/DELETE get 405.
      if (req.method !== "POST") return new Response("Method not allowed", { status: 405, headers: { allow: "POST" } });
      const transport = new WebStandardStreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
      await buildServer().connect(transport);
      return transport.handleRequest(req);
    },
  });
  log(`listening on 127.0.0.1:${PORT}`);
  console.log(`voice connector listening on 127.0.0.1:${PORT}`);
}

import { test, expect } from "bun:test";
import { mkdtempSync, readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { writeCallNote, loadConfig, safePath } from "./server.ts";

const tmp = () => { const d = join(import.meta.dir, "..", "tmp"); mkdirSync(d, { recursive: true }); return mkdtempSync(join(d, "voice-")); };

test("save_call writes a dated note with every section", () => {
  const dir = tmp();
  const name = writeCallNote(dir, { title: "Trip: plans/ideas?", summary: "S", said: "hi", todos: ["Book it"] }, new Date(2026, 9, 22, 9, 5), "Tyler");
  expect(name).toBe("2026-10-22 0905 Trip plansideas.md");
  const body = readFileSync(join(dir, name), "utf8");
  for (const s of ["# Trip plansideas", "## Summary\nS", "## New facts\n- (none)", "## To-dos\n- Book it", "## What Tyler said\nhi"]) expect(body).toContain(s);
});

test("config defaults, then reads name and notes", () => {
  const d = tmp();
  expect(loadConfig(d).name).toBe("the user");
  expect(loadConfig(d).notes.endsWith("/Documents/Voice calls")).toBe(true);
  writeFileSync(join(d, "config.json"), JSON.stringify({ name: "Tyler", notes: "~/Notes/Calls" }));
  expect(loadConfig(d).name).toBe("Tyler");
  expect(loadConfig(d).notes.endsWith("/Notes/Calls")).toBe(true);
});

test("safePath refuses outside home and secret files", () => {
  const home = tmp();
  expect(() => safePath("/etc/hosts", home)).toThrow();
  expect(() => safePath("~/.env", home)).toThrow();
  expect(() => safePath("~/.ssh/id_ed25519", home)).toThrow();
  expect(() => safePath("~/.config/mdma-voice/token", home)).toThrow();
  expect(safePath("~/notes.md", home)).toBe(join(home, "notes.md"));
});

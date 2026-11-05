#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { basename } from "node:path";

const TEXT_MIN = 4.5;

function parseColor(raw) {
  const v = raw.trim().toLowerCase();
  let m = v.match(/^#([0-9a-f]{3,8})$/);
  if (m) {
    let h = m[1];
    if (h.length === 3 || h.length === 4) h = [...h].map((c) => c + c).join("");
    return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
  }
  m = v.match(/^rgba?\(\s*(\d+)[\s,]+(\d+)[\s,]+(\d+)/);
  if (m) return m.slice(1, 4).map(Number);
  return null;
}

function luminance([r, g, b]) {
  const lin = (c) => {
    const s = c / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
}

export function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

function rootBlocks(css) {
  const blocks = [];
  // Matches a selector list containing :root and its flat declaration body.
  const re = /([^{}]*:root[^{}]*)\{([^{}]*)\}/g;
  for (const [, selector, body] of css.matchAll(re)) {
    const vars = {};
    for (const [, name, value] of body.matchAll(/(--[\w-]+)\s*:\s*([^;]+)/g)) vars[name] = value.trim();
    blocks.push({ selector: selector.trim().replace(/\s+/g, " "), vars });
  }
  return blocks;
}

function resolve(vars, name, depth = 0) {
  const value = vars[name];
  if (!value || depth > 5) return value;
  const ref = value.match(/^var\((--[\w-]+)\)$/);
  return ref ? resolve(vars, ref[1], depth + 1) : value;
}

function checkContrast(html, fails) {
  const meta = html.match(/<meta\s+name="contrast-pairs"\s+content="([^"]*)"/i);
  if (!meta) return fails.push('no <meta name="contrast-pairs"> declared');
  const css = [...html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/gi)].map((m) => m[1]).join("\n");
  const blocks = rootBlocks(css);
  const base = blocks.find((b) => b.selector === ":root")?.vars ?? {};
  for (const pair of meta[1].trim().split(/\s+/)) {
    const [fgName, rest] = pair.split("/");
    const [bgName, min] = (rest ?? "").split(":");
    for (const block of blocks) {
      const vars = { ...base, ...block.vars };
      const fg = parseColor(resolve(vars, fgName) ?? "");
      const bg = parseColor(resolve(vars, bgName) ?? "");
      if (!fg || !bg) {
        fails.push(`${pair} in "${block.selector}": token missing or not hex/rgb`);
        continue;
      }
      const ratio = contrast(fg, bg);
      const need = Number(min) || TEXT_MIN;
      if (ratio < need) fails.push(`${pair} in "${block.selector}": ${ratio.toFixed(2)}:1, needs ${need}:1`);
    }
  }
}

const strip = (s) => s.replace(/<[^>]*>/g, "").replace(/&nbsp;/g, " ").trim();
const named = (attrs) => /\baria-label(ledby)?\s*=\s*"[^"]+"/i.test(attrs);

function checkMarkup(html, fails, warns) {
  if (!/<html[^>]*\blang="[^"]+"/i.test(html)) fails.push("<html> has no lang");
  if (!/<title>[^<]+<\/title>/i.test(html)) fails.push("no <title>");
  if (!/<meta[^>]+name="viewport"/i.test(html)) fails.push("no viewport meta");
  for (const [tag] of html.matchAll(/<img\b[^>]*>/gi)) {
    if (!/\balt\s*=/i.test(tag)) fails.push(`img without alt: ${tag.slice(0, 60)}`);
  }
  for (const [, el, attrs, inner] of html.matchAll(/<(button|a)\b([^>]*)>([\s\S]*?)<\/\1>/gi)) {
    if (!strip(inner) && !named(attrs)) fails.push(`empty ${el} with no aria-label: <${el}${attrs.slice(0, 50)}>`);
  }
  const labelled = new Set([...html.matchAll(/<label\b[^>]*\bfor="([^"]+)"/gi)].map((m) => m[1]));
  for (const [tag, el, attrs] of html.matchAll(/<(input|select|textarea)\b([^>]*)>/gi)) {
    if (/type="(hidden|submit|button|reset)"/i.test(attrs)) continue;
    const id = attrs.match(/\bid="([^"]+)"/)?.[1];
    if (!named(attrs) && !(id && labelled.has(id))) fails.push(`${el} without label: ${tag.slice(0, 60)}`);
  }
  if (/(animation|transition)\s*:/i.test(html) && !/prefers-reduced-motion/i.test(html)) {
    warns.push("animates but never checks prefers-reduced-motion");
  }
}

export function checkFile(path) {
  const html = readFileSync(path, "utf8");
  const fails = [];
  const warns = [];
  checkMarkup(html, fails, warns);
  checkContrast(html, fails);
  return { file: basename(path), fails, warns };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const results = process.argv.slice(2).map(checkFile);
  console.log(JSON.stringify(results, null, 2));
  process.exit(results.some((r) => r.fails.length) ? 1 : 0);
}

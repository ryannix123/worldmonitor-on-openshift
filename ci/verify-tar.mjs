#!/usr/bin/env node
// Fail if any resolved copy of node-tar is older than the CVE-2026-59873 fix
// (7.5.19). Run after npm install in the relay build so a vulnerable transitive
// tar cannot slip past the override.
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';

const MIN = [7, 5, 19];
const cmp = (v) => {
  const p = v.split('.').map(Number);
  for (let i = 0; i < 3; i++) {
    if ((p[i] ?? 0) < MIN[i]) return -1;
    if ((p[i] ?? 0) > MIN[i]) return 1;
  }
  return 0;
};

let paths = [];
try {
  paths = execSync("find node_modules -path '*/tar/package.json'", { encoding: 'utf8' })
    .split('\n').filter(Boolean);
} catch { /* no matches → nothing to check */ }

const bad = [];
for (const path of paths) {
  try {
    const { version } = JSON.parse(readFileSync(path, 'utf8'));
    if (version && cmp(version) < 0) bad.push(`${path} -> ${version}`);
  } catch { /* unreadable/parse error — skip */ }
}

if (bad.length) {
  console.error('VULNERABLE node-tar (< 7.5.19, CVE-2026-59873) remains:');
  for (const b of bad) console.error('  ' + b);
  process.exit(1);
}
console.log(`tar override verified: ${paths.length} copy/copies, all >= 7.5.19`);

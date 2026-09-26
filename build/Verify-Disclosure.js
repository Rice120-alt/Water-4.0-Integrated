#!/usr/bin/env node
const path = require('path');
const { spawnSync } = require('child_process');
const root = path.resolve(__dirname, '..', '..', '..');
const test = path.join(root, 'tools', 'tests', 'Test-Water4SourceDisclosure.js');
const disclosure = path.resolve(__dirname, '..');
const result = spawnSync(process.execPath, [test, disclosure], { stdio: 'inherit' });
process.exit(result.status ?? 1);

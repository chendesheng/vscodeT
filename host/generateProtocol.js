#!/usr/bin/env node
// Generates src/vs/workbench/api/common/extHost.protocol.zig and
// extHost.protocol.manifest.zig from the pinned VS Code checkout.
//
// Port of the generation step described in docs/extensions.md §5.2. The
// generator is deliberately dependency free: it reads the TypeScript source
// and only extracts the static shape of the protocol (identifier order,
// sids, method names and the void/promise split). It never evaluates it.

'use strict';

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');
const vscodeRoot = path.resolve(repoRoot, 'vscode');
const protocolPath = path.join(vscodeRoot, 'src/vs/workbench/api/common/extHost.protocol.ts');
const outDir = path.join(repoRoot, 'src/vs/workbench/api/common');

const source = fs.readFileSync(protocolPath, 'utf8');

function fail(message) {
	console.error(`generateProtocol: ${message}`);
	process.exit(1);
}

// ---------------------------------------------------------------------------
// Context identifiers

function readContext(name) {
	const startMarker = `export const ${name} = {`;
	const start = source.indexOf(startMarker);
	if (start < 0) {
		fail(`missing ${name}`);
	}
	const end = source.indexOf('\n};', start);
	if (end < 0) {
		fail(`unterminated ${name}`);
	}
	const body = source.slice(start + startMarker.length, end);
	const entries = [];
	const re = /^\t(\w+): createProxyIdentifier<([\w.]+)>\('([^']*)'\),?$/gm;
	let match;
	while ((match = re.exec(body)) !== null) {
		entries.push({ key: match[1], shape: match[2], sid: match[3] });
	}
	if (entries.length === 0) {
		fail(`no identifiers in ${name}`);
	}
	return entries;
}

const mainContext = readContext('MainContext');
const extHostContext = readContext('ExtHostContext');
if (mainContext.length !== 89) {
	fail(`MainContext has ${mainContext.length} identifiers, expected 89`);
}
if (extHostContext.length !== 82) {
	fail(`ExtHostContext has ${extHostContext.length} identifiers, expected 82`);
}

const identifiers = [];
for (const entry of mainContext) {
	identifiers.push(entry);
}
for (const entry of extHostContext) {
	identifiers.push(entry);
}
if (identifiers.length !== 171) {
	fail(`total identifier count ${identifiers.length}, expected 171`);
}
if (identifiers.length > 255) {
	fail('identifier count does not fit in a u8');
}

const seenKeys = new Set();
const seenSids = new Set();
for (const entry of identifiers) {
	if (seenKeys.has(entry.key)) {
		fail(`duplicate key ${entry.key}`);
	}
	seenKeys.add(entry.key);
	if (!entry.sid) {
		fail(`empty sid for ${entry.key}`);
	}
	if (seenSids.has(entry.sid)) {
		// Upstream allows aliases only by sharing one identifier; distinct
		// identifiers with the same sid would make logging ambiguous.
		fail(`duplicate sid ${entry.sid}`);
	}
	seenSids.add(entry.sid);
}

// ---------------------------------------------------------------------------
// Shape interfaces

const interfaceBodies = new Map();
for (let index = 0; index < source.length;) {
	const marker = 'export interface ';
	const start = source.indexOf(marker, index);
	if (start < 0) {
		break;
	}
	const nameStart = start + marker.length;
	let cursor = nameStart;
	while (cursor < source.length && /[\w]/.test(source[cursor])) {
		cursor++;
	}
	const name = source.slice(nameStart, cursor);
	// Skip the extends clause and the opening brace.
	const brace = source.indexOf('{', cursor);
	if (brace < 0) {
		fail(`unterminated interface ${name}`);
	}
	// Some interfaces extend a qualified name; make sure this brace belongs
	// to the declaration and not to a generic parameter.
	const extendsText = source.slice(cursor, brace);
	if (!/^(?:\s+extends\s+[\w.,\s]+)?\s*$/.test(extendsText)) {
		index = brace + 1;
		continue;
	}
	let depth = 1;
	let bodyStart = brace + 1;
	let pos = bodyStart;
	while (pos < source.length && depth > 0) {
		const ch = source[pos];
		if (ch === '{') {
			depth++;
		} else if (ch === '}') {
			depth--;
		}
		pos++;
	}
	if (depth !== 0) {
		fail(`unterminated interface body ${name}`);
	}
	const body = source.slice(bodyStart, pos - 1);
	if (!interfaceBodies.has(name)) {
		interfaceBodies.set(name, body);
	}
	index = pos;
}

function parseMethods(shape, body) {
	const methods = [];
	let pos = 0;
	while (pos < body.length) {
		const dollar = body.indexOf('\n\t$', pos);
		if (dollar < 0) {
			break;
		}
		let nameStart = dollar + 2;
		let nameEnd = nameStart;
		while (nameEnd < body.length && /[\w$]/.test(body[nameEnd])) {
			nameEnd++;
		}
		const name = body.slice(nameStart, nameEnd);
		let cursor = nameEnd;
		while (cursor < body.length && /\s/.test(body[cursor])) {
			cursor++;
		}
		if (body[cursor] !== '(') {
			// A property-like member; not a wire method.
			pos = nameEnd;
			continue;
		}
		let depth = 0;
		let parens = 0;
		let angle = 0;
		let close = -1;
		for (; cursor < body.length; cursor++) {
			const ch = body[cursor];
			if (ch === '(') {
				parens++;
			} else if (ch === ')') {
				parens--;
				if (parens === 0) {
					close = cursor;
					break;
				}
			}
		}
		if (close < 0) {
			fail(`unterminated parameter list for ${shape}.${name}`);
		}
		const colon = body.indexOf(':', close);
		if (colon < 0) {
			fail(`missing return type for ${shape}.${name}`);
		}
		let end = colon + 1;
		depth = 0;
		angle = 0;
		for (; end < body.length; end++) {
			const ch = body[end];
			if (ch === '<') {
				angle++;
			} else if (ch === '>') {
				angle--;
			} else if (ch === '(' || ch === '[') {
				depth++;
			} else if (ch === ')' || ch === ']') {
				depth--;
			} else if (ch === ';' && depth === 0 && angle === 0) {
				break;
			}
		}
		if (end >= body.length) {
			fail(`unterminated method ${shape}.${name}`);
		}
		const returnType = body.slice(colon + 1, end).replace(/\s+/g, ' ').trim();
		if (returnType.length === 0) {
			fail(`empty return type for ${shape}.${name}`);
		}
		methods.push({ name, notification: returnType === 'void' });
		pos = end + 1;
	}
	return methods;
}

const shapeMethods = new Map();
for (const entry of identifiers) {
	if (!interfaceBodies.has(entry.shape)) {
		fail(`missing shape interface ${entry.shape} for ${entry.key}`);
	}
	if (!shapeMethods.has(entry.shape)) {
		shapeMethods.set(entry.shape, parseMethods(entry.shape, interfaceBodies.get(entry.shape)));
	}
}

// ---------------------------------------------------------------------------
// Zig output

const zigString = value => JSON.stringify(value);

function actorBlock(entry) {
	const methods = shapeMethods.get(entry.shape);
	const lines = [];
	lines.push(`pub const ${entry.key} = struct {`);
	lines.push(`\tpub const key = ${zigString(entry.key)};`);
	lines.push(`\tpub const sid = ${zigString(entry.sid)};`);
	lines.push(`\tpub const nid: u8 = ${identifiers.indexOf(entry) + 1};`);
	lines.push('\tpub const methods = [_]Method{');
	for (const method of methods) {
		lines.push(`\t\t.{ .name = ${zigString(method.name)}, .kind = .${method.notification ? 'notification' : 'request'} },`);
	}
	lines.push('\t};');
	lines.push('};');
	return lines.join('\n');
}

const header = `// Generated by host/generateProtocol.js from
// vscode/src/vs/workbench/api/common/extHost.protocol.ts.
// Do not edit by hand. Regenerate when the pinned host changes.
//
// Pinned host: VS Code 1.147.0. The identifier order and the void/promise
// split are part of the wire contract (docs/extensions.md §5.2).
`;

const parts = [];
parts.push(header);
parts.push('');
parts.push('pub const pinned_version = "1.147.0";');
parts.push('pub const main_context_count = 89;');
parts.push('pub const ext_host_context_count = 82;');
parts.push('pub const max_nid: u8 = 171;');
parts.push('');
parts.push('pub const MethodKind = enum { notification, request };');
parts.push('');
parts.push('pub const Method = struct {');
parts.push('\tname: []const u8,');
parts.push('\tkind: MethodKind,');
parts.push('};');
parts.push('');
parts.push('pub const ProxyIdentifier = struct {');
parts.push('\tkey: []const u8,');
parts.push('\tsid: []const u8,');
parts.push('\tnid: u8,');
parts.push('};');
parts.push('');
parts.push('pub const identifier_table = [_]?ProxyIdentifier{');
parts.push('\tnull,');
for (let i = 0; i < identifiers.length; i++) {
	const entry = identifiers[i];
	parts.push(`\t.{ .key = ${zigString(entry.key)}, .sid = ${zigString(entry.sid)}, .nid = ${i + 1} },`);
}
parts.push('};');
parts.push('');
for (const entry of identifiers) {
	parts.push(actorBlock(entry));
	parts.push('');
}
parts.push(`pub const MainContext = enum(u8) {`);
for (let i = 0; i < mainContext.length; i++) {
	parts.push(`\t${mainContext[i].key} = ${i + 1},`);
}
parts.push('};');
parts.push('');
parts.push(`pub const ExtHostContext = enum(u8) {`);
for (let i = 0; i < extHostContext.length; i++) {
	parts.push(`\t${extHostContext[i].key} = ${mainContext.length + i + 1},`);
}
parts.push('};');
parts.push('');
parts.push('pub fn identifier(nid: u8) ?ProxyIdentifier {');
parts.push('\tif (nid == 0 or nid > max_nid) return null;');
parts.push('\treturn identifier_table[nid];');
parts.push('}');
parts.push('');
parts.push('pub fn actorForSid(sid: []const u8) ?ProxyIdentifier {');
parts.push('\tfor (identifier_table) |maybe_entry| {');
parts.push('\t\tconst entry = maybe_entry orelse continue;');
parts.push('\t\tif (std.mem.eql(u8, entry.sid, sid)) return entry;');
parts.push('\t}');
parts.push('\treturn null;');
parts.push('}');
parts.push('');
parts.push('pub fn methodFor(nid: u8, name: []const u8) ?Method {');
parts.push('\treturn switch (nid) {');
for (let i = 0; i < identifiers.length; i++) {
	const entry = identifiers[i];
	parts.push(`\t\t${i + 1} => find(${entry.key}.methods, name),`);
}
parts.push('\t\telse => null,');
parts.push('\t};');
parts.push('}');
parts.push('');
parts.push('fn find(methods: []const Method, name: []const u8) ?Method {');
parts.push('\tfor (methods) |method| {');
parts.push('\t\tif (std.mem.eql(u8, method.name, name)) return method;');
parts.push('\t}');
parts.push('\treturn null;');
parts.push('}');
parts.push('');
parts.push('const std = @import("std");');
parts.push('');

const out = parts.join('\n');
fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(path.join(outDir, 'extHost.protocol.zig'), out);

// A compact manifest for tests and tooling: one line per actor.
const manifest = [];
manifest.push('# Generated by host/generateProtocol.js. Do not edit.');
manifest.push(`# Pinned host: VS Code 1.147.0`);
for (let i = 0; i < identifiers.length; i++) {
	const entry = identifiers[i];
	const methods = shapeMethods.get(entry.shape);
	manifest.push(`${i + 1}\t${entry.key}\t${entry.sid}\t${methods.length}`);
}
fs.writeFileSync(path.join(outDir, 'extHost.protocol.manifest.txt'), manifest.join('\n') + '\n');

console.log(`wrote ${path.relative(repoRoot, outDir)}/extHost.protocol.zig (${identifiers.length} actors)`);

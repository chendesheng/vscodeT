// Bundles host/extensionHost.ts and the pinned VS Code extension host sources
// into host/dist/extensionHost.mjs.
//
// The upstream tree is TypeScript with ESM `.js` specifiers. esbuild resolves
// those to the sibling `.ts` file; no `out/` build of VS Code is required.
// Only the module graph reachable from the launcher is bundled, so the whole
// workbench is not compiled.
//
// The launcher imports the upstream sources through the `../vscode/` prefix.
// The pinned `vscode/` submodule is always the tree those imports resolve to,
// so a checkout that is not the pinned version never ends up in the bundle.
// The actor table the Zig workbench uses is generated from the same tree
// (`host/generateProtocol.js`); mixing versions makes every RPC land on the
// wrong actor, and the host then hangs instead of failing, so the version is
// checked here.

import * as esbuild from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..');
const pinnedVersion = '1.147.0';
const vscodeRoot = path.resolve(repoRoot, 'vscode');

const vscodeManifestPath = path.join(vscodeRoot, 'package.json');
if (!fs.existsSync(vscodeManifestPath)) {
	console.error(`VS Code sources not found at ${vscodeRoot}`);
	console.error('initialize the pinned vscode/ submodule: git submodule update --init --depth 1');
	process.exit(1);
}
const vscodeVersion = JSON.parse(fs.readFileSync(vscodeManifestPath, 'utf8')).version;
if (vscodeVersion !== pinnedVersion) {
	console.error(`VS Code ${vscodeVersion} at ${vscodeRoot} is not the pinned host ${pinnedVersion}`);
	console.error('the generated RPC actor table only matches the pinned version;');
	console.error('check out the pinned vscode/ submodule at ' + pinnedVersion);
	process.exit(1);
}

const LAUNCHER_PREFIX = '../vscode/';

// Resolves the launcher's `../vscode/...` imports against `vscodeRoot`
// instead of the launcher's own directory.
const pinnedVscode = {
	name: 'pinned-vscode-source',
	setup(build) {
		build.onResolve({ filter: /^\.\.\/vscode\// }, args => {
			if (!args.path.startsWith(LAUNCHER_PREFIX)) {
				return undefined;
			}
			const resolved = path.join(vscodeRoot, args.path.slice(LAUNCHER_PREFIX.length));
			if (resolved.endsWith('.js')) {
				const ts = resolved.slice(0, -3) + '.ts';
				if (fs.existsSync(ts)) {
					return { path: ts };
				}
			}
			return { path: resolved };
		});
	}
};

const jsToTs = {
	name: 'vscode-js-to-ts',
	setup(build) {
		build.onResolve({ filter: /\.js$/ }, args => {
			if (args.path.startsWith('vscode')) {
				return undefined;
			}
			const resolved = path.resolve(args.resolveDir, args.path);
			const ts = resolved.slice(0, -3) + '.ts';
			if (fs.existsSync(ts)) {
				return { path: ts };
			}
			return undefined;
		});
	}
};

const result = await esbuild.build({
	entryPoints: [path.join(here, 'extensionHost.ts')],
	bundle: true,
	platform: 'node',
	format: 'esm',
	target: 'node24',
	outfile: path.join(here, 'dist/extensionHost.mjs'),
	plugins: [pinnedVscode, jsToTs],
	nodePaths: [path.join(here, 'node_modules')],
	external: ['vscode', '@vscode/*', 'kerberos'],
	tsconfigRaw: {
		compilerOptions: {
			experimentalDecorators: true,
			useDefineForClassFields: false,
			target: 'ES2024'
		}
	},
	logLevel: 'warning',
	metafile: true,
	define: {
		'process.env.NODE_ENV': '"production"'
	}
});

const outputs = Object.entries(result.metafile.outputs);
for (const [file, info] of outputs) {
	console.log(`${path.relative(repoRoot, file)}: ${(info.bytes / 1024 / 1024).toFixed(2)} MiB`);
}
console.log(`built against ${vscodeRoot} (VS Code ${vscodeVersion})`);

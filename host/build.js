// Bundles host/extensionHost.ts and the pinned `../vscode` extension host
// sources into host/dist/extensionHost.mjs.
//
// The upstream tree is TypeScript with ESM `.js` specifiers. esbuild resolves
// those to the sibling `.ts` file; no `out/` build of VS Code is required.
// Only the module graph reachable from the launcher is bundled, so the whole
// workbench is not compiled.

import * as esbuild from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..');
const vscodeRoot = process.env.VSCODE_SOURCE_PATH
	? path.resolve(process.env.VSCODE_SOURCE_PATH)
	: path.resolve(repoRoot, '..', 'vscode');

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
	plugins: [jsToTs],
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
console.log(`built against ${vscodeRoot}`);

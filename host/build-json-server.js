// Bundles the pinned VS Code JSON language server into host/dist so the TUI
// can launch it without a full `../vscode` extension compile.
import * as esbuild from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..');
const vscodeRoot = process.env.VSCODE_SOURCE_PATH
	? path.resolve(process.env.VSCODE_SOURCE_PATH)
	: path.resolve(repoRoot, '..', 'vscode');
const entry = path.join(vscodeRoot, 'extensions/json-language-features/server/src/node/jsonServerMain.ts');

const jsToTs = {
	name: 'vscode-js-to-ts',
	setup(build) {
		build.onResolve({ filter: /\.js$/ }, args => {
			const resolved = path.resolve(args.resolveDir, args.path);
			const ts = resolved.slice(0, -3) + '.ts';
			if (fs.existsSync(ts)) return { path: ts };
			return undefined;
		});
	}
};

const result = await esbuild.build({
	entryPoints: [entry],
	bundle: true,
	platform: 'node',
	format: 'esm',
	target: 'node24',
	outfile: path.join(here, 'dist/jsonServer.mjs'),
	plugins: [jsToTs],
	nodePaths: [path.join(vscodeRoot, 'extensions/json-language-features/server/node_modules'), path.join(here, 'node_modules')],
	logLevel: 'warning',
	metafile: true,
	banner: {
		js: "import { createRequire as __createRequire } from 'node:module'; const require = __createRequire(import.meta.url);"
	}
});
for (const [file, info] of Object.entries(result.metafile.outputs)) {
	console.log(`${path.relative(repoRoot, file)}: ${(info.bytes / 1024 / 1024).toFixed(2)} MiB`);
}

// Bundle the pinned desktop extension entry points implemented by the Node
// bridge. Keep their manifests and relative module locations intact so that
// extension activation and vscode.extensions use the upstream identities.
import { build } from 'esbuild';
import { cp, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const upstream = path.resolve(here, '../vscode/extensions');
const destination = path.join(here, 'dist/extensions');

for (const name of ['git-base', 'php-language-features', 'search-result']) {
    const root = path.join(upstream, name);
    const target = path.join(destination, name);
    const manifest = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
    const entry = path.basename(manifest.main, '.js');
    manifest.main = './dist/' + entry + '.js';
    await mkdir(target, { recursive: true });
    await build({
        entryPoints: [path.join(root, 'src', entry + '.ts')],
        outfile: path.join(target, manifest.main),
        platform: 'node',
        target: 'node24',
        format: 'cjs',
        bundle: true,
        external: ['vscode'],
        nodePaths: [path.join(here, 'node_modules')]
    });
    await cp(path.join(root, 'package.nls.json'), path.join(target, 'package.nls.json'));
    await writeFile(path.join(target, 'package.json'), JSON.stringify(manifest, null, 2) + '\n');
}

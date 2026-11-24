// Bundle desktop entry points from the pinned checkout. Clients locate their
// servers, schemas and TypeScript SDK relative to the installed manifest.
import { build } from 'esbuild';
import { cp, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const upstream = path.resolve(here, '../vscode/extensions');
const destination = path.join(here, 'dist/extensions');
const modules = path.join(here, 'node_modules');
const options = {
    platform: 'node', target: 'node24', bundle: true, format: 'cjs',
    // Prefer the ESM entries. Older jsonc-parser UMD builds resolve sibling
    // files with a factory-local require that a bundler cannot rewrite.
    mainFields: ['module', 'main'], external: ['vscode', '@vscode/internal-github'], nodePaths: [modules]
};

async function bundleExtension(name, client, resources = [], alias = {}) {
    const root = path.join(upstream, name);
    const target = path.join(destination, name);
    const manifest = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
    const source = client.replace('/dist/', '/src/').replace(/^dist\//, 'src/').replace(/\.js$/, '.ts');
    await build({ ...options, alias, entryPoints: [path.join(root, source)], outfile: path.join(target, client) });
    for (const resource of ['package.nls.json', ...resources]) {
        await cp(path.join(root, resource), path.join(target, resource), { recursive: true });
    }
    const labels = JSON.parse(await readFile(path.join(target, 'package.nls.json'), 'utf8'));
    for (const command of manifest.contributes?.commands ?? []) {
        for (const key of ['title', 'category']) {
            const value = command[key];
            if (typeof value === 'string' && value.startsWith('%') && value.endsWith('%')) {
                command[key] = labels[value.slice(1, -1)] ?? value;
            }
        }
    }
    manifest.main = './' + client;
    await writeFile(path.join(target, 'package.json'), JSON.stringify(manifest, null, 2) + '\n');
}

async function bundleWebLanguage(language) {
    const name = language + '-language-features';
    const server = path.join(destination, name, 'server');
    const source = path.join(upstream, name, 'server');
    await bundleExtension(name, 'client/dist/node/' + language + 'ClientMain.js');
    await build({
        ...options, format: 'esm', external: ['vscode', 'typescript'],
        entryPoints: [path.join(source, 'src/node/' + language + 'ServerNodeMain.ts')],
        outfile: path.join(server, 'dist/node/' + language + 'ServerMain.js'),
        banner: { js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" }
    });
    await cp(path.join(source, 'package.json'), path.join(server, 'package.json'));
    if (language === 'html') await cp(path.join(source, 'lib'), path.join(server, 'lib'), { recursive: true });
}

export async function bundleTypeScript() {
    await bundleExtension('typescript-language-features', 'dist/extension.js', ['schemas']);
    const sdk = path.join(destination, 'node_modules/typescript');
    await mkdir(sdk, { recursive: true });
    await cp(path.join(modules, 'typescript/package.json'), path.join(sdk, 'package.json'));
    await cp(path.join(modules, 'typescript/lib'), path.join(sdk, 'lib'), { recursive: true });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    await cp(path.join(upstream, '../product.json'), path.join(here, 'dist/product.json'));
    await bundleExtension('configuration-editing', 'dist/configurationEditingMain.js');
    await bundleExtension('extension-editing', 'dist/extensionEditingMain.js');
    for (const name of ['grunt', 'gulp', 'jake']) await bundleExtension(name, 'dist/main.js');
    await bundleExtension('npm', 'dist/npmMain.js', [], {
        which: 'npm-extension-which', 'request-light': 'npm-extension-http', 'vscode-uri': 'npm-extension-uri'
    });
    await bundleExtension('simple-browser', 'dist/extension.js');
    await bundleExtension('merge-conflict', 'dist/mergeConflictMain.js');
    await bundleExtension('git-base', 'dist/extension.js');
    await bundleExtension('php-language-features', 'dist/phpMain.js');
    await bundleExtension('search-result', 'dist/extension.js');
    await bundleExtension('emmet', 'dist/node/emmetNodeMain.js');
    await bundleWebLanguage('css');
    await bundleWebLanguage('html');
    const copilot = path.join(destination, 'copilot');
    await build({ ...options, entryPoints: [path.join(here, 'copilot-inline/extension.cjs')], outfile: path.join(copilot, 'extension.cjs') });
    await cp(path.join(here, 'copilot-inline/package.json'), path.join(copilot, 'package.json'));
    await bundleTypeScript();
}

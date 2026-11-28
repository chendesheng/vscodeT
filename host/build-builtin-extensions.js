// Bundle desktop entry points from the pinned checkout. Clients locate their
// servers, schemas and TypeScript SDK relative to the installed manifest.
import { build } from 'esbuild';
import { cp, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const upstream = path.resolve(here, '../vscode/extensions');
const galleryRelease = process.argv.includes('--gallery-extensions');
const galleryExtensions = new Set(readFileSync(path.join(here, '../src/vs/platform/product/common/galleryExtensions.txt'), 'utf8').trim().split(/\r?\n/));
const destination = path.join(here, galleryRelease ? 'dist/gallery-release-extensions' : 'dist/extensions');
const isBundled = name => !galleryRelease || !galleryExtensions.has(name);
const modules = path.join(here, 'node_modules');
const options = {
    platform: 'node', target: 'node24', bundle: true, format: 'cjs',
    // Prefer the ESM entries. Older jsonc-parser UMD builds resolve sibling
    // files with a factory-local require that a bundler cannot rewrite.
    mainFields: ['module', 'main'], external: ['vscode', '@vscode/internal-github'], nodePaths: [modules]
};

async function bundleExtension(name, client, resources = [], alias = {}, external = []) {
    if (!isBundled(name)) return;
    const root = path.join(upstream, name);
    const target = path.join(destination, name);
    const manifest = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
    const source = client.replace('/dist/', '/src/').replace(/^dist\//, 'src/').replace(/\.js$/, '.ts');
    await build({ ...options, external: [...options.external, ...external], alias, entryPoints: [path.join(root, source)], outfile: path.join(target, client) });
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
    if (!isBundled(name)) return;
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
    if (!isBundled('typescript-language-features')) return;
    await bundleExtension('typescript-language-features', 'dist/extension.js', ['schemas']);
    const sdk = path.join(destination, 'node_modules/typescript');
    await mkdir(sdk, { recursive: true });
    await cp(path.join(modules, 'typescript/package.json'), path.join(sdk, 'package.json'));
    await cp(path.join(modules, 'typescript/lib'), path.join(sdk, 'lib'), { recursive: true });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    // Release output is isolated from the complete development/test bundles.
    if (galleryRelease) await rm(destination, { recursive: true, force: true });
    await mkdir(destination, { recursive: true });
    await cp(path.join(upstream, '../product.json'), path.join(here, 'dist/product.json'));
    await bundleExtension('configuration-editing', 'dist/configurationEditingMain.js');
    await bundleExtension('extension-editing', 'dist/extensionEditingMain.js');
    for (const name of ['grunt', 'gulp', 'jake']) await bundleExtension(name, 'dist/main.js');
    await bundleExtension('npm', 'dist/npmMain.js', [], {
        which: 'npm-extension-which', 'request-light': 'npm-extension-http', 'vscode-uri': 'npm-extension-uri'
    });
    await bundleExtension('github-authentication', 'dist/extension.js');
    await bundleExtension('microsoft-authentication', 'dist/extension.js', [], {
        keytar: path.join(upstream, 'microsoft-authentication/packageMocks/keytar/index.js')
    }, ['electron', './msal-node-runtime']);
    // Native MSAL binaries must match the release target, not the runner that
    // happens to build a cross-compiled binary (for example aarch64 musl on an
    // x86_64 Linux runner).
    const targetPlatform = process.env.MINECODE_TARGET_PLATFORM || process.platform;
    const targetArch = process.env.MINECODE_TARGET_ARCH || process.arch;
    const platformFolder = { darwin: 'macos', win32: 'windows', linux: 'linux' }[targetPlatform];
    if (platformFolder) {
        const source = path.join(modules, '@azure/msal-node-runtime/dist', platformFolder, targetArch);
        const binaries = await readdir(source).catch(error => {
            if (error.code === 'ENOENT') return [];
            throw error;
        });
        for (const binary of binaries.filter(name => /^(lib)?msal.*\.(node|dll|dylib|so)$/.test(name))) {
            await cp(path.join(source, binary), path.join(destination, 'microsoft-authentication/dist', binary));
        }
    }
    await bundleExtension('terminal-suggest', 'dist/terminalSuggestMain.js');
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

// Provisions the real VS Code TypeScript extension for the pinned extension
// host.
//
// The extension host loads extensions from `host/dist/extensions` at runtime.
// This script copies VS Code's shipped `typescript-language-features` bundle
// and the TypeScript SDK it expects at `extensions/node_modules/typescript`,
// so the host runs the real extension without compiling the pinned checkout.
//
// Sources, in order:
//   1. Auto-detected VS Code installations.
//   2. A built extension under the pinned `vscode/extensions/.../dist`.
//   3. The extension's bundled TypeScript SDK, then the checkout's installed
//      `node_modules/typescript` when the app did not ship one.
//
// Run from `host/`: `node build-typescript-extension.js`.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..');
const vscodeRoot = path.resolve(repoRoot, 'vscode');
const outRoot = path.join(here, 'dist', 'extensions');
const extensionName = 'typescript-language-features';
const outExtension = path.join(outRoot, extensionName);
const outSdk = path.join(outRoot, 'node_modules', 'typescript');

function fail(message) {
	console.error(message);
	process.exit(1);
}

function isDirectory(value) {
	try {
		return fs.statSync(value).isDirectory();
	} catch {
		return false;
	}
}

function isFile(value) {
	try {
		return fs.statSync(value).isFile();
	} catch {
		return false;
	}
}

function appCandidates() {
	const candidates = [];
	if (process.platform === 'darwin') {
		candidates.push('/Applications/Visual Studio Code.app/Contents/Resources/app');
		candidates.push(path.join(process.env.HOME ?? '', 'Applications', 'Visual Studio Code.app', 'Contents', 'Resources', 'app'));
	} else if (process.platform === 'win32') {
		for (const base of [process.env.LOCALAPPDATA, process.env.PROGRAMFILES, process.env['PROGRAMFILES(X86)']]) {
			if (base) candidates.push(path.join(base, 'Microsoft VS Code', 'resources', 'app'));
		}
	} else {
		candidates.push('/usr/share/code', '/usr/lib/code', '/opt/visual-studio-code', '/snap/code/current/usr/share/code');
	}
	return candidates;
}

function findAppRoot() {
	for (const candidate of appCandidates()) {
		if (!candidate) continue;
		const root = path.resolve(candidate);
		if (isFile(path.join(root, 'extensions', extensionName, 'dist', 'extension.js'))) {
			return root;
		}
	}
	return undefined;
}

function copyFile(source, target) {
	fs.mkdirSync(path.dirname(target), { recursive: true });
	fs.copyFileSync(source, target);
}

function copyTypeScriptSdk(sdkRoot, required) {
	const packagePath = path.join(sdkRoot, 'package.json');
	const tsserverPath = path.join(sdkRoot, 'lib', 'tsserver.js');
	if (!isFile(packagePath) || !isFile(tsserverPath)) {
		if (required) fail(`No TypeScript SDK with lib/tsserver.js at ${sdkRoot}`);
		return undefined;
	}
	fs.rmSync(outSdk, { recursive: true, force: true });
	fs.mkdirSync(outSdk, { recursive: true });
	copyFile(packagePath, path.join(outSdk, 'package.json'));
	fs.cpSync(path.join(sdkRoot, 'lib'), path.join(outSdk, 'lib'), { recursive: true, dereference: true });
	const version = JSON.parse(fs.readFileSync(packagePath, 'utf8')).version ?? 'unknown';
	return { version, root: sdkRoot };
}

function sdkCandidates(appRoot) {
	const candidates = [];
	if (appRoot) candidates.push(path.join(appRoot, 'extensions', 'node_modules', 'typescript'));
	candidates.push(path.join(vscodeRoot, 'node_modules', 'typescript'));
	candidates.push(path.join(vscodeRoot, 'extensions', 'node_modules', 'typescript'));
	candidates.push(path.join(here, 'node_modules', 'typescript'));
	return candidates;
}

function installFromApp(appRoot) {
	const sourceExtension = path.join(appRoot, 'extensions', extensionName);
	fs.rmSync(outExtension, { recursive: true, force: true });
	fs.mkdirSync(outExtension, { recursive: true });
	const manifest = JSON.parse(fs.readFileSync(path.join(sourceExtension, 'package.json'), 'utf8'));
	// The copied tree always contains the shipped bundle, even when the source
	// manifest points at a checkout's `out/` directory.
	manifest.main = './dist/extension';
	fs.writeFileSync(path.join(outExtension, 'package.json'), JSON.stringify(manifest, null, '\t'));
	const nlsPath = path.join(sourceExtension, 'package.nls.json');
	if (isFile(nlsPath)) copyFile(nlsPath, path.join(outExtension, 'package.nls.json'));
	copyFile(path.join(sourceExtension, 'dist', 'extension.js'), path.join(outExtension, 'dist', 'extension.js'));
	const schemaDir = path.join(sourceExtension, 'schemas');
	if (isDirectory(schemaDir)) {
		fs.cpSync(schemaDir, path.join(outExtension, 'schemas'), { recursive: true, dereference: true });
	}

	let sdk;
	for (const candidate of sdkCandidates(appRoot)) {
		if (!candidate || !isDirectory(candidate)) continue;
		sdk = copyTypeScriptSdk(candidate, false);
		if (sdk) break;
	}
	if (!sdk) fail(`Found ${extensionName} at ${sourceExtension} but no TypeScript SDK`);
	return { manifest, source: path.join(sourceExtension, 'dist', 'extension.js'), sdk };
}

function installFromCheckout() {
	const sourceExtension = path.join(vscodeRoot, 'extensions', extensionName);
	const builtBundle = path.join(sourceExtension, 'dist', 'extension.js');
	if (!isFile(builtBundle)) return undefined;
	fs.rmSync(outExtension, { recursive: true, force: true });
	fs.mkdirSync(outExtension, { recursive: true });
	const manifest = JSON.parse(fs.readFileSync(path.join(sourceExtension, 'package.json'), 'utf8'));
	manifest.main = './dist/extension';
	fs.writeFileSync(path.join(outExtension, 'package.json'), JSON.stringify(manifest, null, '\t'));
	const nlsPath = path.join(sourceExtension, 'package.nls.json');
	if (isFile(nlsPath)) copyFile(nlsPath, path.join(outExtension, 'package.nls.json'));
	copyFile(builtBundle, path.join(outExtension, 'dist', 'extension.js'));
	const schemaDir = path.join(sourceExtension, 'schemas');
	if (isDirectory(schemaDir)) {
		fs.cpSync(schemaDir, path.join(outExtension, 'schemas'), { recursive: true, dereference: true });
	}
	let sdk;
	for (const candidate of sdkCandidates(undefined)) {
		if (!candidate || !isDirectory(candidate)) continue;
		sdk = copyTypeScriptSdk(candidate, false);
		if (sdk) break;
	}
	if (!sdk) fail(`Found a built ${extensionName} but no bundled TypeScript SDK`);
	return { manifest, source: builtBundle, sdk };
}

const appRoot = findAppRoot();
const installed = appRoot ? installFromApp(appRoot) : installFromCheckout();
if (!installed) {
	fail(
		'No VS Code installation with extensions/typescript-language-features/dist/extension.js found.\n' +
		'Install VS Code in a standard location, or build the pinned checkout\'s extension.'
	);
}

// The extension looks up the bundled SDK as <extensionPath>/../node_modules/typescript.
fs.mkdirSync(outSdk, { recursive: true });

console.log(`typescript-language-features ${installed.manifest.version ?? 'unknown'}`);
console.log(`  extension: ${path.relative(repoRoot, outExtension)}`);
console.log(`  typescript ${installed.sdk.version}: ${path.relative(repoRoot, outSdk)}`);
console.log(`  source: ${installed.source}`);

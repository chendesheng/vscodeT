// Standalone entry point for tooling that provisions only TypeScript.
import { bundleTypeScript } from './build-builtin-extensions.js';

await bundleTypeScript();

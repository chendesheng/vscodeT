// Render an isolated Markdown fence without browser scripts or network access.
import { readFileSync } from 'node:fs';
import { renderMermaidASCII } from 'beautiful-mermaid';

try {
    const source = readFileSync(0, 'utf8');
    process.stdout.write(renderMermaidASCII(source, { colorMode: 'none' }));
} catch {
    // The preview keeps the original fence when a diagram cannot be rendered.
    process.exitCode = 1;
}

// Linearize KaTeX's presentation MathML for a terminal. Preserve the source
// in the preview when a construct has no supported text representation.
import { readFileSync } from 'node:fs';
import katex from 'katex';
import parse5 from 'parse5';

const superscripts = '⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾';
const subscripts = '₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎';
function script(text, upper) {
    const chars = [...text].map(c => '0123456789+-=()'.indexOf(c));
    if (chars.every(i => i >= 0)) return chars.map(i => (upper ? superscripts : subscripts)[i]).join('');
    return (upper ? '^' : '_') + '(' + text + ')';
}
function group(text) {
    return [...text].length === 1 || /^\d+$/.test(text) ? text : '(' + text + ')';
}
function render(node) {
    if (node.nodeName === '#text') return node.value;
    if (node.nodeName === 'annotation') return '';
    const children = (node.childNodes || []).map(render);
    const [base, sub, sup] = children;
    switch (node.nodeName) {
        case '#document-fragment': case 'span': case 'math': case 'semantics':
        case 'mrow': case 'mstyle': case 'mi': case 'mn': case 'mo': case 'mtext':
            return children.join('');
        case 'mspace': return ' ';
        case 'msup': return group(base) + script(sub, true);
        case 'msub': return group(base) + script(sub, false);
        case 'msubsup': return group(base) + script(sub, false) + script(sup, true);
        case 'mfrac': return group(base) + '/' + group(sub);
        case 'msqrt': return '√(' + children.join('') + ')';
        case 'mroot': return 'root(' + sub + ', ' + base + ')';
        default: throw new Error('Unsupported MathML element');
    }
}

try {
    const source = readFileSync(0, 'utf8');
    const math = katex.renderToString(source, { output: 'mathml', throwOnError: true, trust: false });
    const text = render(parse5.parseFragment(math));
    if (!text || /[\u0000-\u001f\u007f-\u009f]/u.test(text)) throw new Error('Invalid display text');
    process.stdout.write(text);
} catch {
    process.exitCode = 1;
}

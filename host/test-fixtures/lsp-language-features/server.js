// Deterministic mock of the reference ZLS full capability set. Every request
// is serviced over real JSON-RPC/Content-Length framing via vscode-languageserver.
const {
  createConnection, ProposedFeatures, TextDocuments, TextDocumentSyncKind,
  DiagnosticSeverity, CompletionItemKind, InsertTextFormat, SymbolKind,
  InlayHintKind, DocumentHighlightKind, CodeActionKind, SignatureHelpTriggerKind,
} = require('vscode-languageserver/node');
const { TextDocument } = require('vscode-languageserver-textdocument');
const connection = createConnection(ProposedFeatures.all);
const documents = new TextDocuments(TextDocument);
const counts = Object.create(null);
let initial = null;
let lastUri = null;
let lastSaveText = null;
let lastChange = null;
let watched = [];
let folders = [];
let configuration;
const bump = (name) => { counts[name] = (counts[name] || 0) + 1; };
const pos = (line, character) => ({ line, character });
const range = (line, start, end) => ({ start: pos(line, start), end: pos(line, end) });
const alphaRange = range(0, 0, 5);
const betaRange = range(1, 2, 6);
const location = (uri, r = alphaRange) => ({ uri, range: r });

connection.onInitialize(params => {
  initial = params.capabilities;
  folders = params.workspaceFolders || [];
  return { capabilities: {
    positionEncoding: 'utf-16',
    textDocumentSync: { openClose: true, change: TextDocumentSyncKind.Incremental, willSaveWaitUntil: true, save: { includeText: true } },
    completionProvider: { triggerCharacters: ['.'], completionItem: { labelDetailsSupport: true } },
    hoverProvider: true,
    signatureHelpProvider: { triggerCharacters: ['('], retriggerCharacters: [','] },
    definitionProvider: true, declarationProvider: true, typeDefinitionProvider: true,
    referencesProvider: true, documentHighlightProvider: true,
    documentSymbolProvider: true, workspaceSymbolProvider: { resolveProvider: false },
    codeActionProvider: { codeActionKinds: [CodeActionKind.QuickFix, CodeActionKind.Refactor, CodeActionKind.SourceOrganizeImports, CodeActionKind.SourceFixAll] },
    documentFormattingProvider: true,
    renameProvider: { prepareProvider: true }, foldingRangeProvider: true,
    selectionRangeProvider: true,
    semanticTokensProvider: { legend: { tokenTypes: ['variable', 'function'], tokenModifiers: ['declaration'] }, full: { delta: true }, range: true },
    inlayHintProvider: { resolveProvider: true },
    workspace: { workspaceFolders: { supported: true, changeNotifications: true } },
  }, serverInfo: { name: 'minecode-mock-zls', version: '1.0.0' } };
});
connection.onInitialized(async () => {
  bump('initialized');
  try { configuration = await connection.workspace.getConfiguration('lspFixture'); } catch (_) {}
  connection.workspace.onDidChangeWorkspaceFolders(event => {
    const removed = new Set(event.removed.map(f => f.uri));
    folders = folders.filter(f => !removed.has(f.uri)).concat(event.added);
    bump('workspaceFolders');
  });
});
connection.onDidChangeConfiguration(async () => {
  bump('configurationChanged');
  try { configuration = await connection.workspace.getConfiguration('lspFixture'); } catch (_) {}
});
documents.onDidOpen(({ document }) => {
  lastUri = document.uri;
  bump('open');
  connection.sendDiagnostics({ uri: document.uri, diagnostics: [{ range: alphaRange, message: 'Mock diagnostic', severity: DiagnosticSeverity.Warning, source: 'mock-lsp' }] });
});
documents.onDidChangeContent(({ document }) => {
  lastUri = document.uri;
  lastChange = { text: document.getText(), version: document.version };
  bump('change');
});
documents.onDidClose(({ document }) => { bump('close'); connection.sendDiagnostics({ uri: document.uri, diagnostics: [] }); });
documents.onDidSave(({ document }) => { bump('save'); lastSaveText = document.getText(); });
documents.onWillSaveWaitUntil(({ document }) => {
  bump('willSaveWaitUntil');
  return document.getText().startsWith('// mock save\n') ? [] : [{ range: range(0, 0, 0), newText: '// mock save\n' }];
});
connection.onDidChangeWatchedFiles(event => { watched.push(...event.changes); bump('watchedFiles'); });
connection.onHover(({ textDocument, position }) => {
  bump('hover');
  return { contents: { kind: 'markdown', value: `Mock hover: ${documents.get(textDocument.uri)?.getText().split('\n')[position.line]}` }, range: range(position.line, 0, 5) };
});
connection.onCompletion(() => { bump('completion'); return [{ label: 'mockCompletion', kind: CompletionItemKind.Function, detail: 'Mock LSP completion', labelDetails: { detail: '(value)', description: 'mock' }, insertText: 'mockCompletion(${1:value})', insertTextFormat: InsertTextFormat.Snippet }]; });
connection.onSignatureHelp(({ context }) => { bump('signatureHelp'); return { signatures: [{ label: 'alpha(value: number)', parameters: [{ label: 'value: number' }] }], activeSignature: 0, activeParameter: context?.triggerKind === SignatureHelpTriggerKind.TriggerCharacter ? 0 : 0 }; });
for (const [name, register] of [['definition', 'onDefinition'], ['declaration', 'onDeclaration'], ['typeDefinition', 'onTypeDefinition']]) {
  connection[register](({ textDocument }) => { bump(name); return location(textDocument.uri, betaRange); });
}
connection.onReferences(({ textDocument }) => { bump('references'); return [location(textDocument.uri), location(textDocument.uri, betaRange)]; });
connection.onDocumentHighlight(() => { bump('highlight'); return [{ range: alphaRange, kind: DocumentHighlightKind.Read }, { range: betaRange, kind: DocumentHighlightKind.Write }]; });
connection.onDocumentSymbol(() => { bump('documentSymbol'); return [{ name: 'alpha', kind: SymbolKind.Function, range: { start: pos(0, 0), end: pos(2, 1) }, selectionRange: alphaRange }]; });
connection.onWorkspaceSymbol(({ query }) => { bump('workspaceSymbol'); return lastUri && 'MockWorkspaceSymbol'.toLowerCase().includes(query.toLowerCase()) ? [{ name: 'MockWorkspaceSymbol', kind: SymbolKind.Function, location: location(lastUri, betaRange) }] : []; });
connection.onCodeAction(({ textDocument, context }) => {
  bump('codeAction');
  // The actual ExtHostLanguageFeatures adapter must collect diagnostics that
  // intersect the requested range from its registered DiagnosticCollection.
  if (!context.diagnostics.some(diagnostic => diagnostic.message === 'Mock diagnostic')) return [];
  return [{ title: 'Mock quick fix', kind: CodeActionKind.QuickFix, edit: { changes: { [textDocument.uri]: [{ range: alphaRange, newText: 'fixed' }] } } }];
});
connection.onDocumentFormatting(() => { bump('format'); return [{ range: range(1, 0, 2), newText: '    ' }]; });
connection.onPrepareRename(() => { bump('prepareRename'); return { range: alphaRange, placeholder: 'alpha' }; });
connection.onRenameRequest(({ textDocument, newName }) => { bump('rename'); return { changes: { [textDocument.uri]: [{ range: alphaRange, newText: newName }] } }; });
connection.onFoldingRanges(() => { bump('folding'); return [{ startLine: 0, endLine: 2, kind: 'region' }]; });
connection.onSelectionRanges(({ positions }) => { bump('selectionRange'); return positions.map(p => ({ range: range(p.line, 0, 5), parent: { range: { start: pos(0, 0), end: pos(2, 1) } } })); });
connection.languages.semanticTokens.on(() => { bump('semanticFull'); return { resultId: 'mock-1', data: [0, 0, 5, 1, 1] }; });
connection.languages.semanticTokens.onDelta(() => { bump('semanticDelta'); return { resultId: 'mock-2', edits: [{ start: 2, deleteCount: 1, data: [4] }] }; });
connection.languages.semanticTokens.onRange(() => { bump('semanticRange'); return { data: [0, 0, 5, 1, 1] }; });
connection.languages.inlayHint.on(() => { bump('inlayHints'); return [{ position: pos(0, 6), label: 'value:', kind: InlayHintKind.Parameter, paddingRight: true, data: { resolve: true } }]; });
connection.languages.inlayHint.resolve(hint => { bump('resolveInlayHint'); return { ...hint, tooltip: 'Mock resolved hint' }; });
connection.onRequest('fixture/status', () => ({ counts, initial, lastChange, lastSaveText, watched, folders, configuration }));
connection.onRequest('fixture/applyEdit', async () => {
  bump('applyEdit');
  if (!lastUri) return false;
  const result = await connection.workspace.applyEdit({ changes: { [lastUri]: [{ range: range(0, 0, 0), newText: '// nested edit\n' }] } });
  return result.applied;
});
connection.onRequest('fixture/progress', async () => {
  const progress = await connection.window.createWorkDoneProgress();
  progress.begin('Mock language server', 0, 'Starting', true);
  progress.report(50, 'Halfway'); progress.done();
  return true;
});
documents.listen(connection);
connection.listen();

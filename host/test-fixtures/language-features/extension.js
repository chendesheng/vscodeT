const vscode = require('vscode');

function activate(context) {
  context.subscriptions.push(vscode.languages.registerInlineCompletionItemProvider({ language: 'json' }, {
    provideInlineCompletionItems(document, position) {
      const line = document.lineAt(position.line).text;
      return [new vscode.InlineCompletionItem(line + ' inline result', new vscode.Range(position.line, 0, position.line, position.character))];
    }
  }));
  // A more specific provider may decline, as Emmet does outside abbreviations.
  context.subscriptions.push(vscode.languages.registerInlineCompletionItemProvider({ scheme: 'file', language: 'json' }, {
    provideInlineCompletionItems() { return []; }
  }));
  context.subscriptions.push(vscode.languages.registerCodeLensProvider({ language: 'json' }, {
    provideCodeLenses(document) {
      return [new vscode.CodeLens(new vscode.Range(0, 0, 0, 0), {
        title: document.uri.query + ':' + document.lineAt(0).text,
        command: 'fixture.codeLens',
        arguments: [document.uri.toString()]
      }), new vscode.CodeLens(new vscode.Range(0, 1, 0, 1))];
    },
    resolveCodeLens(lens) {
      lens.command = { title: 'resolved lens', command: 'fixture.codeLens' };
      return lens;
    }
  }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.codeLens', () => {}));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.executeCodeLens', async (uri, count) => {
    const items = await vscode.commands.executeCommand('vscode.executeCodeLensProvider', vscode.Uri.parse(uri), count);
    return items.map(item => ({ title: item.command?.title, start: item.range.start.character }));
  }));
  const highlightQueries = [];
  const highlight = (kind) => new vscode.DocumentHighlight(new vscode.Range(0, 2, 0, 6), kind);
  context.subscriptions.push(vscode.languages.registerDocumentHighlightProvider({ language: 'json' }, {
    async provideDocumentHighlights(document, position, token) {
      highlightQueries.push({ type: 'single', uri: document.uri.toString(), text: document.lineAt(0).text, position: position.character });
      return token.isCancellationRequested ? undefined : [highlight(vscode.DocumentHighlightKind.Read)];
    }
  }));
  context.subscriptions.push(vscode.languages.registerMultiDocumentHighlightProvider({ language: 'json' }, {
    async provideMultiDocumentHighlights(document, position, others, token) {
      highlightQueries.push({ type: 'multi', uri: document.uri.toString(), text: document.lineAt(0).text, position: position.character, others: others.map(other => ({ uri: other.uri.toString(), text: other.lineAt(0).text })) });
      if (token.isCancellationRequested) return undefined;
      return [new vscode.MultiDocumentHighlight(document.uri, [highlight(vscode.DocumentHighlightKind.Read)]), ...others.map(other => new vscode.MultiDocumentHighlight(other.uri, [highlight(vscode.DocumentHighlightKind.Write)]))];
    }
  }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.highlightQueries', () => highlightQueries));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.executeDocumentHighlights', async (uri) => {
    const items = await vscode.commands.executeCommand('vscode.executeDocumentHighlights', vscode.Uri.parse(uri), new vscode.Position(0, 3));
    return items?.map(item => ({ start: item.range.start.character, end: item.range.end.character, kind: item.kind }));
  }));
  const tabEvents = [];
  context.subscriptions.push(vscode.window.tabGroups.onDidChangeTabs(event => {
    tabEvents.push({ opened: event.opened.map(tab => tab.label), closed: event.closed.map(tab => tab.label), changed: event.changed.map(tab => tab.label) });
  }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.tabState', () => ({
    tabEvents,
    activeDocument: vscode.window.activeTextEditor?.document.uri.toString(),
    documents: vscode.workspace.textDocuments.map(document => ({ uri: document.uri.toString(), firstLine: document.lineAt(0).text })),
    groups: vscode.window.tabGroups.all.map(group => ({
      column: group.viewColumn,
      active: group.isActive,
      tabs: group.tabs.map(tab => ({
        active: tab.isActive,
        pinned: tab.isPinned,
        preview: tab.isPreview,
        dirty: tab.isDirty,
        label: tab.label,
        diffs: (tab.input?.textDiffs ?? (tab.input?.original && tab.input?.modified ? [tab.input] : [])).map(diff => ({ original: diff.original.toString(), modified: diff.modified.toString() }))
      }))
    }))
  })));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.closeNamedTab', async label => {
    const tab = vscode.window.tabGroups.all.flatMap(group => group.tabs).find(tab => tab.label === label);
    return tab ? vscode.window.tabGroups.close(tab, true) : false;
  }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.closeComparison', async () => {
    const tab = vscode.window.tabGroups.all.flatMap(group => group.tabs).find(tab => Array.isArray(tab.input?.textDiffs));
    return tab ? vscode.window.tabGroups.close(tab, true) : false;
  }));
  const hoverEvents = [];
  const delayedHovers = new Map();
  context.subscriptions.push(vscode.languages.registerHoverProvider({ language: 'json' }, {
    provideHover(document, position, token, hoverContext) {
      const name = document.uri.query;
      const delayed = name === 'HoverOriginal' || name === 'HoverModified';
      if (!delayed && hoverContext) {
        return { contents: [`fixture hover verbosity ${hoverContext.verbosityDelta}: ${hoverContext.previousHover.contents[0]}`], canIncreaseVerbosity: true, canDecreaseVerbosity: true };
      }
      if (!delayed) return { contents: ['fixture hover'], canIncreaseVerbosity: true };
      const prefix = hoverContext ? 'verbosity-' : '';
      hoverEvents.push({ name, kind: `${prefix}start`, text: document.lineAt(position.line).text, delta: hoverContext?.verbosityDelta });
      return new Promise(resolve => {
        let subscription;
        const finish = (kind, value) => {
          if (delayedHovers.get(name) !== release) return;
          delayedHovers.delete(name);
          subscription?.dispose();
          hoverEvents.push({ name, kind: `${prefix}${kind}` });
          resolve(value);
        };
        const release = () => finish('complete', { contents: [hoverContext ? `${hoverContext.previousHover.contents[0]} verbosity ${hoverContext.verbosityDelta}` : `semantic ${name}`], range: new vscode.Range(0, 2, 0, 6), canIncreaseVerbosity: true, canDecreaseVerbosity: !!hoverContext });
        delayedHovers.set(name, release);
        subscription = token.onCancellationRequested(() => finish('cancel', undefined));
        if (token.isCancellationRequested) finish('cancel', undefined);
      });
    }
  }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.hoverState', () => hoverEvents));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.executeHovers', async (uri, recursive) => {
    const command = recursive ? 'vscode.experimental.executeHoverProvider_recursive' : 'vscode.executeHoverProvider';
    const items = await vscode.commands.executeCommand(command, vscode.Uri.parse(uri), new vscode.Position(0, 3));
    return items?.map(item => ({ contents: item.contents.map(content => content.value), start: item.range.start.character, end: item.range.end.character }));
  }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.releaseHover', name => {
    const finish = delayedHovers.get(name);
    if (!finish) return false;
    finish();
    return true;
  }));
  context.subscriptions.push(vscode.languages.registerCompletionItemProvider({ language: 'json' }, {
    provideCompletionItems() {
      const item = new vscode.CompletionItem('fixture', vscode.CompletionItemKind.Text);
      item.insertText = 'fixture';
      return [item];
    }
  }, '.'));
  context.subscriptions.push(vscode.languages.registerDefinitionProvider({ language: 'json' }, {
    provideDefinition(document) {
      const range = new vscode.Range(0, 0, 0, 1);
      return [{ targetUri: document.uri, targetRange: range, targetSelectionRange: range }];
    }
  }));
  context.subscriptions.push(vscode.languages.registerDeclarationProvider({ language: 'json' }, {
    provideDeclaration(document) {
      const range = new vscode.Range(1, 0, 1, 1);
      return [{ targetUri: document.uri, targetRange: range, targetSelectionRange: range }];
    }
  }));
  context.subscriptions.push(vscode.languages.registerImplementationProvider({ language: 'json' }, {
    provideImplementation(document) {
      const range = new vscode.Range(2, 0, 2, 1);
      return [{ targetUri: document.uri, targetRange: range, targetSelectionRange: range }];
    }
  }));
  context.subscriptions.push(vscode.languages.registerTypeDefinitionProvider({ language: 'json' }, {
    provideTypeDefinition(document) {
      const range = new vscode.Range(0, 0, 0, 3);
      return [{ targetUri: document.uri, targetRange: range, targetSelectionRange: range }];
    }
  }));
  context.subscriptions.push(vscode.languages.registerReferenceProvider({ language: 'json' }, {
    provideReferences(document) {
      return [
        new vscode.Location(document.uri, new vscode.Range(0, 0, 0, 1)),
        new vscode.Location(document.uri, new vscode.Range(1, 0, 1, 1)),
      ];
    }
  }));
  context.subscriptions.push(vscode.languages.registerDocumentSymbolProvider({ language: 'json' }, {
    provideDocumentSymbols() {
      return [new vscode.DocumentSymbol(
        'root',
        '',
        vscode.SymbolKind.Object,
        new vscode.Range(0, 0, 1, 0),
        new vscode.Range(0, 0, 0, 1)
      )];
    }
  }));
}

function deactivate() {}

module.exports = { activate, deactivate };

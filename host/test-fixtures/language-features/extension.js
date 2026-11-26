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
  context.subscriptions.push(vscode.languages.registerHoverProvider({ language: 'json' }, {
    provideHover() {
      return { contents: ['fixture hover'] };
    }
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

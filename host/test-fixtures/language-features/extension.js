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
  const codeActionTargets = new WeakMap();
  const codeActionQueries = [];
  context.subscriptions.push(vscode.languages.registerCodeActionsProvider({ language: 'json' }, {
    async provideCodeActions(document, range, context, token) {
      if (token.isCancellationRequested) return [];
      codeActionQueries.push({ uri: document.uri.toString(), selection: range instanceof vscode.Selection, anchor: range.anchor?.character, active: range.active?.character });
      const quickfix = new vscode.CodeAction('Fixture quick fix', vscode.CodeActionKind.QuickFix);
      quickfix.isPreferred = true;
      codeActionTargets.set(quickfix, document.uri);
      const refactor = new vscode.CodeAction('Fixture refactor', vscode.CodeActionKind.Refactor);
      refactor.disabled = { reason: 'Not available here' };
      const source = new vscode.CodeAction('Fixture source action', vscode.CodeActionKind.Source);
      return [quickfix, refactor, source].filter(action => !context.only || context.only.contains(action.kind));
    },
    async resolveCodeAction(action, token) {
      if (token.isCancellationRequested) return undefined;
      // A command argument survives only while the provider list is cached.
      action.command = { title: 'Fixture code action command', command: 'fixture.codeActionCommand', arguments: [action.title] };
      const uri = codeActionTargets.get(action);
      if (uri) {
        action.edit = new vscode.WorkspaceEdit();
        action.edit.insert(uri, new vscode.Position(0, 0), ' ');
      }
      return action;
    }
  }, { providedCodeActionKinds: [vscode.CodeActionKind.QuickFix, vscode.CodeActionKind.Refactor, vscode.CodeActionKind.Source] }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.codeActionCommand', title => title));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.executeCodeActions', async (uri, kind, count) => {
    const resource = vscode.Uri.parse(uri);
    const selection = new vscode.Selection(0, 6, 0, 2);
    const items = await vscode.commands.executeCommand('vscode.executeCodeActionProvider', resource, selection, kind, count);
    return { items: items.map(item => ({ title: item.title, kind: item.kind?.value, preferred: item.isPreferred, edits: item.edit?.entries().map(([target, edits]) => ({ uri: target.toString(), text: edits[0].newText })) })), query: codeActionQueries.at(-1) };
  }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.applyWorkspaceEdit', async uri => {
    const edit = new vscode.WorkspaceEdit();
    edit.insert(vscode.Uri.parse(uri), new vscode.Position(0, 0), ' ');
    return vscode.workspace.applyEdit(edit);
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
  let participateInSave = false;
  context.subscriptions.push(vscode.commands.registerCommand('fixture.enableSaveParticipant', () => {
    participateInSave = true;
    return true;
  }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.saveDocument', uri => {
    const resource = vscode.Uri.parse(uri).toString();
    const document = vscode.workspace.textDocuments.find(value => value.uri.toString() === resource);
    return document ? document.save() : false;
  }));
  context.subscriptions.push(vscode.workspace.onWillSaveTextDocument(event => {
    if (!participateInSave) return;
    event.waitUntil(Promise.resolve([vscode.TextEdit.insert(new vscode.Position(0, 0), ' ')]));
  }));
  context.subscriptions.push(vscode.languages.registerCompletionItemProvider({ language: 'json' }, {
    provideCompletionItems() {
      const item = new vscode.CompletionItem('fixture', vscode.CompletionItemKind.Text);
      item.insertText = 'fixture';
      return [item];
    }
  }, '.'));
  context.subscriptions.push(vscode.languages.registerOnTypeFormattingEditProvider({ language: 'json' }, {
    async provideOnTypeFormattingEdits(document, position, ch) {
      await new Promise(resolve => setTimeout(resolve, 30));
      if (ch !== ';' || position.character === 0) return [];
      return [vscode.TextEdit.replace(new vscode.Range(position.line, position.character - 1, position.line, position.character), '!')];
    }
  }, ';'));
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
  const inlayChanges = new vscode.EventEmitter();
  context.subscriptions.push(inlayChanges,
    vscode.commands.registerCommand('fixture.changeInlayHints', () => inlayChanges.fire()),
    vscode.languages.registerInlayHintsProvider({ language: 'json' }, {
      onDidChangeInlayHints: inlayChanges.event,
      provideInlayHints(document) {
        const part = new vscode.InlayHintLabelPart('fixtureHint');
        part.tooltip = 'Part tooltip';
        part.location = new vscode.Location(document.uri, new vscode.Range(1, 0, 1, 1));
        part.command = { title: 'Fixture Command', command: 'fixture.changeInlayHints' };
        const hint = new vscode.InlayHint(new vscode.Position(1, 2), [part], vscode.InlayHintKind.Type);
        hint.paddingLeft = true;
        hint.paddingRight = true;
        return [hint];
      },
      resolveInlayHint(hint) {
        hint.tooltip = 'Resolved inlay tooltip';
        hint.textEdits = [vscode.TextEdit.insert(hint.position, 'resolved')];
        return hint;
      }
    }));
  const semanticLegend = new vscode.SemanticTokensLegend(['variable'], ['declaration']);
  const semanticChanges = new vscode.EventEmitter();
  context.subscriptions.push(semanticChanges,
    vscode.commands.registerCommand('fixture.changeSemanticTokens', () => semanticChanges.fire()),
    vscode.languages.registerDocumentSemanticTokensProvider({ language: 'json' }, {
      onDidChangeSemanticTokens: semanticChanges.event,
      provideDocumentSemanticTokens() {
        return new vscode.SemanticTokens(new Uint32Array([1, 0, 1, 0, 1]), 'first');
      },
      provideDocumentSemanticTokensEdits(document, lastResultId) {
        if (lastResultId !== 'first') return new vscode.SemanticTokens(new Uint32Array([1, 0, 2, 0, 1]), 'second');
        return new vscode.SemanticTokensEdits([new vscode.SemanticTokensEdit(2, 1, new Uint32Array([2]))], 'second');
      }
    }, semanticLegend),
    vscode.languages.registerDocumentRangeSemanticTokensProvider({ language: 'json' }, {
      provideDocumentRangeSemanticTokens() { return new vscode.SemanticTokens(new Uint32Array([1, 0, 1, 0, 0])); }
    }, semanticLegend),
    vscode.languages.registerDocumentRangeSemanticTokensProvider({ language: 'plaintext' }, {
      provideDocumentRangeSemanticTokens() { return new vscode.SemanticTokens(new Uint32Array([1, 2, 1, 0, 1])); }
    }, semanticLegend));
  context.subscriptions.push(vscode.languages.registerRenameProvider({ language: 'json' }, {
    prepareRename(document, position) {
      if (position.line === 0) throw new Error('Not a renamable location');
      return { range: new vscode.Range(1, 0, 1, 1), placeholder: 'fixture' };
    },
    provideRenameEdits(document, position, newName) {
      if (newName === 'reject') throw new Error('Rejected name');
      const edit = new vscode.WorkspaceEdit();
      edit.replace(document.uri, new vscode.Range(1, 0, 1, 1), newName);
      return edit;
    }
  }));
  context.subscriptions.push(vscode.languages.registerSignatureHelpProvider({ language: 'json' }, {
    async provideSignatureHelp(document, position, token, trigger) {
      await new Promise(resolve => setTimeout(resolve, 20));
      if (token.isCancellationRequested) return undefined;
      const signature = new vscode.SignatureInformation('f(é, b)', 'Fixture docs');
      signature.parameters = [new vscode.ParameterInformation([2, 3], 'First parameter'), new vscode.ParameterInformation('b', 'Second parameter')];
      const other = new vscode.SignatureInformation('f(b)');
      other.parameters = [new vscode.ParameterInformation('b')];
      return { signatures: [signature, other], activeSignature: 0, activeParameter: trigger.isRetrigger ? 1 : 0 };
    }
  }, {triggerCharacters: ['('], retriggerCharacters: [',']}));
  const foldingChanges = new vscode.EventEmitter();
  let changedFolds = false;
  context.subscriptions.push(foldingChanges,
    vscode.commands.registerCommand('fixture.changeFoldingRanges', () => { changedFolds = true; foldingChanges.fire(); }),
    vscode.languages.registerFoldingRangeProvider({ language: 'json' }, {
      onDidChangeFoldingRanges: foldingChanges.event,
      provideFoldingRanges() {
        return changedFolds ? [new vscode.FoldingRange(0, 2, vscode.FoldingRangeKind.Region)] : [new vscode.FoldingRange(1, 2, vscode.FoldingRangeKind.Region)];
      }
    }));
  context.subscriptions.push(vscode.languages.registerSelectionRangeProvider({ language: 'json' }, {
    async provideSelectionRanges(document, positions, token) {
      await new Promise(resolve => setTimeout(resolve, 30));
      if (token.isCancellationRequested) return [];
      return positions.map(position => {
        const outer = new vscode.SelectionRange(new vscode.Range(0, 0, document.lineCount - 1, document.lineAt(document.lineCount - 1).text.length));
        if (position.line === 1) return new vscode.SelectionRange(new vscode.Range(1, 0, 1, document.lineAt(1).text.length), outer);
        return outer;
      });
    }
  }));
  context.subscriptions.push(vscode.languages.registerWorkspaceSymbolProvider({
    async provideWorkspaceSymbols(query, token) {
      if (query !== 'WorkspaceFixture' || token.isCancellationRequested) return [];
      const uri = vscode.window.activeTextEditor.document.uri;
      return [{ name: 'WorkspaceFixture', kind: vscode.SymbolKind.Function, containerName: 'fixture', location: { uri } }];
    },
    resolveWorkspaceSymbol(symbol) {
      symbol.location = new vscode.Location(symbol.location.uri, new vscode.Range(1, 2, 1, 5));
      return symbol;
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

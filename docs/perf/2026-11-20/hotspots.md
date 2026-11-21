> Historical: VSCodeVim was removed; Vim is now the compiled-in `vscode-textbuffer.vim` extension. See `docs/vim.md`.


### ReleaseFast startup (active 121/1548 = 7.8%)
| inclusive % | self % | symbol |
|---:|---:|---|
| 54.5% | 0.0% | `vs.editor.common.model.textModelTokens.TokenizerWithStateStoreAndTextModel.updateTokensUntilLine` |
| 54.5% | 0.0% | `vs.editor.common.model.textModelTokens.safeTokenize` |
| 54.5% | 0.0% | `vs.editor.common.model.tokens.textMateTokenizer.TextMateSupport.tokenizeEncoded` |
| 51.2% | 0.0% | `grammar.tokenizeString.tokenizeString` |
| 46.3% | 11.6% | `onigLib.OnigScanner.findNextMatchSync` |
| 37.2% | 0.0% | `vs.workbench.browser.workbench.Workbench.render` |
| 33.1% | 0.0% | `surface.Surface.paintFrame` |
| 33.1% | 29.8% | `surface.Surface.ensureLayout` |
| 24.0% | 0.0% | `onig_search` |
layout split: {'editor view': 21, 'statusbar': 19}
  tui.editorView.View.rebuild: incl 5.0% self 1.7%
  vs.workbench.browser.workbench.Workbench.render: incl 37.2% self 0.0%
  surface.Surface.ensureLayout: incl 33.1% self 29.8%
  vs.editor.common.model.tokens.textMateTokenizer.TextMateSupport.tokenizeEncoded: incl 54.5% self 0.0%
  vs.workbench.browser.workbench.Workbench.pollFileWatcher: incl 0.0% self 0.0%

### ReleaseFast burst native (active 1849/5816 = 31.8%)
| inclusive % | self % | symbol |
|---:|---:|---|
| 91.6% | 0.1% | `vs.workbench.browser.workbench.Workbench.render` |
| 87.1% | 0.0% | `surface.Surface.paintFrame` |
| 85.7% | 74.4% | `surface.Surface.ensureLayout` |
| 49.9% | 0.0% | `vs.workbench.browser.workbench.Workbench.renderPane` |
| 20.1% | 0.3% | `layout.layoutElement` |
| 14.9% | 0.3% | `layout.layoutBlockChildren` |
| 14.4% | 0.1% | `layout.layoutOutOfFlow` |
| 11.3% | 3.7% | `text_layout.layoutRun` |
| 5.9% | 0.2% | `paint.paintBox` |
layout split: {'editor view': 883, 'statusbar': 701}
  tui.editorView.View.rebuild: incl 5.1% self 2.0%
  vs.workbench.api.browser.extensionHostAdapter.Extensions.pump: incl 0.5% self 0.0%
  vs.workbench.browser.workbench.Workbench.render: incl 91.6% self 0.1%
  surface.Surface.ensureLayout: incl 85.7% self 74.4%
  vs.editor.common.model.tokens.textMateTokenizer.TextMateSupport.tokenizeEncoded: incl 0.3% self 0.1%
  vs.workbench.browser.workbench.Workbench.pollFileWatcher: incl 2.9% self 0.0%

### ReleaseFast burst VSCodeVim (active 1198/5876 = 20.4%)
| inclusive % | self % | symbol |
|---:|---:|---|
| 84.2% | 0.7% | `vs.workbench.browser.workbench.Workbench.render` |
| 76.8% | 0.1% | `surface.Surface.paintFrame` |
| 75.0% | 60.6% | `surface.Surface.ensureLayout` |
| 44.6% | 0.1% | `vs.workbench.browser.workbench.Workbench.renderPane` |
| 24.2% | 0.7% | `layout.layoutElement` |
| 17.4% | 0.5% | `layout.layoutOutOfFlow` |
| 17.0% | 0.2% | `layout.layoutBlockChildren` |
| 11.9% | 4.2% | `text_layout.layoutRun` |
| 10.9% | 3.7% | `tui.editorView.View.rebuild` |
layout split: {'editor view': 500, 'statusbar': 399}
  tui.editorView.View.rebuild: incl 10.9% self 3.7%
  vs.workbench.api.browser.extensionHostAdapter.Extensions.pump: incl 1.2% self 0.0%
  vs.workbench.browser.workbench.Workbench.render: incl 84.2% self 0.7%
  surface.Surface.ensureLayout: incl 75.0% self 60.6%
  vs.editor.common.model.tokens.textMateTokenizer.TextMateSupport.tokenizeEncoded: incl 1.3% self 0.2%
  vs.workbench.browser.workbench.Workbench.pollFileWatcher: incl 2.3% self 0.0%

### Debug startup (active 6210/6422 = 96.7%)
| inclusive % | self % | symbol |
|---:|---:|---|
| 70.6% | 0.0% | `heap.SafeAllocator.captureStackTrace` |
| 70.6% | 0.3% | `debug.captureCurrentStackTrace` |
| 69.9% | 0.2% | `debug.StackIterator.next` |
| 69.5% | 0.1% | `debug.SelfInfo.MachO.unwindFrame` |
| 69.3% | 3.4% | `debug.SelfInfo.MachO.unwindFrameInner` |
| 52.7% | 1.3% | `debug.Dwarf.SelfUnwinder.computeRules` |
| 46.6% | 0.0% | `tui.editorView.View.refresh` |
| 46.6% | 0.0% | `tui.editorView.View.rebuild` |
layout split: {'editor view': 1272, 'statusbar': 963}
  heap.SafeAllocator.captureStackTrace: incl 70.6% self 0.0%
  tui.editorView.View.refresh: incl 46.6% self 0.0%
  tui.editorView.View.rebuild: incl 46.6% self 0.0%
  vs.workbench.api.browser.extensionHostAdapter.Extensions.pump: incl 0.2% self 0.0%
  vs.workbench.browser.workbench.Workbench.render: incl 37.8% self 0.0%
  surface.Surface.ensureLayout: incl 36.0% self 0.0%
  vs.editor.common.model.tokens.textMateTokenizer.TextMateSupport.tokenizeEncoded: incl 1.7% self 0.0%
  vs.workbench.browser.workbench.Workbench.pollFileWatcher: incl 0.4% self 0.0%

### Debug burst native (active 5652/5656 = 99.9%)
| inclusive % | self % | symbol |
|---:|---:|---|
| 94.1% | 0.0% | `heap.SafeAllocator.captureStackTrace` |
| 94.0% | 0.7% | `debug.captureCurrentStackTrace` |
| 92.8% | 0.2% | `debug.StackIterator.next` |
| 92.3% | 0.1% | `debug.SelfInfo.MachO.unwindFrame` |
| 92.1% | 5.0% | `debug.SelfInfo.MachO.unwindFrameInner` |
| 65.7% | 1.6% | `debug.Dwarf.SelfUnwinder.computeRules` |
| 64.1% | 0.0% | `vs.workbench.api.browser.extensionHostAdapter.Extensions.pump` |
| 62.5% | 0.0% | `vs.workbench.services.extensions.common.extensionHostManager.HostManager.pump` |
layout split: {'editor view': 51, 'statusbar': 43}
  heap.SafeAllocator.captureStackTrace: incl 94.1% self 0.0%
  tui.editorView.View.refresh: incl 51.3% self 0.0%
  tui.editorView.View.rebuild: incl 51.3% self 0.0%
  vs.workbench.api.browser.extensionHostAdapter.Extensions.pump: incl 64.1% self 0.0%
  vs.workbench.browser.workbench.Workbench.render: incl 1.8% self 0.0%
  surface.Surface.ensureLayout: incl 1.7% self 0.0%
  vs.editor.common.model.tokens.textMateTokenizer.TextMateSupport.tokenizeEncoded: incl 0.1% self 0.0%
  vs.workbench.browser.workbench.Workbench.pollFileWatcher: incl 0.0% self 0.0%

### Debug burst VSCodeVim (active 5435/5767 = 94.2%)
| inclusive % | self % | symbol |
|---:|---:|---|
| 81.5% | 0.1% | `heap.SafeAllocator.captureStackTrace` |
| 81.4% | 0.4% | `debug.captureCurrentStackTrace` |
| 80.4% | 0.2% | `debug.StackIterator.next` |
| 79.9% | 0.1% | `debug.SelfInfo.MachO.unwindFrame` |
| 79.9% | 4.4% | `debug.SelfInfo.MachO.unwindFrameInner` |
| 60.5% | 1.1% | `debug.Dwarf.SelfUnwinder.computeRules` |
| 50.8% | 0.0% | `tui.editorView.View.refresh` |
| 50.8% | 0.0% | `tui.editorView.View.rebuild` |
layout split: {'editor view': 602, 'statusbar': 581}
  heap.SafeAllocator.captureStackTrace: incl 81.5% self 0.1%
  tui.editorView.View.refresh: incl 50.8% self 0.0%
  tui.editorView.View.rebuild: incl 50.8% self 0.0%
  vs.workbench.api.browser.extensionHostAdapter.Extensions.pump: incl 12.7% self 0.0%
  vs.workbench.browser.workbench.Workbench.render: incl 23.7% self 0.0%
  surface.Surface.ensureLayout: incl 21.8% self 0.0%
  vs.editor.common.model.tokens.textMateTokenizer.TextMateSupport.tokenizeEncoded: incl 0.1% self 0.0%
  vs.workbench.browser.workbench.Workbench.pollFileWatcher: incl 0.2% self 0.0%

### ReleaseFast idle (active 2/3847 = 0.1%)
| inclusive % | self % | symbol |
|---:|---:|---|
| 0.0% | 0.0% | `vs.workbench.browser.workbench.Workbench.pollFileWatcher` |
| 0.0% | 0.0% | `vs.platform.files.node.watcher.watcher.UniversalWatcher.poll` |
| 0.0% | 0.0% | `vs.platform.files.node.watcher.parcel.watcherLib.root.Lib.poll` |
| 0.0% | 0.0% | `vs.platform.files.node.watcher.parcel.watcherLib.root.kqueue_vtable__struct_8439.call` |
layout split: {}
  vs.workbench.browser.workbench.Workbench.pollFileWatcher: incl 0.0% self 0.0%

### Debug idle (active 34/3815 = 0.9%)
| inclusive % | self % | symbol |
|---:|---:|---|
| 82.4% | 0.0% | `heap.SafeAllocator.captureStackTrace` |
| 82.4% | 0.0% | `debug.captureCurrentStackTrace` |
| 82.4% | 0.0% | `debug.StackIterator.next` |
| 82.4% | 0.0% | `debug.SelfInfo.MachO.unwindFrame` |
| 82.4% | 5.9% | `debug.SelfInfo.MachO.unwindFrameInner` |
| 64.7% | 2.9% | `debug.Dwarf.SelfUnwinder.computeRules` |
| 61.8% | 0.0% | `vs.workbench.api.browser.extensionHostAdapter.Extensions.pump` |
| 52.9% | 0.0% | `debug.Dwarf.Unwind.VirtualMachine.runTo` |
layout split: {}
  heap.SafeAllocator.captureStackTrace: incl 82.4% self 0.0%
  vs.workbench.api.browser.extensionHostAdapter.Extensions.pump: incl 61.8% self 0.0%
  vs.workbench.browser.workbench.Workbench.pollFileWatcher: incl 35.3% self 0.0%

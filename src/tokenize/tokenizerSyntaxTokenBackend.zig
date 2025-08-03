const std = @import("std");
const Emitter = std.event.Emitter;
const Event = std.event.Event;
const MutableDisposable = std.lifecycle.MutableDisposable;
const DisposableMap = std.lifecycle.DisposableMap;
const countEOL = @import("../basics/eolCounter.zig").countEOL;
const Position = @import("../basics/position.zig").Position;
const LineRange = @import("../basics/lineRange.zig").LineRange;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const IBackgroundTokenizer = @import("../languages.zig").IBackgroundTokenizer;
const IState = @import("../languages.zig").IState;
const ITokenizationSupport = @import("../languages.zig").ITokenizationSupport;
const IBackgroundTokenizationStore = @import("../languages.zig").IBackgroundTokenizationStore;
const ContiguousMultilineTokens = @import("../tokens/contiguousMultilineTokens.zig").ContiguousMultilineTokens;
const ContiguousMultilineTokensBuilder = @import("../tokens/contiguousMultilineTokensBuilder.zig").ContiguousMultilineTokensBuilder;
const ContiguousTokensStore = @import("../tokens/contiguousTokensStore.zig").ContiguousTokensStore;
const LineTokens = @import("../tokens/lineTokens.zig").LineTokens;
const TextModel = @import("../textModel.zig").TextModel;
const TokenizerWithStateStoreAndTextModel = @import("../textModelTokens.zig").TokenizerWithStateStoreAndTextModel;
const TrackingTokenizationStateStore = @import("../textModelTokens.zig").TrackingTokenizationStateStore;
const AbstractSyntaxTokenBackend = @import("./abstractSyntaxTokenBackend.zig").AbstractSyntaxTokenBackend;
const AttachedViewHandler = @import("./abstractSyntaxTokenBackend.zig").AttachedViewHandler;
const AttachedViews = @import("./abstractSyntaxTokenBackend.zig").AttachedViews;
const BackgroundTokenizationState = @import("./abstractSyntaxTokenBackend.zig").BackgroundTokenizationState;
const TokenizationRegistry = @import("./tokenizationRegistry.zig").TokenizationRegistry;

// For TextMate
pub const TokenizerSyntaxTokenBackend = struct {
	_tokenizer: ?TokenizerWithStateStoreAndTextModel = null,
	_backgroundTokenizationState: BackgroundTokenizationState,
	_onDidChangeBackgroundTokenizationState: Emitter(void),

	_defaultBackgroundTokenizer: ?DefaultBackgroundTokenizer = null,
	_backgroundTokenizer: MutableDisposable(IBackgroundTokenizer),

	_tokens: ContiguousTokensStore,
	_debugBackgroundTokens: ?ContiguousTokensStore = null,
	_debugBackgroundStates: ?TrackingTokenizationStateStore(IState) = null,

	_debugBackgroundTokenizer: MutableDisposable(IBackgroundTokenizer),

	_attachedViewStates: DisposableMap(AttachedView, AttachedViewHandler),

    _languageIdCodec: LanguageIdCodec,
    _textModel: TextModel,

	pub fn init(
		languageIdCodec: LanguageIdCodec,
		textModel: TextModel,
		getLanguageId: fn () []const u8,
		attachedViews: AttachedViews,
	) TokenizerSyntaxTokenBackend {
		TokenizationRegistry.onDidChange((e) => {
			const languageId = self.getLanguageId();
			if (!std.mem.indexOf(u8, e.changedLanguages, languageId)) {
				return;
			}
			todo_resetTokenization();
		})

		self.todo_resetTokenization();

		attachedViews._onDidChangeVisibleRanges.event({}, struct {
			fn cb({ view, state }, _:void) void {
				if (state) {
					let existing = self._attachedViewStates.get(view);
					if (!existing) {
						existing = AttachedViewHandler(() => self.refreshRanges(existing!.lineRanges));
						self._attachedViewStates.set(view, existing);
					}
					existing.handleStateChange(state);
				} else {
					self._attachedViewStates.deleteAndDispose(view);
				}
			}.cb,
		});
		return TokenizerSyntaxTokenBackend{
			._languageIdCodec = languageIdCodec,
			._textModel = textModel,
			._tokens = ContiguousTokensStore.init(textModel.getAllocator(), languageIdCodec),
			._onDidChangeBackgroundTokenizationState = Emitter(void).init(),
			._backgroundTokenizer = MutableDisposable(IBackgroundTokenizer).init(),
			._backgroundTokenizationState = BackgroundTokenizationState.InProgress,
		}
	}

	pub fn todo_resetTokenization(self: *TokenizerSyntaxTokenBackend, fireTokenChangeEvent: bool) void {
		self._tokens.flush();
		self._debugBackgroundTokens?.flush();
		if (self._debugBackgroundStates) {
			self._debugBackgroundStates = TrackingTokenizationStateStore(IState).init(self._textModel.getLineCount());
		}
		if (fireTokenChangeEvent) {
			self._onDidChangeTokens.fire({
				semanticTokensApplied: false,
				ranges: [
					{
						fromLineNumber: 1,
						toLineNumber: self._textModel.getLineCount(),
					},
				],
			});
		}

		const initializeTokenization = (): [ITokenizationSupport, IState] | [null, null] => {
			if (self._textModel.isTooLargeForTokenization()) {
				return [null, null];
			}
			const tokenizationSupport = TokenizationRegistry.get(self.getLanguageId());
			if (!tokenizationSupport) {
				return [null, null];
			}
			let initialState: IState;
			try {
				initialState = tokenizationSupport.getInitialState();
			} catch (e) {
				onUnexpectedError(e);
				return [null, null];
			}
			return [tokenizationSupport, initialState];
		};

		const [tokenizationSupport, initialState] = initializeTokenization();
		if (tokenizationSupport != null and initialState != null) {
			self._tokenizer = TokenizerWithStateStoreAndTextModel.init(self._textModel.getLineCount(), tokenizationSupport, self._textModel, self._languageIdCodec);
		} else {
			self._tokenizer = null;
		}

		self._backgroundTokenizer.clear();

		self._defaultBackgroundTokenizer = null;
		if (self._tokenizer) {
			const b: IBackgroundTokenizationStore = {
				setTokens: (tokens) => {
					self.setTokens(tokens);
				},
				backgroundTokenizationFinished: () => {
					if (self._backgroundTokenizationState == BackgroundTokenizationState.Completed) {
						// We already did a full tokenization and don't go back to progressing.
						return;
					}
					const newState = BackgroundTokenizationState.Completed;
					self._backgroundTokenizationState = newState;
					self._onDidChangeBackgroundTokenizationState.fire();
				},
				setEndState: (lineNumber, state) => {
					if (!self._tokenizer) { return; }
					const firstInvalidEndStateLineNumber = self._tokenizer.store.getFirstInvalidEndStateLineNumber();
					// Don't accept states for definitely valid states, the renderer is ahead of the worker!
					if (firstInvalidEndStateLineNumber != null and lineNumber >= firstInvalidEndStateLineNumber) {
						self._tokenizer?.store.setEndState(lineNumber, state);
					}
				},
			};

			if (tokenizationSupport != null and tokenizationSupport.createBackgroundTokenizer and !tokenizationSupport.backgroundTokenizerShouldOnlyVerifyTokens) {
				self._backgroundTokenizer.value = tokenizationSupport.createBackgroundTokenizer(self._textModel, b);
			}
			if (!self._backgroundTokenizer.value and !self._textModel.isTooLargeForTokenization()) {
				self._backgroundTokenizer.value = self._defaultBackgroundTokenizer =
					DefaultBackgroundTokenizer.init(self._tokenizer, b);
				self._defaultBackgroundTokenizer.handleChanges();
			}

			if (tokenizationSupport != null and tokenizationSupport.backgroundTokenizerShouldOnlyVerifyTokens and tokenizationSupport.createBackgroundTokenizer) {
				self._debugBackgroundTokens = ContiguousTokensStore.init(self._languageIdCodec);
				self._debugBackgroundStates = TrackingTokenizationStateStore(IState).init(self._textModel.getLineCount());
				self._debugBackgroundTokenizer.clear();
				self._debugBackgroundTokenizer.value = tokenizationSupport.createBackgroundTokenizer(self._textModel, {
					setTokens: (tokens) => {
						self._debugBackgroundTokens?.setMultilineTokens(tokens, self._textModel);
					},
					backgroundTokenizationFinished() {
						// NO OP
					},
					setEndState: (lineNumber, state) => {
						self._debugBackgroundStates?.setEndState(lineNumber, state);
					},
				});
			} else {
				self._debugBackgroundTokens = null;
				self._debugBackgroundStates = null;
				self._debugBackgroundTokenizer.value = null;
			}
		}

		self.refreshAllVisibleLineTokens();
	}

	pub fn handleDidChangeAttached(self: *TokenizerSyntaxTokenBackend) void {
		self._defaultBackgroundTokenizer?.handleChanges();
	}

	pub fn handleDidChangeContent(self: *TokenizerSyntaxTokenBackend, e: IModelContentChangedEvent) void {
		if (e.isFlush) {
			// Don't fire the event, as the view might not have got the text change event yet
			self.todo_resetTokenization(false);
		} else if (!e.isEolChange) { // We don't have to do anything on an EOL change
			for (e.changes) |c| {
				const [eolCount, firstLineLength] = countEOL(c.text);

				self._tokens.acceptEdit(c.range, eolCount, firstLineLength);
				self._debugBackgroundTokens?.acceptEdit(c.range, eolCount, firstLineLength);
			}
			self._debugBackgroundStates?.acceptChanges(e.changes);

			if (self._tokenizer) {
				self._tokenizer.store.acceptChanges(e.changes);
			}
			self._defaultBackgroundTokenizer?.handleChanges();
		}
	}

	pub fn setTokens(self: *TokenizerSyntaxTokenBackend, tokens: ContiguousMultilineTokens[]) struct { changes: []const Range } {
		const { changes } = self._tokens.setMultilineTokens(tokens, self._textModel);

		if (changes.length > 0) {
			self._onDidChangeTokens.fire({ semanticTokensApplied: false, ranges: changes, });
		}

		return .{ .changes = changes };
	}

	pub fn refreshAllVisibleLineTokens(self: *TokenizerSyntaxTokenBackend) void {
		const ranges = LineRange.joinMany([...self._attachedViewStates].map(([_, s]) => s.lineRanges));
		self.refreshRanges(ranges);
	}

	pub fn refreshRanges(self: *TokenizerSyntaxTokenBackend, ranges: []const LineRange) void {
		for (ranges) |range| {
			self.refreshRange(range.startLineNumber, range.endLineNumberExclusive - 1);
		}
	}

	pub fn refreshRange(self: *TokenizerSyntaxTokenBackend, startLineNumber: usize, endLineNumber: usize) void {
		if (!self._tokenizer) {
			return;
		}

		startLineNumber = @max(1, @min(self._textModel.getLineCount(), startLineNumber));
		endLineNumber = @min(self._textModel.getLineCount(), endLineNumber);

		const builder = new ContiguousMultilineTokensBuilder();
		const { heuristicTokens } = this._tokenizer.tokenizeHeuristically(builder, startLineNumber, endLineNumber);
		const changedTokens = self.setTokens(builder.finalize());

		if (heuristicTokens) {
			// We overrode tokens with heuristically computed ones.
			// Because old states might get reused (thus stopping invalidation),
			// we have to explicitly request the tokens for the changed ranges again.
			for (const c of changedTokens.changes) {
				self._backgroundTokenizer.value?.requestTokens(c.fromLineNumber, c.toLineNumber + 1);
			}
		}

		self._defaultBackgroundTokenizer?.checkFinished();
	}

	pub fn forceTokenization(self: *TokenizerSyntaxTokenBackend, lineNumber: usize) void {
		const builder = ContiguousMultilineTokensBuilder.init();
		self._tokenizer?.updateTokensUntilLine(builder, lineNumber);
		self.setTokens(builder.finalize());
		self._defaultBackgroundTokenizer?.checkFinished();
	}

	pub fn hasAccurateTokensForLine(self: *TokenizerSyntaxTokenBackend, lineNumber: usize) bool {
		if (!self._tokenizer) {
			return true;
		}
		return self._tokenizer.hasAccurateTokensForLine(lineNumber);
	}

	pub fn isCheapToTokenize(self: *TokenizerSyntaxTokenBackend, lineNumber: usize) bool {
		if (!self._tokenizer) {
			return true;
		}
		return self._tokenizer.isCheapToTokenize(lineNumber);
	}

	pub fn getLineTokens(self: *TokenizerSyntaxTokenBackend, lineNumber: usize) LineTokens {
		const lineText = self._textModel.getLineContent(lineNumber);
		const result = self._tokens.getTokens(
			self._textModel.getLanguageId(),
			lineNumber - 1,
			lineText
		);
		if (self._debugBackgroundTokens and self._debugBackgroundStates and self._tokenizer) {
			if (self._debugBackgroundStates.getFirstInvalidEndStateLineNumberOrMax() > lineNumber and self._tokenizer.store.getFirstInvalidEndStateLineNumberOrMax() > lineNumber) {
				const backgroundResult = self._debugBackgroundTokens.getTokens(
					self._textModel.getLanguageId(),
					lineNumber - 1,
					lineText
				);
				if (!result.equals(backgroundResult) and self._debugBackgroundTokenizer.value?.reportMismatchingTokens) {
					self._debugBackgroundTokenizer.value.reportMismatchingTokens(lineNumber);
				}
			}
		}
		return result;
	}

	pub fn getTokenTypeIfInsertingCharacter(self: *TokenizerSyntaxTokenBackend, lineNumber: usize, column: usize, character: []const u8) StandardTokenType {
		if (!self._tokenizer) {
			return StandardTokenType.Other;
		}

		const position = self._textModel.validatePosition(Position.init(lineNumber, column));
		self.forceTokenization(position.lineNumber);
		return self._tokenizer.getTokenTypeIfInsertingCharacter(position, character);
	}


	pub fn tokenizeLinesAt(self: *TokenizerSyntaxTokenBackend, lineNumber: usize, lines: []const []const u8) ?[]LineTokens {
		if (!self._tokenizer) {
			return null;
		}
		self.forceTokenization(lineNumber);
		return self._tokenizer.tokenizeLinesAt(lineNumber, lines);
	}

	pub fn getHasTokens(self: *TokenizerSyntaxTokenBackend) bool {
		return self._tokens.hasTokens;
	}
};

// Port of `src/vs/base/browser/ui/scrollbar/scrollbarState.ts`.
//
// Terminal adaptation: the slider minimum can be expressed in terminal cells
// through `initWithMinimumSliderSize`. The editor scrollbar passes `1` instead
// of the upstream 20px default so a one-row thumb remains usable. The exact
// fractional getters expose sub-cell slider geometry for terminal painting;
// click and drag movement still use the upstream rounded offset/delta math.

const std = @import("std");

const MINIMUM_SLIDER_SIZE: f64 = 20;

pub const ScrollbarState = struct {
    /// For the vertical scrollbar: the width.
    _scrollbarSize: f64,
    /// For the vertical scrollbar: the height of the pair horizontal scrollbar.
    _oppositeScrollbarSize: f64,
    /// For the vertical scrollbar: the height of the scrollbar's arrows.
    _arrowSize: f64,

    // --- variables
    /// For the vertical scrollbar: the viewport height.
    _visibleSize: f64,
    /// For the vertical scrollbar: the scroll height.
    _scrollSize: f64,
    /// For the vertical scrollbar: the scroll top.
    _scrollPosition: f64,

    // --- computed variables
    /// `visibleSize - oppositeScrollbarSize`.
    _computedAvailableSize: f64,
    /// `scrollSize > 0 && scrollSize > visibleSize`.
    _computedIsNeeded: bool,
    _computedSliderSize: f64,
    _computedSliderRatio: f64,
    _computedSliderPosition: f64,

    /// Terminal adaptation: the smallest slider size in the caller's unit.
    _minimumSliderSize: f64,

    const ComputedValues = struct {
        available_size: f64,
        is_needed: bool,
        slider_size: f64,
        slider_ratio: f64,
        slider_position: f64,
    };

    pub fn init(
        arrowSize: f64,
        scrollbarSize: f64,
        oppositeScrollbarSize: f64,
        visibleSize: f64,
        scrollSize: f64,
        scrollPosition: f64,
    ) ScrollbarState {
        return initWithMinimumSliderSize(
            arrowSize,
            scrollbarSize,
            oppositeScrollbarSize,
            visibleSize,
            scrollSize,
            scrollPosition,
            MINIMUM_SLIDER_SIZE,
        );
    }

    pub fn initWithMinimumSliderSize(
        arrowSize: f64,
        scrollbarSize: f64,
        oppositeScrollbarSize: f64,
        visibleSize: f64,
        scrollSize: f64,
        scrollPosition: f64,
        minimumSliderSize: f64,
    ) ScrollbarState {
        var self = ScrollbarState{
            ._scrollbarSize = @round(scrollbarSize),
            ._oppositeScrollbarSize = @round(oppositeScrollbarSize),
            ._arrowSize = @round(arrowSize),
            ._visibleSize = visibleSize,
            ._scrollSize = scrollSize,
            ._scrollPosition = scrollPosition,
            ._computedAvailableSize = 0,
            ._computedIsNeeded = false,
            ._computedSliderSize = 0,
            ._computedSliderRatio = 0,
            ._computedSliderPosition = 0,
            ._minimumSliderSize = minimumSliderSize,
        };
        self.refreshComputedValues();
        return self;
    }

    pub fn clone(self: ScrollbarState) ScrollbarState {
        return self;
    }

    pub fn setVisibleSize(self: *ScrollbarState, visibleSize: f64) bool {
        const rounded = @round(visibleSize);
        if (self._visibleSize != rounded) {
            self._visibleSize = rounded;
            self.refreshComputedValues();
            return true;
        }
        return false;
    }

    pub fn setScrollSize(self: *ScrollbarState, scrollSize: f64) bool {
        const rounded = @round(scrollSize);
        if (self._scrollSize != rounded) {
            self._scrollSize = rounded;
            self.refreshComputedValues();
            return true;
        }
        return false;
    }

    pub fn setScrollPosition(self: *ScrollbarState, scrollPosition: f64) bool {
        const rounded = @round(scrollPosition);
        if (self._scrollPosition != rounded) {
            self._scrollPosition = rounded;
            self.refreshComputedValues();
            return true;
        }
        return false;
    }

    pub fn setScrollbarSize(self: *ScrollbarState, scrollbarSize: f64) void {
        self._scrollbarSize = @round(scrollbarSize);
    }

    pub fn setOppositeScrollbarSize(self: *ScrollbarState, oppositeScrollbarSize: f64) void {
        self._oppositeScrollbarSize = @round(oppositeScrollbarSize);
    }

    fn computeValues(
        oppositeScrollbarSize: f64,
        arrowSize: f64,
        visibleSize: f64,
        scrollSize: f64,
        scrollPosition: f64,
        minimumSliderSize: f64,
    ) ComputedValues {
        const availableSize = @max(0, visibleSize - oppositeScrollbarSize);
        const representableSize = @max(0, availableSize - 2 * arrowSize);
        const needed = scrollSize > 0 and scrollSize > visibleSize;

        if (!needed) {
            return .{
                .available_size = @round(availableSize),
                .is_needed = false,
                .slider_size = @round(representableSize),
                .slider_ratio = 0,
                .slider_position = 0,
            };
        }

        // The slider is artificially enlarged when needed so it can still be
        // grabbed with a pointer.
        const sliderSize = @round(@max(
            minimumSliderSize,
            @floor(visibleSize * representableSize / scrollSize),
        ));

        // The slider can move from 0 to `representableSize - sliderSize` in the
        // same way `scrollPosition` can move from 0 to `scrollSize - visibleSize`.
        const sliderRatio = (representableSize - sliderSize) / (scrollSize - visibleSize);
        const sliderPosition = @round(scrollPosition * sliderRatio);

        return .{
            .available_size = @round(availableSize),
            .is_needed = true,
            .slider_size = sliderSize,
            .slider_ratio = sliderRatio,
            .slider_position = sliderPosition,
        };
    }

    fn refreshComputedValues(self: *ScrollbarState) void {
        const values = computeValues(
            self._oppositeScrollbarSize,
            self._arrowSize,
            self._visibleSize,
            self._scrollSize,
            self._scrollPosition,
            self._minimumSliderSize,
        );
        self._computedAvailableSize = values.available_size;
        self._computedIsNeeded = values.is_needed;
        self._computedSliderSize = values.slider_size;
        self._computedSliderRatio = values.slider_ratio;
        self._computedSliderPosition = values.slider_position;
    }

    pub fn getArrowSize(self: *const ScrollbarState) f64 {
        return self._arrowSize;
    }

    pub fn getScrollPosition(self: *const ScrollbarState) f64 {
        return self._scrollPosition;
    }

    pub fn getRectangleLargeSize(self: *const ScrollbarState) f64 {
        return self._computedAvailableSize;
    }

    pub fn getRectangleSmallSize(self: *const ScrollbarState) f64 {
        return self._scrollbarSize;
    }

    pub fn isNeeded(self: *const ScrollbarState) bool {
        return self._computedIsNeeded;
    }

    pub fn getSliderSize(self: *const ScrollbarState) f64 {
        return self._computedSliderSize;
    }

    pub fn getSliderPosition(self: *const ScrollbarState) f64 {
        return self._computedSliderPosition;
    }

    /// Unrounded slider size, for sub-cell rendering. Upstream rounds the
    /// slider to whole pixels; the terminal keeps the fractional proportional
    /// size so the thumb's bottom edge can land on a half cell.
    pub fn getSliderSizeExact(self: *const ScrollbarState) f64 {
        if (!self._computedIsNeeded) return 0;
        const availableSize = @max(0, self._visibleSize - self._oppositeScrollbarSize);
        const representableSize = @max(0, availableSize - 2 * self._arrowSize);
        return @max(self._minimumSliderSize, self._visibleSize * representableSize / self._scrollSize);
    }

    /// Unrounded slider position, for sub-cell rendering. The scrollbar state
    /// keeps the upstream rounded value for hit testing; the terminal view uses
    /// the exact size and position to place the thumb at half-cell precision.
    /// Using the exact size as the travel denominator keeps the thumb flush
    /// with the end of the track at the maximum scroll position.
    pub fn getSliderPositionExact(self: *const ScrollbarState) f64 {
        if (!self._computedIsNeeded) return 0;
        const availableSize = @max(0, self._visibleSize - self._oppositeScrollbarSize);
        const representableSize = @max(0, availableSize - 2 * self._arrowSize);
        const sliderTravel = representableSize - self.getSliderSizeExact();
        const scrollTravel = self._scrollSize - self._visibleSize;
        if (sliderTravel <= 0 or scrollTravel <= 0) return 0;
        return self._scrollPosition * (sliderTravel / scrollTravel);
    }

    /// Compute a desired `scrollPosition` such that `offset` ends up in the
    /// center of the slider.
    pub fn getDesiredScrollPositionFromOffset(self: *const ScrollbarState, offset: f64) f64 {
        if (!self._computedIsNeeded) return 0;
        if (self._computedSliderRatio == 0) return self._scrollPosition;

        const desiredSliderPosition = offset - self._arrowSize - self._computedSliderSize / 2;
        return @round(desiredSliderPosition / self._computedSliderRatio);
    }

    /// Compute a desired `scrollPosition` from whether `offset` is before or
    /// after the slider position.
    pub fn getDesiredScrollPositionFromOffsetPaged(self: *const ScrollbarState, offset: f64) f64 {
        if (!self._computedIsNeeded) return 0;

        const correctedOffset = offset - self._arrowSize;
        var desiredScrollPosition = self._scrollPosition;
        if (correctedOffset < self._computedSliderPosition) {
            desiredScrollPosition -= self._visibleSize;
        } else {
            desiredScrollPosition += self._visibleSize;
        }
        return desiredScrollPosition;
    }

    /// Compute a desired `scrollPosition` such that the slider moves by
    /// `delta`.
    pub fn getDesiredScrollPositionFromDelta(self: *const ScrollbarState, delta: f64) f64 {
        if (!self._computedIsNeeded) return 0;
        if (self._computedSliderRatio == 0) return self._scrollPosition;

        const desiredSliderPosition = self._computedSliderPosition + delta;
        return @round(desiredSliderPosition / self._computedSliderRatio);
    }
};

pub const RateLimiter = struct {
    _lastRun: usize,
    _minimumTimeBetweenRuns: usize,
    timesPerSecond: u64,

    pub fn init(timesPerSecond: u64) RateLimiter {
        return RateLimiter{
            ._lastRun = 0,
            ._minimumTimeBetweenRuns = 1000 / timesPerSecond,
            .timesPerSecond = timesPerSecond,
        };
    }

    // pub fn runIfNotLimited(callback: () => void): void {
    //  const now = Date.now();
    //  if (now - this._lastRun >= this._minimumTimeBetweenRuns) {
    //   this._lastRun = now;
    //   callback();
    //  }
    // }
};

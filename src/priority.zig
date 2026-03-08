pub const Priority = enum(u2) {
    /// Frame-critical work: physics, animation, visibility
    high = 0,
    /// Standard work: AI, scripting, audio
    normal = 1,
    /// Deferrable background work: streaming, compression
    low = 2,
};

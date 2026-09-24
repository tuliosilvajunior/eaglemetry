/// How often a history list re-reads on its own.
///
/// The car announces a session write, so the tick is only the fallback for a
/// push that never connected. A closed session cannot grow, so nothing here
/// changes between one write and the next.
const historyFallbackInterval = Duration(minutes: 5);

/// How many records a history pane asks for.
const historyLimit = 50;

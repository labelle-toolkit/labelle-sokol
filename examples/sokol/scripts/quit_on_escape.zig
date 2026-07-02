// Global script (lives at scripts/ root, runs in every state) — quits
// the game on ESC. The frame template polls `g.isRunning()` after each
// tick and routes the exit through `window.requestQuit()`, so any
// `game.quit()` call (from a script, a UI button, an engine hook)
// produces the same shutdown path.

pub fn tick(game: anytype, _: f32) void {
    if (game.isKeyPressed(.escape)) game.quit();
}

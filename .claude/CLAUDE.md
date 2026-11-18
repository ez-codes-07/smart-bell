# Smart Bell — Claude Code guidance

Mirrors the Codex setup in `AGENTS.md` and `.agents/`. The project context and TODO live in `.agents/context/` and are imported below so both tools share one source of truth — edit them there, not here.

- Use the repo skills in `.claude/skills/` when changing SwiftUI/Xcode app code (`smartbell-ios-workflows`), ESP32 BLE integration (`smartbell-esp32-ble`), or IMU rep analysis (`smartbell-motion-analysis`).
- Treat hardware protocol details (device name, UUIDs, packet layout, units, sensor model) as provisional until confirmed from firmware.

@../.agents/context/PROJECT_CONTEXT.md
@../.agents/context/PROJECT_TODO.md

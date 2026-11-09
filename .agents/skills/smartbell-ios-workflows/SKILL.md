---
name: smartbell-ios-workflows
description: Build or change the Smart Bell native iOS app, its SwiftUI screens, Xcode project configuration, or local persistence.
---

# Smart Bell iOS workflows

Use this skill for app work in this repository. Read [project context](../../context/PROJECT_CONTEXT.md) first for the current structure and hardware assumptions.

- Keep the app native SwiftUI and compatible with the project's iOS deployment target. Avoid new dependencies unless the task needs them.
- Keep views in `SmartBell/` and sensor, BLE, analysis, models, and persistence code in `SmartBell/Backend/`.
- When adding or moving Swift files, update the explicit source build phase and group references in `SmartBell.xcodeproj/project.pbxproj`.
- Preserve automatic code signing. Do not disable signing; a developer must select their own Apple development team in Xcode for device runs.
- Keep a demo path for UI and sensor work that does not require connected hardware.
- Do not represent simulator or demo behavior as validated against the physical ESP32. State when Xcode or device validation was unavailable.

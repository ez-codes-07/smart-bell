---
name: smartbell-motion-analysis
description: Design or tune Smart Bell inertial-sensor calibration, repetition segmentation, angular excursion, speed, or movement-consistency feedback.
---

# Smart Bell motion analysis

Read [project context](../../context/PROJECT_CONTEXT.md) before changing signal logic.

- Treat calibration as exercise-specific and dependent on consistent sensor mounting. Keep thresholds and signal-processing parameters configurable.
- Use timestamps and units from the active sensor decoder. Filter or reject stale, malformed, and implausible samples before analysis.
- Distinguish measurable signals (rep timing, angular speed, relative angular excursion) from inferred form quality. Accelerometer integration drifts and does not by itself yield a trustworthy 3D path.
- Compare a rep with that user's calibrated motion signature and present concise cues. Avoid accuracy percentages, medical claims, or automatic weight prescriptions without appropriate validation.
- Preserve the demo stream for development, but keep its results visibly identified as simulated.
- When changing thresholds or rep segmentation, explain the expected motion pattern and limitations; tune against recorded, labeled hardware data when available.

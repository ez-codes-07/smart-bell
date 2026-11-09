# Smart Bell project TODO

## Functions and product requirements

### App and training functions

- Improve and validate rep counting for supported exercises (a prototype counter exists).
- Detect form breaks, including non-linear or non-standard rep paths, and consider suggesting a weight decrease when form drifts; target greater than 90% accuracy only after testing against labeled movements.
- Suggest heavier or lighter weights using rep speed and/or pathing, including detecting reps that are consistently too fast and suggesting the user consider increasing weight.
- Provide a buzz after a sufficiently good rep to reinforce good form, and buzz or otherwise give real-time feedback when the dumbbell path deviates.
- Detect too few or too many reps relative to the user's set target.
- Graph and map gyroscope data for inspection and movement analysis.
- Let users choose exercises, expanding beyond bicep curls and shoulder presses to movements such as dumbbell press.
- Add motivating notifications and configurable workout reminders or alarms.
- Log workout days and improve adherence tracking.
- Keep the app simple and accessible for older adults.
- Explore a calibration and starting-weight flow: collect proposed age, height, and body-weight inputs, calculate a suggested starting weight, then let the user try controlled reps. Form drift could indicate the load is too heavy; performing more reps than the target could indicate it is too light. Review and validate this guidance before implementation. Users still enter the actual dumbbell weight because the hardware cannot measure it.

### Hardware and system requirements

- Design a secure dumbbell attachment that stays attached during intense exercises.
- Support wireless connection from the sensor/ESP32 to the app.
- Resist small water exposure (exact ingress requirement still to be defined).
- Keep the attachment no larger than 15 × 15 × 15 cm.

### Open brainstorm items

- The source notes include an unfinished objective (“App should detect …”) and the prompt “training?”; clarify these with the team before implementation.
- Treat the greater-than-90% path/form accuracy item as a validation goal, never as a product claim before measured results support it.


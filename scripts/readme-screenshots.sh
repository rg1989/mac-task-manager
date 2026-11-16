#!/bin/bash
# Render the README screenshots off-screen with sample data.
# Writes assets/screenshots/processes.png and smart-scan.png.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product MacClean
TM_SCREENSHOT_DIR="assets/screenshots" "$(swift build -c release --show-bin-path)/MacClean"
ls -la assets/screenshots

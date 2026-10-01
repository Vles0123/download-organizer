#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/下载整理助手.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -O -parse-as-library "$PROJECT_DIR/Sources/Organizer.swift" \
  -o "$APP_DIR/Contents/MacOS/DownloadOrganizer"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
"$APP_DIR/Contents/MacOS/DownloadOrganizer" --self-test
printf '构建完成：%s\n' "$APP_DIR"

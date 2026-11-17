# iWord iOS

Offline-first personal vocabulary learning app for iOS 15+, built with SwiftUI and SQLite. Includes review, practice, listening medleys, local backup, manual content updates and an optional on-device AI learning coach.

## Public build source

This repository starts with a clean snapshot. It contains no private repository history, textbook PDF, textbook recordings, full vocabulary export, real study records, backend configuration, API credentials or signing assets. The five demo entries use independently written short definitions and generated test tones (not spoken pronunciation). Download authorized content from your own server for actual study audio. Existing installed vocabulary and audio remain on the phone when updating in place.

The build workflow is manual only. It runs core tests, native logic tests, simulator UI tests and an unsigned arm64 iOS 15 build. Sign the resulting IPA locally using your own Apple account; never upload signing credentials here. The bundle identifier remains `biz.powerunion.iword` for in-place updates. Build numbers use 100 plus the workflow run number.

## Local checks

`python3 iword-ios/scripts/check_source.py`

On macOS: `swift test --package-path iword-ios/Core --parallel`, or open the Xcode project. The workflow pins Xcode 16.4 and ZIPFoundation 0.9.19.

AI credentials are synchronized from a user-configured server into the device Keychain. No default credentials or personal server address are included. Night analysis is best effort under iOS scheduling and can also be run manually.

Source publication does not grant rights to third-party textbooks or recordings. ZIPFoundation is obtained separately by Swift Package Manager under its own license. No additional source license is granted by this snapshot.

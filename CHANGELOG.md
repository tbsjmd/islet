# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Assistant in the island, after Atticus and Plip: hold Control-Option and ask out loud, or type. Instant commands run without AI; other questions go to your signed-in Claude Code with a screenshot when they're about the screen. It can open apps and links, search, set volume, dark mode and timers, find files, run Shortcuts and add reminders, asking before anything that quits, runs or writes. It remembers what you tell it, reads replies aloud and shows its state on the closed island.

## [1.0.0] - 2026-11-02

### Summary
Islet's first release puts a teleprompter and a video downloader in the Dynamic Island.

### Added
- Teleprompter in the island, after Textream: word tracking highlights each word as you say it, with classic and voice-activated scrolling too. Reading keeps the island open under the camera and shows progress on the closed island.
- Video Downloader in the island, after Parabolic: paste a link, pick video or audio and quality, and yt-dlp downloads it. Progress shows on the closed island, and a finished file is announced and one click from Finder.

### Changed
- New name, mark and bundle identifier. The Dynamic Island is on by default.

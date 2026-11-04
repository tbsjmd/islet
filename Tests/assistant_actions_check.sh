#!/bin/zsh
# Compiles the assistant's command and reply parsers against tiny stubs and checks them.
set -euo pipefail
cd "$(dirname "$0")/.."
dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
cat > "$dir/stubs.swift" <<'SWIFT'
enum NotchPlaybackCommand: Equatable { case toggle, next, previous }
enum NotchTimerMode { case timer }
final class NotchMusicService { static let shared = NotchMusicService(); func send(_ c: NotchPlaybackCommand) -> Bool { true } }
final class NotchTimerService { static let shared = NotchTimerService(); func start(mode: NotchTimerMode, minutes: Int) {} }
SWIFT
cat > "$dir/main.swift" <<'SWIFT'
import Foundation
func check(_ ok: Bool, _ what: String) { if !ok { print("✗ \(what)"); exit(1) } }
check(AssistantActions.instant("Volume 30") == .volume(30), "volume")
check(AssistantActions.instant("please mute") == .mute(true), "mute")
check(AssistantActions.instant("turn on dark mode") == .darkMode(true), "dark mode")
check(AssistantActions.instant("set a 10 minute timer") == .timer(minutes: 10), "timer")
check(AssistantActions.instant("timer for 5 minutes") == .timer(minutes: 5), "timer for")
check(AssistantActions.instant("search for best tacos") == .webSearch("best tacos"), "search")
check(AssistantActions.instant("remember I prefer aisle seats") == .remember("I prefer aisle seats"), "remember")
check(AssistantActions.instant("run my Log Water shortcut") == .runShortcut("Log Water"), "shortcut")
check(AssistantActions.instant("remind me to call Sam in 20 minutes") == .reminder(title: "call Sam", minutes: 20), "reminder")
check(AssistantActions.instant("open Finder") == .openApp("Finder"), "open app")
check(AssistantActions.instant("open the pod bay doors") == nil, "unknown app goes to the model")
check(AssistantActions.instant("what's on my screen") == nil, "questions go to the model")
let reply = "Opening it now.\n```actions\n[{\"do\":\"open_app\",\"name\":\"Safari\"},{\"do\":\"volume\",\"level\":140},{\"do\":\"open_url\",\"url\":\"file:///etc/passwd\"}]\n```"
let parsed = AssistantActions.parse(reply: reply)
check(parsed.text == "Opening it now.", "reply text without the block")
check(parsed.actions == [.openApp("Safari"), .volume(100)], "actions parsed, clamped, non-web URL dropped")
check(AssistantAction(kind: .quitApp("Slack")).needsConfirmation && !AssistantAction(kind: .volume(3)).needsConfirmation, "confirmation")
let plan = AssistantPlan.parse("Sure.\n```json\n{\"say\":\"Opening File\",\"actions\":[{\"do\":\"point\",\"element\":2}],\"done\":false}\n```")
check(plan.say == "Opening File" && plan.steps.count == 1 && !plan.done, "agent step parsed from a fenced reply")
let plain = AssistantPlan.parse("It's 4pm in Tokyo.")
check(plain.say == "It's 4pm in Tokyo." && plain.steps.isEmpty && plain.done, "a plain answer is a finished step")
print("ASSISTANT ACTIONS CHECK OK")
SWIFT
# AssistantActions.swift uses AppKit types; the stubs stand in for the island services.
swiftc -O -o "$dir/check" Sources/Islet/Services/Assistant/AssistantActions.swift "$dir/stubs.swift" "$dir/main.swift" 2>&1 | grep -v warning || true
"$dir/check"

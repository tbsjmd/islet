# Islet

**Your Mac's Dynamic Island, finally doing something.**

Islet turns the strip of black around your MacBook's camera into the busiest, most useful few square centimeters on your screen. It is a voice assistant you talk to by holding two keys, a teleprompter that reads along with you right under the lens, a video and audio downloader that works from a pasted link, and a home for more than seventy small Mac tools that would otherwise each cost you a separate app, a separate menu bar icon and a separate subscription.

It is free, it is open source under the GPL, it runs on your Mac rather than someone's server, and it asks for a permission only when a feature you chose actually needs it.

---

## The idea

Apple gave the iPhone a Dynamic Island: a pill around the camera that grows to show a timer, a call, a song or a delivery, then shrinks back out of the way. The MacBook got the same cutout in its screen and none of the cleverness. On most Macs the notch is simply a hole the menu bar has to work around.

Islet fills that space. At rest it is a small black shape around the camera (or, on a Mac without a notch, a floating capsule in the middle of the menu bar that looks like one). When something is happening it grows a little to tell you: a timer counting down, a song playing, a download's percentage, the assistant listening. Hover over it, or click it, and it opens into a panel with pages you can move between, each one a tool. Move the pointer away and it folds itself back up.

Everything Islet does is built around that one rule: be there the instant you need it, and be invisible the rest of the time.

---

## The three headline features

These three lead the island. They are what Islet is for.

### 1. The Assistant: talk to your Mac

Hold **⌃ control** and **⌥ option** together, say what you want, and let go.

The island opens to the Assistant, your words appear as you speak them, and when you release the keys Islet works out what to do. You can also type into the Assistant page instead of talking.

**Instant commands, no AI at all.** A lot of what people ask a Mac to do is simple and doesn't need a language model to understand. Islet recognizes these and does them immediately, offline and free:

- "Open Spotify", "launch Xcode", "open settings"
- "Quit Slack" (this one asks first)
- "Volume 30", "mute", "unmute"
- "Dark mode on", "switch to light mode"
- "Search for the best ramen near me"
- "Play", "pause", "next song", "previous track"
- "Set a 10 minute timer", "timer for 25 minutes"
- "Run my Log Water shortcut" (any of your Apple Shortcuts; asks first)
- "Find my lease PDF" (searches your Mac with Spotlight and lists what it finds; click one to open it)
- "Remind me to call Sam in 20 minutes" (adds it to Reminders; asks first)
- "Remember I prefer aisle seats"

App names are forgiving: "Chrome", "VS Code", "settings", "browser" and "texts" all go where you'd expect.

**Everything else goes to Claude, on the plan you already have.** For questions and requests that need real thought, Islet hands your words to [Claude Code](https://claude.com/claude-code), the command-line tool you sign in to with your Claude account. There's no API key to create and nothing extra to pay for: it runs on the plan you're already on. You choose the model from the ✦ menu: **Haiku** (the default, fast and inexpensive, a typical question costs a fraction of a cent of plan usage), **Sonnet** (smarter) or **Opus** (the most capable).

**It can see your screen, but only when you ask about it.** Say "what does this error mean?", "summarize this page", "what am I looking at?" or "where's the export button?" and Islet attaches a picture of the display your pointer is on, scaled down so it's quick to send. Questions that aren't about the screen don't send one. Each answer that used the screen is marked with a small eye so you always know.

**It does things, and it asks before anything risky.** Claude's replies can include actions from a short, fixed list that Islet knows how to perform: opening apps and links, searching the web or your files, changing the volume or the appearance, starting timers, playing music, running a Shortcut, adding a reminder, or remembering something. Islet never gives the model a shell, file access or the ability to run arbitrary commands. Anything that closes, runs or writes something (quitting an app, running a Shortcut, adding a reminder, opening a program file) shows up as a card with **Do it** and **Not now** buttons and waits for you.

**It remembers you.** Tell it "remember that my sister's name is Ana" or "remember I work in Pacific time" and that fact is included with every request from then on. The ✦ menu lists what it remembers, and you can forget any item with a click.

**It talks back.** When you asked out loud, the reply is read aloud too. The speaker button in the Assistant page turns that off.

**It keeps a conversation.** Follow-ups work: ask "what's this chart?", then "and what does the red line mean?", and the second question knows about the first.

**It shows its state in the closed island.** While it listens, the island reads *Listening*. While Claude thinks, *Thinking*. While it speaks, *Talking*. Click the island at any point to open the Assistant page; press the stop button to cut it off.

**Privacy.** Your voice is turned into text by Apple's speech recognition on your Mac; audio isn't uploaded. What leaves your Mac is the text of a question you sent to Claude and, only when you asked about the screen, one screenshot, both sent through your own Claude Code sign-in.

The Assistant takes the best ideas from two open-source projects, [Atticus](https://github.com/SaarthurR/atticus-mac) and [Plip](https://github.com/hussainn7/plip-oss): hold-to-talk from the notch, instant commands that skip the AI, screen-aware answers on the plan you already pay for, and actions that ask first. It is a fresh Swift implementation built into the island.

### 2. The Teleprompter: read your script under the camera

If you record videos, present on calls or stream, the hardest part is looking at the lens while remembering what to say. The Teleprompter puts your script in the island, right under the camera, so your eyes stay where your audience sees them.

Paste or type your script into the Teleprompter page and press play (or ⌘↩). The island stays open while you read, and the text scrolls in one of three ways:

- **Word tracking.** Islet listens and highlights each word as you say it, keeping the current line in view. Skip a sentence, ad-lib, go back, and it finds where you are. Click any word to jump there.
- **Classic.** The script scrolls at a steady pace you set, from 100 to 200 words a minute. No microphone needed.
- **Voice-activated.** The script scrolls at that pace only while you're speaking, and waits when you pause to think.

Words you've already read dim, the current one glows, and the rest wait in white. Choose a text size that's comfortable from your chair. Pause, step back a few words or stop from the top row. If you close the island mid-read, the closed island shows how far through you are.

The speech engine comes from [Textream](https://github.com/f/textream), an excellent open-source teleprompter, included under its MIT license.

### 3. The Video Downloader: paste a link, get the file

Copy a link to a video from YouTube or any of more than a thousand other sites, open the Video Downloader page, and the link is already filled in. Choose **Video** or **Audio**, pick a quality (**Best**, **1080p**, **720p** or **480p**), and press return.

The download runs in the island. Each one shows its title, a progress bar, its speed and how long is left; you can cancel any of them. Close the island and the closed island keeps showing the percentage. When a file finishes, the island announces it, and one click shows it in Finder (double-click to open it). Files go to your Downloads folder unless you pick another one.

Under the hood Islet uses [yt-dlp](https://github.com/yt-dlp/yt-dlp), the widely trusted open-source downloader. If you already have it (for example from Homebrew), Islet uses yours; if not, one click fetches it. If ffmpeg is installed, video and audio streams are merged into a single MP4 and audio downloads are saved as M4A. The page's design follows [Parabolic](https://github.com/NickvisionApps/Parabolic), a popular open-source downloader for Linux and Windows.

Please download only what you have the right to.

---

## Everything else in the island

The island has more pages than the three above, and you choose which ones appear and in what order.

- **Controls.** Volume, display brightness and keyboard brightness sliders, playback, Keep Awake and quick shortcuts on one home page.
- **Now Playing.** The song, its artwork, playback controls, scrubbing, a live equalizer, synced lyrics where available and the up-next queue, for Apple Music, Spotify and supported browsers.
- **Mixer.** Per-app volume in the island.
- **Clipboard.** Your clipboard history; ⌘1 to ⌘9 paste the entries in order.
- **Captures.** Your recent screenshots and recordings, ready to drag, share or delete.
- **Files.** A shelf to park files on while you drag them between places.
- **System.** CPU, GPU, memory, network, disk, battery and fan readings with graphs.
- **Calendar.** Your next event with a countdown, and a month view.
- **Notifications.** Recent notifications, gathered in one place.
- **Timer.** Timers, a Pomodoro cycle and a stopwatch, with the countdown on the closed island.
- **Camera.** A mirror to check how you look before a call.
- **Downloads.** Browser downloads from a folder you choose, with progress.
- **Scratchpad.** Quick notes in tabs, with Markdown preview.
- **AI Agents.** Live status, limits and usage for Claude, Codex, OpenCode and GitHub Copilot sessions, with a notice when a long task finishes.
- **Watch.** Keep an eye on part of another window and get told when it changes.

The closed island also shows **live activities**, the small readings around the camera: the Assistant's state, Teleprompter progress, a video download's percentage, a running timer, a browser download, working AI agents, the next meeting's countdown, the song that's playing, and Keep Awake. When more than one is happening, hover to choose which one the island shows, or pair two side by side.

There's a small companion character that can live in the island too, if you like that sort of thing.

---

## Seventy-plus Mac tools, one menu bar icon

Beyond the island, Islet replaces a drawer full of small utilities. Each is a feature you can install or uninstall on its own in Settings → Features; an uninstalled feature stops loading entirely and disappears from the interface, and reinstalling it brings its settings back.

**Sound.** A per-app volume mixer that can boost quiet apps past 100%; play different apps through different outputs; switch outputs with a shortcut and lower the volume when headphones disconnect; microphone mute and level controls; and a blocker for the Music app that launches itself when you press play.

**Knowing what your Mac is doing.** A real system monitor with CPU, GPU, memory, temperatures, battery health and power draw, history graphs and the apps using the most energy; fan control with manual speeds or temperature curves (beta); any of those readings in the menu bar; live network traffic, totals, your local IP and a speed test; and alerts for heat, memory pressure, low disk space or low battery.

**Windows and the Dock.** A better app and window switcher with live previews and search; window snapping with shortcuts, screen edges or modifier-drag; window previews when you hover over the Dock; Dock clicks that minimize, hide or cycle windows; a green button that fills the screen without making a new Space; Spaces that stay in the order you set; apps that quit when their last window closes; and protection against an accidental ⌘Q or ⌘W.

**Keyboard and mouse.** Text snippets that expand as you type; smooth scrolling and linear scrolling for mice; turning off pointer acceleration; focus that follows the mouse; separate scroll direction for mouse and trackpad; sideways scrolling while holding a key; Back and Forward on mouse side buttons; shortcuts on extra mouse buttons; middle click from a three-finger trackpad press; filters for a worn mouse button or a keyboard that repeats letters; and a Super key made from Caps Lock or a spare modifier.

**Clipboard, files and links.** Searchable clipboard history with images and files; automatic clipboard clearing; paste as plain text; a drag-and-drop shelf; ⌘X and ⌘V to move files in Finder and F2 to rename; tracking parameters stripped from links; and installing an app from a disk image in one step.

**Everyday tools.** A Command Bar that searches apps, windows, files, clipboard, snippets and app menus from one field; a quick panel of favorite tools; quick toggles for things like hiding desktop icons, ejecting disks and locking the screen; a list for quitting apps in bulk; a radial menu around the pointer; and a Cleaning Mode that locks the keyboard while you wipe it.

**Capture and create.** Screenshots of an area, window, screen or a whole scrolling page, with an editor; screen recording with separate system-audio and microphone tracks; text recognition and QR codes from anything on screen; a color picker that copies HEX, RGB, HSL or SwiftUI code; and local media tools to compress video, convert images in bulk, add watermarks and make GIFs.

**App management.** One list of available updates for App Store, Homebrew and other apps; a cleaner for caches, logs and leftovers; an uninstaller that finds an app's hidden files; a Homebrew manager; and a port manager that shows which processes are listening.

**Energy and display.** Keep Awake on a timer, with the lid closed, or while certain apps or displays are present; brightness for every display, including external monitors and dimming below their minimum; extra brightness on XDR displays; and Bluetooth that sleeps when your Mac does.

---

## Private by default

Islet has no account, no analytics and no tracking. Your settings, clipboard history, notes and memories stay on your Mac.

The network is used only by things you start yourself: questions you send to the Assistant (through your own Claude Code, with a screenshot only when you asked about the screen), video downloads and the one-time yt-dlp download, the speed test, Homebrew actions, App Store and app update checks, and optional online lyrics. Speech recognition for the Assistant and the Teleprompter happens on your Mac.

Permissions are asked for only when a feature you installed needs them, and Islet explains each one in plain words. The Settings → Permissions page shows which features use which permission, and tells you when a permission you granted is no longer needed by anything.

Here is what the headline features ask for:

| Feature | Permission | Why |
|---|---|---|
| Dynamic Island | Accessibility | To read media keys, the pointer and the windows around the island |
| Assistant | Microphone, Speech Recognition | To hear your question while you hold ⌃⌥ |
| Assistant | Screen Recording | Only for questions about your screen |
| Assistant | Automation (System Events, Reminders) | Only for dark mode and reminders, when you ask |
| Teleprompter | Microphone, Speech Recognition | Only for Word Tracking and Voice-Activated modes |
| Video Downloader | None | It writes to your Downloads folder |

---

## Getting Islet

1. Download **Islet.dmg** and open it.
2. Drag **Islet** onto the **Applications** folder in the window that appears.
3. Open Islet from your Applications folder. The first time, macOS may say it can't verify the developer: open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. (Islet isn't notarized by Apple yet.)
4. A short setup lets you choose a starting set of features; the Dynamic Island is always included. You can add or remove anything later in Settings → Features.
5. Hover over the island. Then hold **⌃ control + ⌥ option** and say hello.

**For the Assistant's AI answers**, install [Claude Code](https://claude.com/claude-code) and sign in once in Terminal by running `claude`. Instant commands work without it.

**Requirements.** A Mac with Apple Silicon running macOS 14 Sonoma or newer. The island looks and works best on a MacBook with a notch; other Macs get a floating capsule in the menu bar.

---

## Questions

**Does the Assistant cost money?** Instant commands are free and offline. AI answers use your existing Claude plan through Claude Code, with no API key. A typical Haiku question uses a fraction of a cent of plan usage; Sonnet and Opus use more.

**Can the Assistant delete my files or send emails?** No. It can only perform the specific actions on its list, none of which delete or send anything, and the ones that quit, run or write something wait for your "Do it".

**Does ⌃⌥ get in the way of my other shortcuts?** Islet only starts listening after you've held those two keys by themselves for about a third of a second. Pressing another key or clicking within that moment cancels it, so quick shortcuts like ⌃⌥→ and modifier-drags keep working.

**Does Islet work without a notch?** Yes. On displays without one, the island floats as a capsule at the top center of the screen, and you can show it on every display at once.

**Can I hide pages I don't use?** Yes. Settings → Dynamic Island lets you reorder and hide pages, change the island's size and shape, choose what it shows at rest and decide which live activities it displays.

**Is it really free?** Yes, and the source code is public under the GNU General Public License v3.0 or later.

---

## Credits

Islet is a fork of [Vorssaint Utils](https://github.com/vorssaint/vorssaint-utils) (GPL-3.0), which provides the Dynamic Island and the Mac tools. The Teleprompter's speech engine comes from [Textream](https://github.com/f/textream) (MIT). The Video Downloader follows [Parabolic](https://github.com/NickvisionApps/Parabolic) and runs [yt-dlp](https://github.com/yt-dlp/yt-dlp). The Assistant follows [Atticus](https://github.com/SaarthurR/atticus-mac) and [Plip](https://github.com/hussainn7/plip-oss) (both MIT). Islet isn't affiliated with or endorsed by any of these projects. Full notices are in `THIRD_PARTY_NOTICES.md`.

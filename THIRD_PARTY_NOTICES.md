# Third-party notices

Islet is free software under the GNU General Public License v3.0 or later (see LICENSE).

## Vorssaint Utils
Islet is a fork of Vorssaint Utils (https://github.com/vorssaint/vorssaint-utils),
Copyright (C) 2026 Vorssaint, GPL-3.0-or-later. Source files keep their original
copyright headers. Islet is not affiliated with or endorsed by the Vorssaint project,
and uses its own name, icon and bundle identifier as TRADEMARKS.md asks.

## Parabolic
The Video Downloader page follows the design of Parabolic
(https://github.com/NickvisionApps/Parabolic), GPL-3.0. No Parabolic source is
included; downloads are performed by yt-dlp (https://github.com/yt-dlp/yt-dlp,
Unlicense), which Islet runs from your installation or downloads on first use.

## Atticus and Plip
The Assistant (Sources/Islet/Services/Assistant) follows the design of Atticus
(https://github.com/SaarthurR/atticus-mac, MIT, Copyright (c) 2026 SaarthurR) and
Plip (https://github.com/hussainn7/plip-oss, MIT, Copyright (c) 2026 Hussain): the
hold-to-talk shortcut, instant commands, app-name aliases, screen-aware questions,
the step-by-step agent loop, the element map, pointing on screen and ask-first actions.
AssistantHands.swift adapts Atticus's key-combo parser, risky-key check and
front-of-screen mouse, drag and scroll events (MIT, Copyright (c) 2026 SaarthurR).

## Textream
The teleprompter's speech engine (Sources/Islet/Services/Teleprompter/Textream*.swift)
is taken from Textream (https://github.com/f/textream) under the MIT License:

```
MIT License

Copyright (c) 2026 Fatih Kadir Akin

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

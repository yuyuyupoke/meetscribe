# Troubleshooting

## "App can't be opened — unidentified developer"

Ad-hoc signing triggers Gatekeeper on first launch.

```bash
xattr -cr "/Applications/Clawd Listen.app"
```

Then right-click the app and choose **Open**.

## "The Realtime Beta API is no longer supported"

The OpenAI Realtime API Beta endpoint has been retired. Update to the latest release.

## "claude CLI not found"

Q&A requires Claude Code installed and reachable on `$PATH`.

```bash
which claude
```

Install: [docs.claude.com/en/docs/claude-code/quickstart](https://docs.claude.com/en/docs/claude-code/quickstart)

## VU meter moves but no transcription

Quota exhausted or audio considered silent by server VAD.

- Check usage: [platform.openai.com/usage](https://platform.openai.com/usage)
- Try speaking louder, or move closer to the microphone
- Confirm the input device in System Settings → Sound

## Microphone captures the other party (double-labeled transcript)

Voice Processing should prevent this, but in some Bluetooth headsets the echo path is too long.

- Use wired headphones if possible
- Lower output volume; AEC works better at moderate levels

## Resetting all preferences

```bash
defaults delete com.clawdlisten.app
launchctl bootout "gui/$(id -u)/com.clawdlisten.agent" 2>/dev/null
```

Re-launch the app and re-enter API key and folders.

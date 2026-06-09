# Security Policy

## Reporting a Vulnerability

Please report security vulnerabilities through GitHub's
[private vulnerability reporting](https://github.com/yuyuyupoke/clawd-listen/security/advisories/new)
rather than opening a public issue.

Initial response within 72 hours. Please refrain from public disclosure until a fix is released.

## Notes

- OpenAI API keys are stored in the macOS Keychain (`com.clawdlisten.app` service).
- Transcribed audio is sent to the OpenAI Realtime API. Do not use for confidential meetings without organizational approval.
- Q&A queries are executed locally via the Claude Code CLI subprocess.

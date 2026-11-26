# Security policy

## Reporting a vulnerability

Please do not open a public issue. Report it privately with GitHub's
"Report a vulnerability" button in the repository's **Security** tab
(private vulnerability reporting).

Include what you found, how to reproduce it and the Tabula version. I will reply as soon as I can.

## Scope

Anything that could expose or misuse credentials or run unintended code, in particular:

- passwords stored in the macOS Keychain
- Aurora DSQL IAM token generation and caching
- pre-connect scripts and tunnels

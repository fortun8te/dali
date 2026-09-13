# Security

DALI is a preview project. Please report security issues through GitHub private vulnerability reporting, not a public issue containing personal logs or reproduction details that expose a user.

The browser bridge listens on the loopback interface. It accepts status requests and restricts playback-control requests to extension clients. It does not provide access to files, shell commands, or account credentials. It is not a security boundary against other software already running on your Mac.

The audio engine communicates with speakers on your local network. Use a trusted network. Release checks and remaining distribution requirements are documented in docs/releasing.md.

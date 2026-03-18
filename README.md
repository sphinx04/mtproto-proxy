# MTProto Proxy

This script installs and runs a Telegram MTProto proxy with Fake TLS in **one command**.

## Features

- One-command install
- Fake TLS support (domain-based obfuscation)
- Persistent secret (does NOT change after reboot)
- Auto-start on reboot (systemd)
- Docker-based (clean + isolated)
- Outputs ready-to-use Telegram link

---

## Quick Start

Run this on your VPS for setup:

```bash
curl -fsSL https://raw.githubusercontent.com/sphinx04/mtproto-proxy/main/setup.sh | bash
```

To remove:
```bash
curl -fsSL https://raw.githubusercontent.com/sphinx04/mtproto-proxy/main/remove.sh | bash
```

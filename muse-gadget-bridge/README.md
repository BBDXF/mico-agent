# Muse Gadget bridge for mico-agent

The bridge exposes only `POST /ask` on port 8765. It requires a shared Bearer token and delegates the message to the already-installed Muse Linux SDK via `musegadget send-user-msg --wait`. It does not expose a shell endpoint.

Request:

```http
POST /ask
Authorization: Bearer <token>
Content-Type: application/json

{"text":"question for Muse"}
```

Success response: `{"reply":"Muse's text reply"}`. Configure the same token in mico-agent's `muse.bridge_token`. The endpoint uses plain HTTP for a trusted home LAN; do not forward port 8765 to the public internet.

Install on Ubuntu after the official Muse Gadget SDK has created the `musegadget` account:

```sh
bash install.sh
```

The install script creates a random token if none exists, stores it root-only in `/etc/mico-muse-bridge.env`, and starts `mico-muse-bridge.service`. To copy the token into mico-agent's web config, read it locally with `sudo cat /etc/mico-muse-bridge.env`; do not send it in chat.

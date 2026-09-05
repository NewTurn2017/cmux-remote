# Browser client

Phone/tablet client for the relay. The relay serves this directory as-is; open
`http://<your-machine>:4399/` from any device on the tailnet.

## Deploy

The relay reads `~/.cmuxremote/web` by default (override with `web_root` in
`relay.json`). It only serves static files when that directory already exists —
a missing directory leaves the relay API-only, exactly as before.

```sh
mkdir -p ~/.cmuxremote/web
cp -R web/ ~/.cmuxremote/web/
```

No build step. `vendor/xterm.js` is checked in deliberately: the page has to
work with nothing but the tailnet reachable, and a CDN would be a second thing
that can be down or blocked.

## What the screen model is

The relay does not stream bytes. It sends whole rows with their ANSI escapes
intact:

- `screen.full` — `{ rows: [String], cols, rowsCount, cursor }`
- `screen.diff` — `{ ops: [{op: "row"|"cursor"|"clear", …}] }`

`app.js` repaints by moving the cursor and rewriting individual rows, and
diffs each incoming `screen.full` against the previous one so only changed
rows reach xterm.

## Two things that will bite you

**The first WebSocket frame is a bare `HelloFrame`** — `{deviceId, appVersion,
protocolVersion}` — *not* a JSON-RPC envelope, and `deviceId` is the
`device_id` from registration. Get it wrong (or take longer than 100ms) and the
server closes the socket without a word; the browser only reports code 1006.

**Every update arrives as a full frame**, ~76KB, several times a second
(400–800KB/s). `Screen.requiresFullReset` returns true whenever cmux bumps its
render epoch, which is every read in practice, so `screen.diff` never fires.
That is why the client unsubscribes when the tab is hidden and offers a pause
button — leave a phone on this screen and it will eat mobile data.

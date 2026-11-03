# Friends: sharing a SharePlay build of Walkabout (experimental)

SharePlay (Group Activities) is granted to paid Apple teams only, and SharePlay finds the game on the other
participants' headsets by its bundle identifier. So for a round of Walkabout with Spatial Personas, one player with
a paid team builds the game once for everybody: an ad-hoc signed app that runs on the friends' Vision Pros, under one
bundle identifier. AVP Play does this through **Friends**: a small relay on the project's server that lets two
installations of AVP Play find each other, exchange what they need, and hand the build over. The game's files never
travel this way: every friend's AVP Play copies them from that friend's own Meta purchase, as for any install.

What the server sees: who is friends with whom, and sealed messages and blobs it cannot read.

## Identities and friend codes

Every AVP Play installation makes two keys and keeps them in the keychain: a Curve25519 key for sealing messages to it
and an Ed25519 key for signing its requests. It registers the public halves once (`POST /api/v1/friends/register`
with a display name) and gets its **id** (the first 16 bytes of the SHA-256 of the signing key, hex) and a
**friend code** (8 characters, Crockford base32) to show in Settings › Friends.

Every later request carries `X-AVP-Friend: <id>`, `X-AVP-Ts: <unix seconds>`, `X-AVP-Body: <sha256 of the body,
hex>` (the hash of nothing for an empty body) and `X-AVP-Sig: <base64>`, the Ed25519 signature over
`<ts>\n<METHOD>\n<path>\n<body hash>` – the path without its query. The server verifies the signature against the
stored key, checks the body against the hash as it arrives (so a blob is signed without being held in memory first)
and rejects timestamps more than five minutes off.

Adding a friend: `POST /friends/requests {code}` creates a pending request; the other side sees it (event
`request`) and accepts (`POST /friends/requests/<id>/accept`) or declines (`DELETE`). A request in both directions
is a friendship at once. `GET /friends/me` returns the own record, the friends (id, name, sealing key, since) and the
open requests. `DELETE /friends/<id>` ends a friendship for both.

## Messages

`POST /friends/messages {to, kind, body}` stores a sealed message (at most 64 KiB) for a friend and pushes an event;
`GET /friends/messages?after=<seq>` lists what is stored, `POST /friends/messages/ack {upTo}` deletes it. Messages
older than 30 days go anyway.

Sealing (CryptoKit on the Mac; the server never opens one): an ephemeral Curve25519 key agrees with the recipient's
sealing key, HKDF-SHA256 (salt = the recipient's public key, info `avpplay-friends-v1`) derives a ChaChaPoly key,
and the body is `ephemeral public key (32) || nonce (12) || ciphertext || tag (16)`, base64. The sender is the
authenticated id; the recipient only decrypts messages from friends.

Kinds, as JSON once opened:

- `status` – what a friend needs to know to include you: `{ "app": "1.10.2", "games": { "walkabout": { "owned": true, "checked": <unix> } }, "device": { "udid": "…", "name": "…", "os": "26.1" }, "canShare": true }`. Sent at launch, when the paired headset or an ownership changes, and once a day. `canShare` is true for a paid team with a toolchain that can export.
- `offer` – a build for you: `{ "game": "walkabout", "blob": "<id>", "key": "<base64 32 bytes>", "sha256": "<of the plain .ipa>", "size": <bytes>, "bundleId": "…", "stamp": "<CFBundleVersion>", "appVersion": "6.8", "toolchain": 853, "spatialPersonas": true, "note": "…" }`.
- `result` – the answer: `{ "game": "walkabout", "blob": "<id>", "state": "installed" | "declined" | "failed", "detail": "…" }`.

## Blobs

`POST /friends/blobs` (raw body, up to 2 GiB) stores a sealed blob under a random id and answers `{ id, size,
expires }`; it is kept 14 days. `GET /friends/blobs/<id>` returns it to the owner and the owner's friends (supports ranges);
the owner may `DELETE` it. The blob is the .ipa sealed in 8 MiB chunks: a 16-byte header `AVPB` + version + chunk
size, then per chunk `ChaChaPoly.seal(chunk, key, nonce = chunk index)` as nonce (12) || ciphertext || tag (16).
The key and the SHA-256 of the plain file travel only in the `offer`.

## Events

`GET /friends/events` is a stream of Server-Sent Events (the same signed headers; one stream per identity, a newer
one replaces an older). The server sends `data: {"type": "hello"}`, then `{"type": "message", "seq": n}`,
`{"type": "request"}`, `{"type": "friend"}` as things happen, and `{"type": "ping"}` every 30 s. A client whose
stream drops reconnects with backoff and, in between, polls `GET /friends/me` and `GET /friends/messages`.

## The flow

**Sharing (a paid team):** on Walkabout's page, with Spatial Personas on, *Share with friends* lists the friends whose
last status says they own Walkabout and name a headset. For the chosen ones AVP Play

1. registers their headsets in your Apple developer account (App Store Connect API, with the key from Settings ›
   Friends; without a key it shows the UDIDs to enter by hand at developer.apple.com),
2. has the toolchain export an ad-hoc build (`visionos/run.sh export`, method `release-testing`, automatic signing,
   the Group Activities entitlement, your bundle identifier),
3. seals and uploads the .ipa and sends each friend an `offer`.

**Receiving:** the offer appears on the friend's Walkabout page. *Install* first asks Meta again whether this account
owns the game (the same check an install makes) and refuses otherwise, then downloads and opens the blob, checks the
SHA-256, installs the app with `devicectl` under the friend's bundle identifier, remembers that this game is now a
shared install (bundle identifier, stamp, from whom), and runs the usual steps for the files: fetch from the friend's
own purchase, copy to the device, unlock. The friend answers with a `result`. A later offer replaces the app the
same way; the files stay.

An ad-hoc build runs only on the headsets it was made for and for as long as its profile lasts (a year).

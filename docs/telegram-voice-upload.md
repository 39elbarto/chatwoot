# Telegram audio upload fix

Prepared on 2026-10-23 for LeviLaser; not deployed by this change.

## Behavior

Chatwoot previously sent all audio through `sendMediaGroup` with an external
ActiveStorage URL. Production message 41811 failed with Telegram's
`400 WEBPAGE_CURL_FAILED`. The same AAC bytes were accepted when uploaded as a
document. This proves that the original file is readable, but does not identify
the precise cause of Telegram's failed URL fetch.

The patch uploads audio bytes using multipart requests:

- MP3/M4A keep the audio-player presentation via `sendAudio`.
- Other recorded audio is converted by FFmpeg to mono 48 kHz OGG/Opus at
  32 kbit/s and sent via `sendVoice`.
- If conversion fails, FFmpeg is missing, or conversion exceeds 60 seconds,
  upload the original bytes via `sendDocument`.
- Telegram rejection or a network exception does not trigger document fallback:
  an ambiguous send must not automatically produce another delivery.
- Reply references and Telegram Business connection context are preserved.
- Source blobs remain unchanged. Conversion uses a unique temporary directory,
  removed on success and on error. Conversion cannot fetch network resources.
- The existing `SendOnTelegramService` records the returned Telegram message ID.
  This patch does not introduce global exactly-once delivery or change retry
  policy for partially delivered multi-attachment messages.

Photos/videos keep their existing media-group path. Documents retain their
existing upload path, with cleanup also performed on exceptions.

## Source and packaging

Base: `origin/levilaser/plain-canned-v4.16.1`, commit
`d814f897c81ad42a15cc9b5aa0fa565998a7a75f`.
Task branch: `fix/telegram-voice-upload`.

Application divergence is limited to:

- `app/services/telegram/send_attachments_service.rb`
- `app/services/telegram/send_audio_service.rb`

`docker/Dockerfile` adds FFmpeg for future full builds. For this backend-only
release, build `docker/Dockerfile.telegram-voice`: it overlays these two Ruby
files and FFmpeg on the exact deployed image, preserving frontend assets and
all previous LeviLaser customizations.

```bash
docker build -f docker/Dockerfile.telegram-voice \
  -t levilaser-chatwoot:telegram-voice-candidate .
```

## Validation

The candidate image was checked without a network and without sending external
messages. A standalone harness used the real service classes, Faraday file
parts, synthetic audio fixtures, and real FFmpeg, replacing only HTTP responses
and the Chatwoot model objects. It verified AAC/WebM/OGG conversion, MP3/M4A
upload, original-byte fallback, missing FFmpeg, conversion timeout, reply and
Business context, ID propagation, temporary-file cleanup, explicit Telegram
rejection, and ambiguous network failure. These are isolated checks, not a live
Telegram end-to-end test.

Pinned RuboCop 1.75.6 and the project plugin versions passed on both service
files and the updated attachment spec: three files, no offenses. The final
backend-only image built successfully; its local image ID is
`sha256:af86376d67f5e6437becf5720e3c1e9624d9ea5c2fe1ef6f6dff2bf378af8923`.
This local image ID is not a registry manifest digest.

Existing attachment RSpec expectations were updated for direct audio upload.
The Rails/RSpec suite was not run: the production-derived image excludes test
dependencies and no isolated Rails database was provisioned.

UBS was attempted but its Ruby analyzers reported an unsupported block
structure. Its run is partial, not a passing quality gate. Manual review
confirmed block-scoped file handles, block-scoped temporary directories, and
the existing JSON parse rescue. Use the project's pinned RuboCop versions for
Ruby lint; a newer RuboCop conflicts with its custom `OneClassPerFile` cop.

## Authorized rollout and rollback

Production remains unchanged until rollout approval, as required by the infra
deployment runbook. Before rollout, commit the task changes, agree a short
Chatwoot restart/test window, and confirm Docker root filesystem free space on
the actual deployment host. Publish a new, unused GHCR tag and record its digest;
do not overwrite the current tag. Pin both `chatwoot` and `worker` to the new
tag plus digest in the infra repository's task worktree. Preserve unrelated
changes in the deployed infra checkout, including its operations log.

Recreate only the application services, without migrations:

```bash
cd /opt/infra-core/infra/chatwoot
docker compose up -d --no-deps chatwoot worker
docker compose ps
docker logs --since 5m chatwoot-worker-1
```

Verify internal application health, worker startup and `ffmpeg -version` in the
worker. Agree the recipient and content of any live voice-message test; do not
reuse the customer's already delivered recording as a test. Check the returned
Telegram ID and Chatwoot `sent` status, then inspect worker logs for errors.

Rollback: restore both application image fields to the following preserved pin
and run the same scoped Compose command. No database rollback is needed.

```text
ghcr.io/39elbarto/levilaser-chatwoot:v4.16.1-plaincanned.1@sha256:1e16c1368d19ea96db57964ebedc56d17e486fc6dd088d5626c78914e373bc38
```

Keep this rollback image available through the observation window; avoid global
image pruning. Reapply the two-file patch and FFmpeg dependency when rebasing
the LeviLaser fork onto a future upstream release, unless upstream already
provides equivalent behavior.

# Telegram remote deletion

Observable behavior: deleting a sent outgoing Telegram message in Chatwoot
first removes its remote copy. On an explicit Telegram 400 rejection, a text
message is replaced in place with `Сообщение удалено`. Only then is the local
content replaced with the usual tombstone. Errors preserve the local content
and return HTTP 422, which the existing dashboard shows as a deletion failure.

## Scope and configuration

- Base is the source of deployed `v4.16.1-plaincanned.2`, including voice fix.
- `TELEGRAM_REMOTE_DELETE_ENABLED=true` enables the feature. Default: disabled.
- Optional `TELEGRAM_REMOTE_DELETE_CONVERSATIONS=1:28` limits it to account 1,
  display conversation 28. Empty/unset means all conversations when enabled.
- Private notes, incoming messages and other channels keep local-only deletion.
- Sent text messages and single attachments without separate text are covered.
- Legacy albums and attachment-plus-text messages have incomplete Telegram IDs;
  deletion is refused without erasing the local message. Business connections
  and pending/failed outgoing messages are also refused in this first release.
- A single attachment may be deleted, but cannot fall back to text redaction.
- Telegram's normal remote-deletion limit is less than 48 hours. Redaction may
  still work for older text messages sent by this bot.
- Network failures, rate limits and permission errors do not trigger fallback.
  No automatic retries or scans of historical messages are introduced.
- `content_attributes.telegram_removal` records `deleted`/`redacted`, Telegram
  message ID and UTC completion time. It stores no token or original text.
- Existing local tombstones are not retroactively synchronized.
- Read notifications/screenshots and previously read text cannot be recalled.

## Packaging and tests

`docker/Dockerfile.telegram-delete` overlays only the controller and new
`Telegram::RemoveMessageService` on the immutable production image. No frontend
rebuild, database migration or queue change is needed. Both application services
must use the new image. Preserve the existing image as the rollback target.

Run `script/telegram_delete_harness.rb` under Bundler in a Chatwoot image with
`--network none`. It loads the actual service and controller, stubs HTTP and
model objects, and verifies remote success before local erasure, text fallback,
failure preservation, bounded HTTP options, idempotency and scope exclusions.
This is an isolated harness, not the complete Rails request suite.

Validation on 2026-11-07: all 22 isolated checks passed, including execution in
the actual candidate image; Ruby syntax checks passed for both application
files. UBS 5.5.26 was run on the three changed Ruby files but exited 2 (partial):
its Ruby taint analyzer cannot bind rest/block arguments or Rails instance
state. Its sole warning is a false positive on backticks in an existing comment.
This is not a passing UBS gate. The Rails/RSpec request suite and RuboCop are
unavailable in the production image (test/lint dependencies excluded).

First live test is owner-approved account 1, conversation #28, @AK1477.
Send only synthetic text, wait for `status=sent` and Telegram `source_id`, then
call the same Chatwoot DELETE endpoint used by the dashboard. Inspect the
remote-success receipt, HTTP response and local tombstone, and obtain visual
confirmation from the owner. Never test on a customer conversation.

## Deployment and rollback

Build and publish a new unused GHCR tag. Pin the registry digest for both web
and worker in the infra task checkout. Preserve remote unrelated dirty work;
change only the two image references and feature configuration. Before rollout,
agree the brief application restart/test window, check Docker root capacity and
prepare a protected recovery copy of the live Compose file. Recreate only web
and worker, without migrations or data-service restarts.

Rollback: restore the prior application image pin and remove the feature env
overrides, then recreate only web and worker. Previous image:

`ghcr.io/39elbarto/levilaser-chatwoot:v4.16.1-plaincanned.2@sha256:ad09780d350191f01ab3232d68b8d836462f8f58327dcef765f08079c97b0ba9`

Remote deletion/redaction already confirmed by Telegram cannot be undone by
rolling back the application. No DB rollback is required.

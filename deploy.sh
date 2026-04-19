#!/bin/bash
# Deploy the latest mos15 build to the docker host.
#
# Per HANDOFF: stop VM before pushing — QEMU writes to the image while
# running (boot logs, NVRAM). Pushing into a running container = corruption.
#
# Layout on host (after first run):
#   /data/macos/builds/mos15_YYYYMMDDHHMMSS.img    each deployed build, full history
#   /data/macos/mos15.img -> builds/<active>       symlink the container bind-mounts
#
# Sequence: stop container -> scp build to host builds/ -> retarget symlink -> start.

set -euo pipefail

cd "$(dirname "$0")"

HOST="${DEPLOY_HOST:-docker}"
CONTAINER="${DEPLOY_CONTAINER:-macos-macos-1}"
REMOTE_DIR="${DEPLOY_REMOTE_DIR:-/data/macos}"
LATEST="mos15.img"

[ -L "$LATEST" ] || { echo "$LATEST symlink missing — run ./build-mos15-img.sh first"; exit 1; }
TARGET=$(readlink "$LATEST")  # builds/mos15_YYYYMMDDHHMMSS.img
NAME=$(basename "$TARGET")

echo "==> Deploying $NAME to $HOST:$REMOTE_DIR/builds/"
echo "==> Stopping $CONTAINER"
ssh "$HOST" "sudo docker stop $CONTAINER" >/dev/null

echo "==> Pushing"
ssh "$HOST" "sudo mkdir -p $REMOTE_DIR/builds && sudo chown matthew:matthew $REMOTE_DIR/builds"
scp "$TARGET" "$HOST:$REMOTE_DIR/builds/$NAME"

echo "==> Verifying checksum"
LOCAL=$(md5 -q "$TARGET")
REMOTE=$(ssh "$HOST" "md5sum $REMOTE_DIR/builds/$NAME | awk '{print \$1}'")
[ "$LOCAL" = "$REMOTE" ] || { echo "checksum mismatch! local=$LOCAL remote=$REMOTE"; exit 1; }
echo "    md5: $LOCAL"

echo "==> Retargeting $REMOTE_DIR/mos15.img -> builds/$NAME"
# Bind mount currently points at /data/macos/opencore15.img. Until Portainer is
# updated, replace that with a symlink so the container reads the active build.
ssh "$HOST" "sudo ln -sfn $REMOTE_DIR/builds/$NAME $REMOTE_DIR/mos15.img && \
             sudo ln -sfn $REMOTE_DIR/builds/$NAME $REMOTE_DIR/opencore15.img"

echo "==> Starting $CONTAINER"
ssh "$HOST" "sudo docker start $CONTAINER" >/dev/null

echo
echo "Deployed $NAME. Watch boot:"
echo "  ssh $HOST 'sudo docker logs -f $CONTAINER'"
echo "Run 20-boot test:"
echo "  ./kexts/QEMUDisplayPatcher/test-20.sh"

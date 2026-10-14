#!/usr/bin/env bash
#
# entrypoint.sh — Prepare the lab container before handing over to the shell.
#
# Starts dockerd when nothing else did (no systemd in the container) and raises
# the inotify limits multi-node kind clusters need. Both require --privileged.
#
set -euo pipefail

# kind runs every node as a container; each kubelet/containerd consumes inotify
# watches. Low limits leave pods stuck in ContainerCreating or CrashLoopBackOff.
sysctl -qw fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512 2>/dev/null \
  || echo "[!] could not raise inotify limits (not privileged?)" >&2

# cgroup v2 nesting (same as moby's hack/dind): controllers can only be handed
# down to child cgroups once no process lives in the root one. Without this the
# memory controller never reaches dockerd's containers and kind nodes exit
# before systemd boots ("could not find a log line ... Multi-User System").
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
  mkdir -p /sys/fs/cgroup/init
  xargs -rn1 < /sys/fs/cgroup/cgroup.procs > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || :
  sed -e 's/ / +/g' -e 's/^/+/' < /sys/fs/cgroup/cgroup.controllers \
    > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null \
    || echo "[!] could not enable cgroup v2 controllers (not privileged?)" >&2
fi

if ! docker info >/dev/null 2>&1; then
  dockerd >/var/log/dockerd.log 2>&1 &
  for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done
  docker info >/dev/null 2>&1 \
    || echo "[!] dockerd did not start, see /var/log/dockerd.log (not privileged?)" >&2
fi

exec "$@"

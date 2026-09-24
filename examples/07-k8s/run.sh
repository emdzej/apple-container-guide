#!/usr/bin/env bash
# Local single-node Kubernetes on Apple container, with a locally built image.
#
# `container k8s` is EXPERIMENTAL and ships as a plugin, so availability depends
# on your install. It also only resolves when the CLI and the running apiserver
# come from the SAME install root - if you have both a Homebrew keg and the
# official .pkg, the plugin will report "not found" even though the binary is on
# disk. ../../scripts/doctor.sh detects that.
set -euo pipefail
CLUSTER=${CLUSTER:-k8s-dev}

container system status >/dev/null 2>&1 || container system start

if ! container k8s list >/dev/null 2>&1; then
  cat <<'MSG'
`container k8s` is not available in this install.

Check which install root the daemon is using, and whether it has the plugin:

    container system status | grep installRoot
    ls "$(container system status | awk '$1=="paths.installRoot"{print $2}')libexec/container-plugins" 2>/dev/null
    ls "$(brew --prefix container 2>/dev/null)/libexec/container-plugins" 2>/dev/null

If the plugin exists under the Homebrew keg but the daemon is running from
/usr/local (or vice versa), that mismatch is the cause. Stop the services, remove
one install, start again:

    container system stop
    sudo /usr/local/bin/uninstall-container.sh -k    # -k keeps your images/volumes
    container system start

Alternatives that work regardless: kind or k3d driven through socktainer's Docker
API, or minikube with the docker driver.
MSG
  exit 1
fi

echo "==> create cluster '$CLUSTER'"
# Defaults are 1/4 of host CPUs (min 2) and 1/4 of host RAM (min 2 GB). Since the
# control plane is a single VM, give it real resources if you plan to run anything.
container k8s create --name "$CLUSTER" --cpus 4 --memory 8g

echo "==> the context is written to ~/.kube/config automatically"
kubectl --context "$CLUSTER" get nodes
container k8s list

echo
echo "==> build an image locally and load it - no registry involved"
cd "$(dirname "$0")/../01-hello"
container build --tag k8s-demo:local --file Dockerfile .
container k8s load-image --name "$CLUSTER" k8s-demo:local

cat > /tmp/k8s-demo-pod.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: k8s-demo
spec:
  restartPolicy: Never
  containers:
    - name: app
      image: k8s-demo:local
      # Required: the image was loaded into the node's containerd directly and
      # does not exist in any registry. Without this the kubelet tries to pull.
      imagePullPolicy: Never
YAML

kubectl --context "$CLUSTER" apply -f /tmp/k8s-demo-pod.yaml
kubectl --context "$CLUSTER" wait --for=condition=Ready pod/k8s-demo --timeout=90s || true
kubectl --context "$CLUSTER" logs k8s-demo

cat <<NOTE

Notes for container 1.4.1:
  - subcommands: create, delete, list, load-image, start, write-config
  - node image defaults to a pinned docker.io/kindest/node:v1.35.5 digest;
    override with --node-image for a different Kubernetes version
  - --cni (custom CNI manifest) is documented on main but not present in 1.4.1;
    the bundled kindnet is what you get
  - multiple clusters coexist: container k8s create --name staging
  - if the control-plane container stops, delete and recreate - there is no resume
  - write-config puts the context in an alternate kubeconfig:
      container k8s write-config --name $CLUSTER --kubeconfig ~/.kube/$CLUSTER.kubeconfig

cleanup:  container k8s delete --name $CLUSTER
NOTE

#!/usr/bin/env bash
#
# Reproducible native linux/s390x build of cilium-envoy (Envoy 1.36.6 + Cilium).
# Runs on a native s390x host/runner. Produces /usr/bin/cilium-envoy,
# /usr/bin/cilium-envoy-starter and /usr/lib/libcilium.so under $OUT/install,
# then builds and (optionally) pushes a container image.
#
# Why this is not the upstream Dockerfile.builder path:
#  - No official Bazel / bazelisk binary exists for s390x → we bootstrap Bazel
#    7.7.1 from the source dist zip.
#  - OpenJDK's C2 JIT segfaults on s390x during the Bazel build → force C1 only.
#  - clang-18's SystemZ backend crashes on int128 __builtin_mul_overflow → clang-19.
#  - BoringSSL/quiche carry big-endian patches (wired via WORKSPACE patches 0007/0008).
#
set -euxo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BAZEL_VERSION="${BAZEL_VERSION:-7.7.1}"
# Fixed path (apt installs openjdk-21-jdk here on s390x). Do not `ls` — that would
# fail under `set -e` before install_deps has a chance to install the JDK.
JDK_HOME="${JDK_HOME:-/usr/lib/jvm/java-21-openjdk-s390x}"
# Empty when running as root (e.g. inside a build container); "sudo" otherwise.
SUDO="${SUDO-$([ "$(id -u)" = 0 ] && echo "" || echo sudo)}"
# When true, package() builds+pushes the image itself (direct-on-host mode).
# In container-build mode the workflow packages from $OUT/install instead.
DOCKER_PACKAGE="${DOCKER_PACKAGE:-false}"
# Required cilium-envoy version SHA the cilium agent checks against (v1.19.4).
ENVOY_SHA="${ENVOY_SHA:-b87d1e32f522b33bd51701c6476d199326f01496}"
IMAGE="${IMAGE:-ghcr.io/dnse-tech/cilium-envoy}"
IMAGE_TAG="${IMAGE_TAG:-v1.36.6-1778235340-${ENVOY_SHA}-s390x}"
PUSH="${PUSH:-false}"
JOBS="${JOBS:-4}"

# --- 1. Toolchain prerequisites (idempotent) -------------------------------
install_deps() {
  # Skip apt entirely when the toolchain is already present (e.g. a runner that
  # shares a pre-provisioned host). Avoids needing passwordless sudo.
  if command -v clang-19 >/dev/null && command -v lld-19 >/dev/null \
     && [ -e /usr/lib/llvm-19/lib/libc++.a ] && [ -d "$JDK_HOME" ] \
     && command -v go >/dev/null; then
    echo "Toolchain already present; skipping apt."
  else
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq \
    ca-certificates curl git wget zip unzip patch patchelf \
    autoconf automake cmake coreutils libtool make ninja-build \
    python3 python-is-python3 virtualenv \
    libatomic1 gcc g++ \
    openjdk-21-jdk
  # LLVM 19 (clang-18 SystemZ backend bug); apt.llvm.org
  wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | $SUDO tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc >/dev/null
  $SUDO apt-add-repository -y "deb http://apt.llvm.org/noble/ llvm-toolchain-noble-19 main"
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq \
    clang-19 lld-19 llvm-19 llvm-19-dev clang-tools-19 \
    libc++-19-dev libc++abi-19-dev
  # Unversioned symlinks expected by bazel/toolchains/BUILD (s390x cc_toolchain).
  local p
  for p in clang:clang-19 clang++:clang++-19 clang-cpp:clang-cpp-19 \
           lld:lld-19 ld.lld:ld.lld-19 llvm-ar:llvm-ar-19 llvm-nm:llvm-nm-19 \
           llvm-strip:llvm-strip-19 llvm-objcopy:llvm-objcopy-19 \
           llvm-objdump:llvm-objdump-19 llvm-dwp:llvm-dwp-19 \
           llvm-cov:llvm-cov-19 llvm-config:llvm-config-19; do
    [ -e "/usr/bin/${p##*:}" ] && $SUDO ln -sf "/usr/bin/${p##*:}" "/usr/bin/${p%%:*}"
  done
  fi
}

# --- 2. Bootstrap Bazel 7.7.1 for s390x ------------------------------------
bootstrap_bazel() {
  if [ -x "$HOME/bin/bazel" ] && "$HOME/bin/bazel" version 2>/dev/null | grep -q "$BAZEL_VERSION"; then
    return
  fi
  export JAVA_HOME="$JDK_HOME" PATH="$JDK_HOME/bin:$PATH"
  # C1-only avoids the s390x C2 JIT segfault. bazel strips JAVA_TOOL_OPTIONS from
  # its server, so we also patch the phase-1 java line and set the phase-2 server
  # startup args. BAZEL_DEV_VERSION_OVERRIDE fixes bazel_features' "macro" error
  # (scratch bazel reports an empty native.bazel_version otherwise).
  export JAVA_TOOL_OPTIONS="-XX:TieredStopAtLevel=1"
  export BAZEL_DIR_STARTUP_OPTIONS="--host_jvm_args=-XX:TieredStopAtLevel=1"
  export EMBED_LABEL="$BAZEL_VERSION" BAZEL_DEV_VERSION_OVERRIDE="$BAZEL_VERSION"
  local work="$HOME/bazel-build"
  mkdir -p "$work" && cd "$work"
  [ -f "bazel-$BAZEL_VERSION-dist.zip" ] || \
    curl -sfL "https://github.com/bazelbuild/bazel/releases/download/$BAZEL_VERSION/bazel-$BAZEL_VERSION-dist.zip" \
      -o "bazel-$BAZEL_VERSION-dist.zip"
  rm -rf src && mkdir src && cd src
  unzip -q "../bazel-$BAZEL_VERSION-dist.zip"
  sed -i 's|      -XX:+HeapDumpOnOutOfMemoryError -Xverify:none|      -XX:TieredStopAtLevel=1 -XX:+HeapDumpOnOutOfMemoryError -Xverify:none|' \
    scripts/bootstrap/compile.sh
  EXTRA_BAZEL_ARGS="--tool_java_runtime_version=local_jdk --java_runtime_version=local_jdk" \
    BAZEL_JAVAC_OPTS="-J-Xmx3g" bash ./compile.sh
  mkdir -p "$HOME/bin" && cp output/bazel "$HOME/bin/bazel"
}

# --- 3. Build the binaries -------------------------------------------------
build() {
  export JAVA_HOME="$JDK_HOME" PATH="$JDK_HOME/bin:$HOME/bin:$PATH"
  export BAZEL_DEV_VERSION_OVERRIDE="$BAZEL_VERSION"
  cd "$REPO_ROOT"
  # Distribution build path: report the pinned envoy SHA regardless of git state.
  echo "$ENVOY_SHA" > SOURCE_VERSION
  # Resource/JIT tuning, auto try-imported by envoy.bazelrc.
  cat > user.bazelrc <<EOF
startup --host_jvm_args=-XX:TieredStopAtLevel=1
build --jobs=${JOBS}
build --disk_cache=${HOME}/.cache/cilium-envoy-bazel
build --verbose_failures
# clang-19 -Wnullability-completeness fires on Google libs (cel-cpp) lacking full
# annotations, and envoy builds -Werror. Not an s390x issue; suppress.
build --copt=-Wno-nullability-completeness
EOF
  # libcilium.so (Go c-shared)
  GOARCH=s390x make -C proxylib all
  # cilium-envoy + starter (Bazel). PKG_BUILD=1 registers the s390x toolchain and
  # assumes bazel+clang present; ARCH=s390x selects //bazel:linux_s390x + release.
  make PKG_BUILD=1 ARCH=s390x V="${V:-0}" \
    bazel-bin/cilium-envoy-starter bazel-bin/cilium-envoy
}

# --- 4. Package + optional push --------------------------------------------
package() {
  cd "$REPO_ROOT"
  local out="${OUT:-$REPO_ROOT/out-s390x}"
  rm -rf "$out" && mkdir -p "$out/install/usr/bin" "$out/install/usr/lib"
  cp bazel-bin/cilium-envoy            "$out/install/usr/bin/cilium-envoy"
  cp bazel-bin/cilium-envoy-starter    "$out/install/usr/bin/cilium-envoy-starter"
  cp proxylib/libcilium.so             "$out/install/usr/lib/libcilium.so"
  chmod +x "$out/install/usr/bin/"*
  cat > "$out/Dockerfile" <<'EOF'
FROM docker.io/library/ubuntu:24.04
LABEL maintainer="maintainer@dnse-tech"
RUN apt-get update && apt-get upgrade -y \
    && apt-get install --no-install-recommends -y ca-certificates libatomic1 \
    && apt-get autoremove -y && apt-get clean \
    && rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/*
COPY install /
EOF
  # Verify the freshly built binary reports the required SHA (runs even when the
  # image is packaged later by the workflow).
  ./bazel-bin/cilium-envoy --version | grep -q "$ENVOY_SHA"
  echo "OK: cilium-envoy reports required SHA $ENVOY_SHA; staged at $out"
  # Direct-on-host packaging (needs docker). In container-build mode the workflow
  # runs `docker build $out` + push on the runner instead.
  if [ "$DOCKER_PACKAGE" = "true" ]; then
    docker build -t "$IMAGE:$IMAGE_TAG" "$out"
    docker run --rm "$IMAGE:$IMAGE_TAG" cilium-envoy --version | grep -q "$ENVOY_SHA"
    [ "$PUSH" = "true" ] && docker push "$IMAGE:$IMAGE_TAG"
  fi
}

install_deps
bootstrap_bazel
build
package

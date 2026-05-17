ARG DISTRO_VERSION="13"
FROM docker.io/library/debian:${DISTRO_VERSION}

# --- Build deps (mirrors src/build/docker/debian/Dockerfile) -----------------
RUN DEBIAN_FRONTEND="noninteractive" apt-get -qq update && \
    apt-get -qq -y --no-install-recommends install \
        blueprint-compiler \
        build-essential \
        curl \
        ca-certificates \
        gettext \
        libbz2-dev \
        libonig-dev \
        libxml2-utils \
        lsb-release \
        pandoc \
        libadwaita-1-dev \
        libgtk-4-dev \
        libgtk4-layer-shell-dev \
        # --- Display/VNC bits ---
        xvfb \
        x11vnc \
        fluxbox \
        xterm \
        dbus-x11 \
        fonts-dejavu-core \
        adwaita-icon-theme \
        hicolor-icon-theme && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY ./build.zig ./build.zig.zon /src/

# Pin Zig to the version build.zig.zon expects (parsed from minimum_zig_version)
RUN export ZIG_VERSION=$(sed -n -E 's/^\s*\.?minimum_zig_version\s*=\s*"([^"]+)".*/\1/p' build.zig.zon) && \
    curl -L -o /tmp/zig.tar.xz "https://ziglang.org/download/$ZIG_VERSION/zig-$(uname -m)-linux-$ZIG_VERSION.tar.xz" && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    rm /tmp/zig.tar.xz && \
    ln -s "/opt/zig-$(uname -m)-linux-$ZIG_VERSION/zig" /usr/local/bin/zig

COPY . /src

RUN zig build -Doptimize=ReleaseFast -Dcpu=baseline

# --- Runtime: Xvfb + fluxbox + x11vnc, then ghostty --------------------------
ENV DISPLAY=:99
ENV GHOSTTY_BIN=/src/zig-out/bin/ghostty
# Disable GPU/GLES on Xvfb (no GL acceleration)
ENV LIBGL_ALWAYS_SOFTWARE=1
ENV GDK_GL=disable
# x11vnc password is "ghostty" — VNC is localhost-only, but a password keeps
# random scanners on the host network from connecting if you forward the port.
EXPOSE 5900

RUN printf '%s\n' \
    '#!/bin/sh' \
    'set -e' \
    'rm -f /tmp/.X99-lock /tmp/.X11-unix/X99' \
    'Xvfb :99 -screen 0 1600x1000x24 +extension RANDR &' \
    'sleep 0.5' \
    'fluxbox >/tmp/fluxbox.log 2>&1 &' \
    'sleep 0.3' \
    'x11vnc -display :99 -forever -shared -nopw -rfbport 5900 -bg -o /tmp/x11vnc.log' \
    'exec "$GHOSTTY_BIN" "$@"' \
    > /usr/local/bin/run-ghostty.sh && chmod +x /usr/local/bin/run-ghostty.sh

CMD ["/usr/local/bin/run-ghostty.sh"]

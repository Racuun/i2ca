FROM ubuntu:24.04

LABEL description="Development environment for i2ca (Introduction to Computer Architecture)"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Install foundational utilities, build tools, Java runtime, Icarus Verilog, and Python
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    make \
    git \
    curl \
    wget \
    ca-certificates \
    sudo \
    locales \
    nano \
    tree \
    unzip \
    # Java Runtime for Digital logic simulator
    openjdk-21-jre \
    # Icarus Verilog for Digital external Verilog simulation and syntax checks
    iverilog \
    # GNU toolchain for RISC-V bare-metal development
    gcc-riscv64-unknown-elf \
    binutils-riscv64-unknown-elf \
    picolibc-riscv64-unknown-elf \
    # Python environment and serial drivers for flash_rv32.py
    python3 \
    python3-pip \
    python3-serial \
    python3-venv \
    # X11 & GUI libraries to enable Digital GUI rendering over X11 / Wayland forwarding
    libxext6 \
    libxrender1 \
    libxtst6 \
    libxi6 \
    libxrandr2 \
    libgl1 \
    libfreetype6 \
    fonts-dejavu \
    x11-apps \
    && rm -rf /var/lib/apt/lists/*

# Create riscv32-unknown-elf-* symlinks pointing to 64-bit multi-arch tools
RUN for tool in gcc as ld ar objcopy objdump size readelf; do \
        if [ -f /usr/bin/riscv64-unknown-elf-$tool ]; then \
            ln -s /usr/bin/riscv64-unknown-elf-$tool /usr/local/bin/riscv32-unknown-elf-$tool; \
        fi \
    done

# Install Digital logic simulator (H. Neemann)
ARG DIGITAL_VERSION=v0.31
RUN mkdir -p /opt/digital /tmp/digital_download && \
    (curl -fsSL "https://github.com/hneemann/Digital/releases/download/${DIGITAL_VERSION}/Digital.zip" -o /tmp/digital_download/Digital.zip || \
     curl -fsSL "https://github.com/hneemann/Digital/releases/latest/download/Digital.zip" -o /tmp/digital_download/Digital.zip) && \
    unzip -q /tmp/digital_download/Digital.zip "Digital/Digital.jar" -d /tmp/digital_download && \
    mv /tmp/digital_download/Digital/Digital.jar /opt/digital/Digital.jar && \
    rm -rf /tmp/digital_download

# Create system-wide launcher script 'digital'
RUN printf '#!/bin/sh\nexec java -jar /opt/digital/Digital.jar "$@"\n' > /usr/local/bin/digital && \
    chmod +x /usr/local/bin/digital

# Setup non-root student user (UID 1000) with passwordless sudo and dialout group for UART flashing
ARG USERNAME=student
ARG USER_UID=1000
ARG USER_GID=1000

RUN if getent passwd $USER_UID >/dev/null; then \
        EXISTING_USER=$(getent passwd $USER_UID | cut -d: -f1); \
        userdel -r $EXISTING_USER 2>/dev/null || true; \
    fi && \
    if getent group $USER_GID >/dev/null; then \
        EXISTING_GRP=$(getent group $USER_GID | cut -d: -f1); \
        groupdel $EXISTING_GRP 2>/dev/null || true; \
    fi && \
    groupadd --gid $USER_GID $USERNAME && \
    useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $USERNAME && \
    usermod -aG sudo,dialout $USERNAME && \
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/$USERNAME && \
    chmod 0440 /etc/sudoers.d/$USERNAME

USER $USERNAME
WORKDIR /workspace

CMD ["/bin/bash"]

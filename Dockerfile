
# syntax=docker/dockerfile:1
ARG RUNNER_VERSION=latest
ARG BASE_IMAGE=ghcr.io/actions/actions-runner:${RUNNER_VERSION}
ARG AGENT_TOOLSDIRECTORY=/tools

####################################################################
# Base CodeQL image (Java, Node, Python 3)
####################################################################

FROM ${BASE_IMAGE} AS tools
ARG AGENT_TOOLSDIRECTORY
ENV AGENT_TOOLSDIRECTORY=${AGENT_TOOLSDIRECTORY}
USER root
RUN << EOF bash 
  set -euxo pipefail
  apt-get update
  apt-get install -qqq -y wget lsb-release unzip
  git clone --sparse --filter=blob:none --depth 1 https://github.com/actions/runner-images
  pushd runner-images
  git sparse-checkout add images/ubuntu
  cd images/ubuntu
  
  export DEBIAN_FRONTEND=noninteractive
  export HELPER_SCRIPTS=\${PWD}/scripts/helpers
  export INSTALLER_SCRIPT_FOLDER=\${PWD}/toolsets

  mkdir -p "${AGENT_TOOLSDIRECTORY}"
  cp "\${INSTALLER_SCRIPT_FOLDER}/toolset-2404.json" "\${INSTALLER_SCRIPT_FOLDER}/toolset.json"
  find "\${PWD}/scripts" -type f -name "*.sh" -exec chmod +x {} \;
  
  echo "#!/bin/bash" > /usr/local/bin/invoke_tests && chmod +x /usr/local/bin/invoke_tests
  cp /etc/sudoers /etc/sudoers.bak
  echo 'root ALL=(ALL) ALL' >> /etc/sudoers
  
  ./scripts/build/install-java-tools.sh
  ./scripts/build/install-codeql-bundle.sh
  ./scripts/build/install-nodejs.sh

  mv -f /etc/sudoers.bak /etc/sudoers
  rm /usr/local/bin/invoke_tests 

  chown -R runner:docker "${AGENT_TOOLSDIRECTORY}"
  popd
  rm -rf runner-images
  rm -rf /var/lib/apt/lists/* 
  rm -rf /tmp/*
EOF
USER runner

####################################################################
# Python 2 Binaries
####################################################################

FROM ${BASE_IMAGE} AS python2
ENV PYTHON_VERSION=2.7.18
ENV DEBIAN_FRONTEND=noninteractive
USER root
RUN  <<EOF
  apt-get update
  apt-get install -qqq -y wget build-essential checkinstall libncursesw5-dev libssl-dev libsqlite3-dev tk-dev libgdbm-dev libc6-dev libbz2-dev libreadline-dev libnss3-dev libffi-dev zlib1g-dev
  
  rm -rf /usr/local/lib/*
  
  wget -O python2.tgz https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz
  tar -xvf python2.tgz
  
  cd Python-${PYTHON_VERSION}
  ./configure 
  # ./configure --enable-optimizations
  make -j`nproc` all install
  
  wget -O get-pip.py https://bootstrap.pypa.io/pip/2.7/get-pip.py
  python2 get-pip.py
  
  tar czf /python2.tgz /usr/local/bin/ /usr/local/lib
EOF

####################################################################
# Final composite image
####################################################################

FROM tools
USER runner
RUN --mount=type=bind,from=python2,source=/python2.tgz,target=/tmp/python2.tgz \
	sudo tar -xvf /tmp/python2.tgz -C /

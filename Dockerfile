# syntax=docker/dockerfile:1

## Settings that we can change at build time, including the base image
## You can provide either a specific version or a completely different base image.
ARG RUNNER_VERSION=latest
ARG BASE_IMAGE=ghcr.io/actions/actions-runner:${RUNNER_VERSION}
ARG AGENT_TOOLSDIRECTORY=/tools

####################################################################
# Base CodeQL image (Java, Node, Python 3)
####################################################################

## First stage of the build will create an updated base image.
FROM ${BASE_IMAGE} AS tools

## Allow this variable to be set as part of this stage
ARG AGENT_TOOLSDIRECTORY

## Configure the environment variable for the tools directory
## so the runner can use it (and more importantly, because
## the scripts expect it to be set to know where to install the tools).
ENV AGENT_TOOLSDIRECTORY=${AGENT_TOOLSDIRECTORY}

## Change to the root user to install the tools (base image is using `runner`)
USER root

## Use the heredoc syntax to run a series of commands using the Bash shell
## instead of the default `sh` shell. The script ends when a line with just
## EOF is encountered. By doing a lot of steps inside a single RUN command,
## it creates a single layer with the final layout instead of multiple
## layers representing diffs between each command.
RUN << EOF bash
  ## Configure the Bash error handling
  set -euxo pipefail
 
  ## Update the package list so that we can install some packages
  apt-get update

  ## Quietly install the prerequisites we need to run the scripts
  apt-get install -qqq -y wget lsb-release unzip

  ## Clone the repository. The repository is 19M, I like small and fast!
  ## As a blobless clone, it just downloads the list of files and directories
  ## (trees), reducing the size of the clone to 8.4M. Since it is also
  ## a shallow clone (depth 1), it only downloads the latest commit -- 332K.
  ## By making it sparse, I only download the blobs for files in the root
  ## directory, `images`, and `images/ubuntu` (three "cone"). The final size
  ## is about 1.2M, or less than 10% of the original repository size!
  git clone --sparse --filter=blob:none --depth 1 https://github.com/actions/runner-images
  
  ## Move into the repository directory, but remember where we are for later.
  pushd runner-images

  ## Perform a sparse checkout. This will cause the blobs for the "cone"
  ## `images/ubuntu` to be downloaded and placed in the working directory.
  ## You will now have all of the directories and files below `images/ubuntu`
  ## (plus the files -- but not the directories -- from `images`)
  git sparse-checkout add images/ubuntu
  
  ## Move into the `images/ubuntu` directory to set everything else up.
  ## I'm not using pushd because I won't need to return back to the parent
  cd images/ubuntu
  
  ## Set some environment variables for the script. AGENT_TOOLSDIRECTORY
  ## is already set for the image. These just need to be set for this script.
  ## Because Docker tries to populate any variables in the RUN command,
  ## I use a slash to escape the dollar sign. That gets removed when
  ## the script is executed. For example ${AGENT_TOOLSDIRECTORY} is
  ## interpreted by Docker and populated before the script is run, but
  ## \${INSTALLER_SCRIPT_FOLDER} is converted to ${INSTALLER_SCRIPT_FOLDER}
  ## when the final script is executed inside the container.
  ## I want ${PWD} to be interpreted by the script (not Docker), so I
  ## escape it as well.
  export DEBIAN_FRONTEND=noninteractive
  export HELPER_SCRIPTS=\${PWD}/scripts/helpers
  export INSTALLER_SCRIPT_FOLDER=\${PWD}/toolsets

  ## The directory is expected to exist
  mkdir -p "${AGENT_TOOLSDIRECTORY}"

  ## Create the toolset file that the scripts will use
  cp "\${INSTALLER_SCRIPT_FOLDER}/toolset-2404.json" "\${INSTALLER_SCRIPT_FOLDER}/toolset.json"
  
  ## And make sure all of the .sh scripts are executable, since many 
  ## are missing that bit in the repository
  find "\${PWD}/scripts" -type f -name "*.sh" -exec chmod +x {} \;
  
  ## Instead of setting up PowerShell and making sure we can run the test
  ## scripts, I will create an empty script so that nothing breaks
  ## when the command is called
  echo "#!/bin/bash" > /usr/local/bin/invoke_tests
  chmod +x /usr/local/bin/invoke_tests
 
  ## Root use needs to be able to run sudo, but I want to leave the
  ## sudoers file like I found it. So, I will back it up, then
  ## add the line that allows `root` to run `sudo
  cp /etc/sudoers /etc/sudoers.bak
  echo 'root ALL=(ALL) ALL' >> /etc/sudoers

  ## FINALLY! We can now run the scripts to install the tools!

  ## Configure Java and set it up in the tool cache (lots of symlinks!)
  ./scripts/build/install-java-tools.sh

  ## Install and configure the latest version of CodeQL (huge!)
  ./scripts/build/install-codeql-bundle.sh

  ## Install Node.js. This one is not being installed in the tool cache.
  ## so you might consider doing that yourself using the logic in
  ## the `actions/setup-node` Action.
  ./scripts/build/install-nodejs.sh

  ## Wait! What? No Python? I'll explain in a bit ...

  ## Restore the sudoers file back to its original state
  mv -f /etc/sudoers.bak /etc/sudoers
 
  ## And remove invoke_tests, since it doesn't need to remain in the image.
  rm /usr/local/bin/invoke_tests 

  ## Update the permissions on the tools directory so that the
  ## default user, `runner`, can access it.
  chown -R runner:docker "${AGENT_TOOLSDIRECTORY}"

  ## Return back to the parent directory so we can also remove
  ## the entire Git repository.
  popd
  rm -rf runner-images

  ## Finally, clean up the package cache and temporary files.
  rm -rf /var/lib/apt/lists/* 
  rm -rf /tmp/*
EOF

## And now we can return the image to using the `runner` user.
USER runner

####################################################################
# Python 2 Binaries
####################################################################

## Use the same base image as before. Not required, but it means there
## are fewer layers to download.
FROM ${BASE_IMAGE} AS python2

## Set the Python version to install
ENV PYTHON_VERSION=2.7.18

## And run this image as root without interactive prompts
ENV DEBIAN_FRONTEND=noninteractive
USER root

## We'll use the heredoc again. It saves us from importing a separate 
## script file as a layer and it keeps you from needing to use lots of
## line separators and `&&` to chain commands together.
RUN  <<EOF
  ## Update the package list and install the required packages for building the code
  apt-get update
  apt-get install -qqq -y wget build-essential checkinstall libncursesw5-dev libssl-dev libsqlite3-dev tk-dev libgdbm-dev libc6-dev libbz2-dev libreadline-dev libnss3-dev libffi-dev zlib1g-dev

  ## The base image already has a few things installed that you can remove
  ## to make the final step in this process a bit easier.
  rm -rf /usr/local/lib/docker
  rm -rf /usr/local/lib/python3

  ## Download the source code. The environment variable is used to
  ## make it easy to change the version later if it becomes necessary.
  wget -O python2.tgz https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz

  ## Unpack the source code and move into the directory
  tar -xvf python2.tgz
  cd Python-${PYTHON_VERSION}

  ## Configure the makefile. If you don't mind a much longer build time,
  ## you can add --enable-optimizations to enable optimizations that will
  ## make the final Python binary run faster.
  ./configure

  ## Build the code and install the binaries. The `-j` option allows
  ## the build to use multiple cores, which speeds up the process.
  ## `all` builds everything, while `install` puts the binaries
  ## into their final locations for use.
  make -j`nproc` all install

  ## You also will want pip2 to be available, so download the install
  ## script for that and run it.
  wget -O get-pip.py https://bootstrap.pypa.io/pip/2.7/get-pip.py
  python2 get-pip.py

  ## Create a package that contains the Python 2 binaries and
  ## libraries. Since those folders were cleaned out earlier,
  ## the only things that will be included are parts of Python 2
  ## This preserves the symbolic links, since copying these files
  ## in a multistage build would cause those to be dereferenced.
  tar czf /python2.tgz /usr/local/bin/ /usr/local/lib
EOF

####################################################################
# Final composite image
####################################################################

## Use the tools stage as the base for this final image. If you choose,
## you can also use the `FROM tools AS final` syntax to create a target
## that you can build by name.
FROM tools
## Make sure that the final image runs as the `runner` user. Just in case
USER runner

## Mount the tarball from the previous stage just during this run
## command. Use that to unpack the binaries into the root. After this
## runs, the mounted file is removed and no reference to it is left
## in the final image. The layer contains just the unpacked files.
RUN --mount=type=bind,from=python2,source=/python2.tgz,target=/tmp/python2.tgz \
	sudo tar -xvf /tmp/python2.tgz -C /
FROM ubuntu:focal

### base ###
ENV DEBIAN_FRONTEND=noninteractive
RUN yes | unminimize \
    && apt-get install -yq \
    curl \
    wget \
    acl \
    zip \
    unzip \
    bash-completion \
    build-essential \
    jq \
    locales \
    man-db \
    software-properties-common \
    libpq-dev \
    sudo \
    && locale-gen en_US.UTF-8 \
    && mkdir /var/lib/apt/dazzle-marks \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/*

ENV LANG=en_US.UTF-8

### Git ###
RUN add-apt-repository -y ppa:git-core/ppa \
    && apt-get install -yq git \
    && rm -rf /var/lib/apt/lists/*

### Container user ###
# '-l': see https://docs.docker.com/develop/develop-images/dockerfile_best-practices/#user
RUN useradd -l -u 33334 -G sudo -md /home/student -s /bin/bash -p student student \
    # passwordless sudo for users in the 'sudo' group
    && sed -i.bkp -e 's/%sudo\s\+ALL=(ALL\(:ALL\)\?)\s\+ALL/%sudo ALL=NOPASSWD:ALL/g' /etc/sudoers
ENV HOME=/home/student
WORKDIR $HOME
# custom Bash prompt
RUN { echo && echo "PS1='\[\e]0;\u \w\a\]\[\033[01;32m\]\u\[\033[00m\] \[\033[01;34m\]\w\[\033[00m\] \\\$ '" ; } >> .bashrc

### Student user (2) ###
USER student
# use sudo so that user does not get sudo usage info on (the first) login
RUN sudo echo "Running 'sudo' for container: success" && \
    # create .bashrc.d folder and source it in the bashrc
    mkdir /home/student/.bashrc.d && \
    (echo; echo "for i in \$(ls \$HOME/.bashrc.d/*); do source \$i; done"; echo) >> /home/student/.bashrc

### Ruby ###
LABEL dazzle/layer=lang-ruby
LABEL dazzle/test=tests/lang-ruby.yaml
USER student
RUN curl -sSL https://rvm.io/mpapis.asc | gpg --import - \
    && curl -sSL https://rvm.io/pkuczynski.asc | gpg --import - \
    && curl -fsSL https://get.rvm.io | bash -s stable \
    && bash -lc " \
    rvm requirements \
    && rvm install 3.2.1 \
    && rvm use 3.2.1 --default \
    && rvm rubygems current \
    && gem install bundler:2.5.16 --no-document" \
    && echo '[[ -s "$HOME/.rvm/scripts/rvm" ]] && source "$HOME/.rvm/scripts/rvm" # Load RVM into a shell session *as a function*' >> /home/student/.bashrc.d/70-ruby

# Make sure RVM paths are prioritized
RUN echo 'export PATH="$HOME/.rvm/rubies/ruby-3.2.1/bin:$HOME/.rvm/gems/ruby-3.2.1/bin:$HOME/.rvm/bin:$PATH"' >> /home/student/.bashrc
RUN echo 'export GEM_HOME="$HOME/.rvm/gems/ruby-3.2.1"' >> /home/student/.bashrc
RUN echo 'export GEM_PATH="$GEM_HOME:$GEM_PATH"' >> /home/student/.bashrc

# AppDev stuff
RUN sudo wget -qO /usr/bin/install-packages "https://gist.githubusercontent.com/jelaniwoods/d5cc8157a0de0f449de748f75e2e182e/raw/c45b0f2947975ff7bb53cbddb8a2fe2e6241db8e/install-packages" \
    && sudo chmod 775 /usr/bin/install-packages
RUN /bin/bash -l -c "gem install htmlbeautifier rufo -N"

WORKDIR /rails-template

# Pre-install gems into /rails-template/gems/
COPY Gemfile /rails-template/Gemfile
COPY --chown=student:student Gemfile.lock /rails-template/Gemfile.lock
RUN /bin/bash -l -c "bundle install"

# Install Google Chrome
RUN sudo apt-get update && sudo apt-get install -y libxss1 && sudo rm -rf /var/lib/apt/lists/*
RUN wget https://mirror.cs.uchicago.edu/google-chrome/pool/main/g/google-chrome-stable/google-chrome-stable_114.0.5735.198-1_amd64.deb && \
    sudo apt-get install -y ./google-chrome-stable_114.0.5735.198-1_amd64.deb

# Install Chromedriver (compatible with Google Chrome version)
RUN BROWSER_MAJOR=$(google-chrome --version | sed 's/Google Chrome \([0-9]*\).*/\1/g') && \
    wget https://chromedriver.storage.googleapis.com/LATEST_RELEASE_${BROWSER_MAJOR} -O chrome_version && \
    wget https://chromedriver.storage.googleapis.com/`cat chrome_version`/chromedriver_linux64.zip && \
    unzip chromedriver_linux64.zip && \
    sudo mv chromedriver /usr/local/bin/ && \
    DRIVER_MAJOR=$(chromedriver --version | sed 's/ChromeDriver \([0-9]*\).*/\1/g') && \
    echo "chrome version: $BROWSER_MAJOR" && \
    echo "chromedriver version: $DRIVER_MAJOR" && \
    if [ $BROWSER_MAJOR != $DRIVER_MAJOR ]; then echo "VERSION MISMATCH"; exit 1; fi

# Install PostgreSQL
RUN sudo install-packages postgresql-12 postgresql-contrib-12

# Setup PostgreSQL server for user student
ENV PATH="$PATH:/usr/lib/postgresql/12/bin"
ENV PGDATA="/workspaces/.pgsql/data"
RUN sudo mkdir -p $PGDATA
RUN mkdir -p $PGDATA ~/.pg_ctl/bin ~/.pg_ctl/sockets \
    && printf '#!/bin/bash\n[ ! -d $PGDATA ] && mkdir -p $PGDATA && initdb -D $PGDATA\npg_ctl -D $PGDATA -l ~/.pg_ctl/log -o "-k ~/.pg_ctl/sockets" start\n' > ~/.pg_ctl/bin/pg_start \
    && printf '#!/bin/bash\npg_ctl -D $PGDATA -l ~/.pg_ctl/log -o "-k ~/.pg_ctl/sockets" stop\n' > ~/.pg_ctl/bin/pg_stop \
    && chmod +x ~/.pg_ctl/bin/* \
    && sudo addgroup dev \
    && sudo adduser student dev \
    && sudo chgrp -R dev $PGDATA \
    && sudo chmod -R 775 $PGDATA \
    && sudo setfacl -dR -m g:staff:rwx $PGDATA \
    && sudo chmod 777 /var/run/postgresql
ENV PATH="$PATH:$HOME/.pg_ctl/bin"
ENV PGHOSTADDR="127.0.0.1"
ENV PGDATABASE="postgres"

# This is a bit of a hack. At the moment we have no means of starting background
# tasks from a Dockerfile. This workaround checks, on each bashrc eval, if the
# PostgreSQL server is running, and if not starts it.
RUN printf "\n# Auto-start PostgreSQL server.\n[[ \$(pg_ctl status | grep PID) ]] || pg_start > /dev/null\n" >> ~/.bashrc

WORKDIR /rails-template
USER student
# Install graphviz (Rails ERD)
RUN /bin/bash -l -c "sudo apt update && sudo apt install -y graphviz=2.42.2-3build2"

# Install fuser (bin/server)
RUN sudo apt install -y psmisc

# Install Node and npm
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - \
    && sudo apt-get install -y nodejs

# Install Yarn
RUN curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add - \
    && echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list \
    && sudo apt-get update \
    && sudo apt-get install -y yarn \
    && sudo npm install -g n \
    && sudo n 18 \
    && hash -r \
    && sudo rm -rf /var/lib/apt/lists/*

# Install Redis.
RUN sudo apt-get update \
    && sudo apt-get install -y \
    redis-server=5:5.0.7-2ubuntu0.1 \
    && sudo rm -rf /var/lib/apt/lists/*

# Install flyyctl
RUN /bin/bash -l -c "curl -L https://fly.io/install.sh | sh"
RUN echo "export PATH=\"/home/student/.fly/bin:\$PATH\"" >> ~/.bashrc
RUN echo '[[ -s "$HOME/.rvm/scripts/rvm" ]] && source "$HOME/.rvm/scripts/rvm"' >> /home/student/.bashrc

# Thoughtbot style bash prompt
RUN sudo wget -qO ./prompt "https://gist.githubusercontent.com/jelaniwoods/7e5db8d72b3dfac257b7eb562cfebf11/raw/af43083d91c0eb1489059a2ad9c39474a34ddbda/thoughtbot-style-prompt"
RUN /bin/bash -l -c "cat ./prompt >> ~/.bashrc"

# Git global configuration
RUN git config --global push.default upstream \
    && git config --global merge.ff only \
    && git config --global alias.aa '!git add -A' \
    && git config --global alias.cm '!f(){ git commit -m "${*}"; };f' \
    && git config --global alias.acm '!f(){ git add -A && git commit -am "${*}"; };f' \
    && git config --global alias.as '!git add -A && git stash' \
    && git config --global alias.p 'push' \
    && git config --global alias.sla 'log --oneline --decorate --graph --all' \
    && git config --global alias.co 'checkout' \
    && git config --global alias.cob 'checkout -b' \
    && git config --global --add --bool push.autoSetupRemote true \
    && git config --global core.editor "code --wait"

# Alias 'git' to 'g'
RUN echo "# No arguments: 'git status'\n\
    # With arguments: acts like 'git'\n\
    g() {\n\
    if [[ \$# > 0 ]]; then\n\
    git \$@\n\
    else\n\
    git status\n\
    fi\n\
    }\n# Complete g like git\n\
    source /usr/share/bash-completion/completions/git\n\
    __git_complete g __git_main" >> ~/.bash_aliases

# Alias bundle exec to be
RUN echo "alias be='bundle exec'" >> ~/.bash_aliases

# Alias rake grade to grade
RUN echo "alias grade='rake grade'" >> ~/.bash_aliases
RUN echo "alias grade:reset_token='rake grade:reset_token'" >> ~/.bash_aliases

# Add bin/rake to path for non-Rails projects
RUN echo 'export PATH="$PWD/bin:$PATH"' >> ~/.bashrc

# Install Docker
RUN sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add - \
    && sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    && sudo apt-get update && sudo apt-get install -y docker-ce \
    && sudo usermod -aG docker student
RUN echo 'export PATH="$PATH:/usr/bin/docker"' >> ~/.bashrc

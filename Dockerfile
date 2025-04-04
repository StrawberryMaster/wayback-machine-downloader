FROM ruby:3.1.6-alpine
USER root
WORKDIR /build
COPY . /build

RUN gem update \
    && gem install concurrent-ruby \
    && bundle install

WORKDIR /
ENTRYPOINT [ "/build/bin/wayback_machine_downloader" ]
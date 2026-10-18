FROM alpine:3.22
RUN apk add --no-cache openssh-client
COPY entrypoint.sh healthcheck.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Stand-in smoke-test image for the updater tests.
FROM alpine:3
COPY smoke.sh /smoke.sh
RUN chmod 0755 /smoke.sh
ENTRYPOINT ["/smoke.sh"]

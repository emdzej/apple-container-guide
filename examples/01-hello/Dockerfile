FROM docker.io/library/alpine:3.22
RUN echo "built at $(date -u)" > /built.txt
ENTRYPOINT ["/bin/sh", "-c", "cat /built.txt && echo 'hello from' $(uname -m) 'kernel' $(uname -r)"]

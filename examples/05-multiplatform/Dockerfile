FROM docker.io/library/alpine:3.22
RUN uname -m > /arch.txt
CMD ["/bin/sh", "-c", "echo image built for $(cat /arch.txt); echo running as $(uname -m)"]

# Copyright 2026 ELEMENTS Consulting GmbH
#
# IODD-Mirror: lokaler IODDfinder-Ersatz fuer das sensorconnect-Plugin.
# Nur Go-Standardbibliothek, der Build laedt keine Module nach.
#
#   docker build -f iodd_mirror/Dockerfile -t opairs-iodd-mirror .

FROM golang:1.27.1@sha256:3680233e3204827fbdc66088528ae6d4b3d034f51d03a99d454f6de034888244 AS build

WORKDIR /src
COPY go.mod go.sum ./
COPY iodd_mirror ./iodd_mirror

ENV CGO_ENABLED=0
RUN go build -trimpath -ldflags "-s -w" -o /out/iodd-mirror ./iodd_mirror/cmd/iodd-mirror

FROM scratch

# CA-Zertifikate nur fuer "iodd-mirror fetch" (HTTPS zum IODDfinder)
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /out/iodd-mirror /iodd-mirror

USER 10001
EXPOSE 8080
ENTRYPOINT ["/iodd-mirror"]
CMD ["serve", "-dir", "/data", "-listen", ":8080"]

LABEL org.opencontainers.image.source=https://github.com/ELEMENTSCONSULTING/opairs-connect-machine

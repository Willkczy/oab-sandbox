# The Discord gateway relay: a TCP listener that forwards each connection
# through squid as an HTTP CONNECT tunnel.
#
# It exists because openab's gateway client, tokio-tungstenite, ignores
# HTTPS_PROXY and dials the gateway host itself (finding 8). The agent container
# resolves that host to this container instead, and socat opens the tunnel on
# its behalf. socat never terminates TLS: openab's handshake travels end to end,
# so Discord's certificate is still verified by openab, and squid still sees and
# logs the destination hostname. The single-gate property survives.
#
# Deliberately its own image rather than oab-sandbox:pi with a different
# entrypoint. The agent image happens to ship socat, but it also ships node, pi
# and openab. This container needs one binary and holds no secret, and keeping it
# that small follows the rule the broker already follows.
FROM alpine:3.24

RUN apk add --no-cache socat

USER 1000:1000
ENTRYPOINT ["socat"]

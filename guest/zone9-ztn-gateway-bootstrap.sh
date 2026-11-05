#!/bin/sh
# Kept for existing images and URLs. The gateway bootstrap now lives in
# storc-gateway-bootstrap.sh, installed as /usr/local/sbin/zone9-gateway-bootstrap
# (egress NAT on every boot + Zero Trust on request).
exec /usr/local/sbin/zone9-gateway-bootstrap "$@"

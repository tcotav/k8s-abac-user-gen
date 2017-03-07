#!/bin/bash

CERTHOME=/srv/kubernetes
SERVKEY=${CERTHOME}/server.key
SERVCERT=${CERTHOME}/server.cert
CA=${CERTHOME}/${CACERT}
NEWNAME=tcotav

openssl genrsa -out ${NEWNAME}.pem 2048
openssl req -new -key ${NEWNAME}.pem -out ${NEWNAME}.csr -subj "/CN=${NEWNAME},O=admin"
openssl x509 -req -in ${NEWNAME}.csr -CA ${SERVCERT} -CAkey ${SERVKEY} -CAcreateserial -out ${NEWNAME}.crt -days 365

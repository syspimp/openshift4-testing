#!/bin/bash
pushd ~/go/src/github.com/openshift/installer/ && \
bin/openshift-install --dir=initial destroy cluster && \
popd && \
rm -rf ~/go/src/github.com/openshift/installer


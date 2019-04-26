#!/bin/bash
[[ -e  ~/go/src/github.com/openshift/installer ]] && \
pushd ~/go/src/github.com/openshift/installer/ && \
if [[ -x bin/openshift-install ]]
then
  bin/openshift-install --dir=initial destroy cluster
fi && \
popd && \
rm -rf ~/go/src/github.com/openshift/installer
exit 0;

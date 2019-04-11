#!/bin/bash
if [[ "$1" == "-h" ]];
then
  echo -e "$0 Wrapper to set up Openshift on Openstack Ansible playbooks\n\
  usage:\n\
    $0\n\
    run in interactive mode\n\n\
    $0 -y\n\
    run in non-interactive mode\n\n\
    $0 -d\n\
    run in debug level non-interactive mode\n\n"
  exit 0;
fi

if [[ "$1" != "-y" && "$1" != "-d" ]];
then
  echo -e "Prerequisites:
  - 1. you will need to get an openshift pull secret from\n\
    cloud.openshift.com developer preview\n\
    https://cloud.openshift.com/clusters/install\n\
  - 2. you will also need to upload a proper RH Core OS image to your Openstack deployment\n\
    the installer expects it to be named 'rhcos'\n\
    you can get rhcos images from (need internal redhat vpn access)\n\
    https://releases-redhat-coreos.cloud.paas.upshift.redhat.com/\n\
    I use version rhcos based on maipo (redhat 7)\n\
    because the ootpa branch is under constant revision\n\
    curl --compressed -J -L -O https://releases-redhat-coreos.cloud.paas.upshift.redhat.com/storage/releases/maipo/400.7.20190312.0/rhcos-maipo-400.7.20190312.0-openstack.qcow2.gz\n\
  - 3. you will need to edit the group_vars/all with your Openstack creds\n\
    These are found in your keystone_admin or similar file.\n\
  - 4. In the group_vars/all file, there is a section for the External Network type and subnet to use.\n\
    Edit as needed in the build-ocp-in-osp.yaml file as well.\n\
  - 5. You will need to setup up DNS to access all the components of Openshifts\n\
    This script will setup some common entries /etc/hosts to get it up,\n\ 
    but it is not a substitute for a working Openshift environment.\n\
  - 6. If you want to deploy to aws, you will need to run the following commands FIRST\n\
    pip3 install awscli --upgrade --user (pip3 if on Fedora 29 or greater)\n\
    aws configure\n"
  sleep 2
  read -p "Proceed? Hit Enter to proceed, Ctrl-C to cancel"
  echo -e "\n\n\nThis setup script will:\n\
  - create a clouds.yaml in this directory to access your Openstack via Ansible\n\
  - install rpms to satisfy build dependencies to build the openshift-install binary and go packages\n\
  - create directory ~/go/src/github.com/openshift/installer to build and run installer\n\
  - update /etc/hosts with entries for installer to succeed.\n\
  - create an External Network in Openstack for Openshift only use\n\
  - create a temporary instance to assign a floating IP address\n\
  - create a temporay file to store the floating IP address in /tmp\n\
  - launch openshift-install, an interactive prompt to define the Openshift cluster\n\
  - Deploy the Openshift cluster\n"
  sleep 2
  echo -e "You should have edited the following files:\n\
  - group_vars/all\n\n\
ansible-playbook will ask you for your sudo password.  If you don't have to type a sudo password to install packages or edit /etc/hosts, you can edit this file $0 and uncomment the line without --ask-become-pass"
  echo -e "\n\nRun $0 -y to skip this message next time\n"

 read -p "Proceed? Hit Enter to start, Ctrl-C to cancel"
fi

rpm -qa | grep ansible-2.7 >/dev/null

if [ $? -ne 0 ]
then
  echo -e "\nnYou need to install ansible 2.7. I'll install it now.\n\n"
  if [ -e /etc/redhat-release ]
  then
    if grep Fedora /etc/redhat-release
    then
      sudo yum -y install ansible
    elif grep "Red Hat" /etc/redhat-release
    then
      sudo subscription-manager repos --enable rhel-7-server-ansible-2.7-rpms
      sudo yum -y install ansible
    else
      echo -e "This script was only tested on RHEL 7 and Fedora 29. You will have to manually install ansible 2.7 and try again"
      exit 1;
    fi
  else
    echo -e "This script was only tested on RHEL 7 and Fedora 29. You will have to manually install ansible 2.7 and try again"
    exit 1;
  fi
fi

#exit on error
set -e

# run playbook to create the clouds.yaml
ansible-playbook --extra-vars "currentdir=$(pwd)" build-cloud-creds.yaml

# remove Region info from local clouds.yaml
# only the one in openshift-install directory needs it
ansible localhost -m lineinfile -a "dest=clouds.yaml regexp='^      region_name: RegionOne' line='#      region_name: RegionOne' state=present backrefs=yes"

# run playbook to create the environment
# if you don't have to type a password for sudo
#ansible-playbook build-osp-ocp4-env.yaml
ansible-playbook --ask-become-pass build-osp-ocp4-env.yaml

source /tmp/floatingIP.txt
#echo "Floating IP is ${floatingIP}. Is this correct?"
#read -p "[enter] or Ctrl-C and edit /tmp/floatingIP.txt"

# run the openshift-install binary to create the config, and then edit it with the floating Ip we created
echo -e "\nRunning the openshift-install binary to create an OCP4 cluster, and save the configuration in the directory \n\
~/go/src/github.com/openshift/installer/initial\n"

pushd ~/go/src/github.com/openshift/installer

if [[ "$1" != "-y" && "$1" != "-d" ]];
then
  bin/openshift-install --dir=initial create install-config
  # fix the floating ip in the install-config.yaml
  if [[ ! -z "$floatingIP" ]]
  then
    echo -e "\nNow we edit the install-config.yaml file to add the floating ip we created.\n"
    #sed -i -e "s/    lbFloatingIP: \"\"/    lbFloatingIP: \"${floatingIP}\"/g" initial/install-config.yaml
    ansible localhost -m lineinfile -a "dest=initial/install-config.yaml regexp='^    lbFloatingIP: \"\"' line='    lbFloatingIP: \"${floatingIP}\"' state=present backrefs=yes"
  else
    echo "WARNING: Floating IP was not created, you will have to manually add the floating IP to the api instance"
  fi
else
  #sed -i -e "s/    lbFloatingIP: \"\"/    lbFloatingIP: \"${floatingIP}\"/g" initial/install-config.yaml
  popd
  ansible localhost -m -e "floatingIP=${floatingIP}" template -a "src=install-config.yaml.j2 dest='{{ homedir }}/go/src/github.com/openshift/installer/initial/install-config.yaml'"
  pushd ~/go/src/github.com/openshift/installer
fi

# create the cluster
echo -e "\nRunning the openshift-install binary again to *use* the configuration in the directory \n\
~/go/src/github.com/openshift/installer/initial\n\n\
This will take about 1 hour.\n\n
Some useful commands to run in another terminal\n\
  - for these examples, ip's will be similar to yours, but not exact\n\
  - the user is 'core' and the api server is the load balancer for the cluster\n\
  - watch the logs on the api server:\n\
  - ssh core@api.${clustername}.${basedomain} 'journalctl -f'\n\
  - use the api server as a jump host to the masters:\n\
  - ssh -J core@api.${clustername}.${basedomain} core@10.0.0.9\n\
  - test the api server:\n\
  - curl -k https://api.${clustername}.${basedomain}:6443\n\
  - list the running pods on the api server:\n\
  - ssh core@api.${clustername}.${basedomain} 'sudo podman ls'\n\
  - and so on\n\n"

sleep 5
if [[ "$1" != "-y" && "$1" != "-d" ]];
then
  read -p "[enter] or Ctrl-C and exit"
fi

# resume on error to troubleshoot
set +e

echo "Start: $(date)"

if [[ "$1" == "-d" ]];
then
  bin/openshift-install --log-level=debug --dir=initial create cluster
else
  bin/openshift-install --dir=initial create cluster
fi

if [[ $? -eq 0 ]]
then
  echo "lets use the kubeconfig to test it out"
  oc --config initial/auth/kubeconfig get all

  # copy kubeconfig to expected place so we don't have to be explicit
  # mkdir ${HOME}/.kube && cp initial/auth/kubeconfig ${HOME}/.kube/config

  # ssh to machine, cat release
  echo "lets ssh to the floating ip address and cat the redhat-release"
  ssh core@${floatingIP} "cat /etc/redhat-release"
else
  echo "something went wrong, let's dump some journals"
  # be verbose with our commands
  set -x
  oc --config=./initial/auth/kubeconfig --namespace=openshift-machine-api get deployments
  oc --config=./initial/auth/kubeconfig --namespace=openshift-machine-api logs deployments/clusterapi-manager-controllers --container=machine-controller
  oc --config=./initial/auth/kubeconfig --namespace=openshift-machine-api get csr
  oc --config=./initial/auth/kubeconfig describe clusterversion
  oc --config=./initial/auth/kubeconfig get clusterversion
  #oc --config=./initial/auth/kubeconfig --namespace=openshift-machine-api get csr -o name | xargs oc --config=./initial/auth/kubeconfig adm certificate approve
  #oc --config=./initial/auth/kubeconfig --namespace=openshift-machine-api logs deployments/clusterapi-manager-controllers --container=clusterapi-manager-controllers
  #oc --config=./initial/auth/kubeconfig --namespace=openshift-machine-api logs deployments/clusterapi-manager-controllers --container=nodelink-controller
  #oc --config=./initial/auth/kubeconfig get pods
  #oc --config initial/auth/kubeconfig get all
  #oc --config=./initial/auth/kubeconfig get all
  #vi docs/user/troubleshooting.md
  #oc get clusterversion -o json|jq ".items[0].status"
  #oc get clusterversion -o json|jq ".items[0].status"

  set +x
  echo -e "You might be able to log into the console:\n\
  https://console-openshift-console.apps.${clustername}.${basedomain}\n\n
  User: kubeadmin\n\
  Pass: `cat ./initial/auth/kubeadmin-password`\n"
  echo "the installer is in ~/go/src/github.com/openshift/installer"
  echo "the cluster config is in ~/go/src/github.com/openshift/installer/initial"
  echo "the cluster kubeconfig is in ~/go/src/github.com/openshift/installer/initial/auth"
  echo -e "you can destroy the created resources with the command \n\
  bin/openshift-install --dir=initial destroy install-config from the installer directory\n\
  To re-run this file from scratch, run: rm -rf ~/go/src/github.com/openshift && ./setup.sh"
fi
echo "End: $(date)"

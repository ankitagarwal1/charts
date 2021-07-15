#!/usr/bin/env bash

##
## Copyright (c) 2021. Dell Inc. or its subsidiaries. All Rights Reserved.
##
## This software contains the intellectual property of Dell Inc.
## or is licensed to Dell Inc. from third parties. Use of this software
## and the intellectual property contained therein is expressly limited to the
## terms and conditions of the License Agreement under which it is provided by or
## on behalf of Dell Inc. or its subsidiaries.


# usage function
function usage()
{
   cat << HEREDOC

   Usage: $progname  --set type=<install_type> --set helmrepo=<repo> --set primaryStorageClassName=... [--set global.registry=myfavereg.docker.com] [--set global.watchAllNamespaces=false]
                        [--verbose] [--debug] [--version 0.76.0] [--namespace default]

   required arguments for install:
     --set type={install|list|remove}       set install type
     --set helmrepo=repo_name               location of helm repository or directory where charts located
     --set primaryStorageClassName=<string> name of storage class to install high performance persistent volumes (e.g. csi-baremetal-ssdlvg). Required only for type=install

   optional arguments:
     --set global.registry=<string>           where to pull ObjectScale container images
     --set global.registrySecret=<string>     what registry login to use to pull down container images
     --set secondaryStorageClassName=<string> name of storage class for normal performance persistent volumes (e.g. csi-baremetal-hddlvg)
     --set global.watchAllNamespaces=<true|false> allow deploying objectstore across the namespaces
     -h, --help                               show this help message and exit
     -v, --verbose                            increase the verbosity of the bash script
     --debug                                  shell debug (-x) mode, lots of output
     --version                                version of the chart to upgrade
     --namespaace                             namespace to install the plugin

   Example for OpenShift:
   ----------------------
   helm repo add objectscale "https://MY_PRIVATE_TOKEN@raw.githubusercontent.com/emcecs/charts/v0.7x.0/docs"
   helm repo update
   ./objectscale-install.sh --set type=install --set helmrepo=objectscale --set global.registry=asdrepo.isus.emc.com:8099 --set primaryStorageClassName=csi-baremetal-sc-ssdlvg --set secondaryStorageClassName=csi-baremetal-sc-hddlvg
   helm repo add objectscale "https://MY_PRIVATE_TOKEN@raw.githubusercontent.com/emcecs/charts/v0.7y.0/docs"
   ./objectscale-install.sh --set type=upgrade --set helmrepo=objectscale

HEREDOC
}  

function parse_set_opts()
{
    nameval="$1"
    namevalArr=(${nameval//=/ })
    setName=${namevalArr[0]}
    setValue=${namevalArr[1]}
    case $setName in 
        "type")                    
            install_type=$setValue 
            ;;
        "helmrepo")                 
            helm_repo=$setValue 
            ;;
        "primaryStorageClassName"|"primaryStorageClass"|psc*)
            primaryStorageClassName=$setValue 
            ;;
        "secondaryStorageClassName"|"secondaryStorageClass"|ssc*)
            secondaryStorageClassName=$setValue
            ;;
        "global.registry")
            registry="$nameval"
            registryName="$setValue"
            ;;
        "global.registrySecret")
            regSecret="$nameval"
            registryName="$setValue"
            ;;
        "global.watchAllNamespaces")
            watchAllNamespaceFlag="$setValue"
            ;;
        *)  
            set_opts+=($nameval) ;;
    esac

}

function install_portal() 
{
    uiStorageClass=${secondaryStorageClassName:-$primaryStorageClassName}
    cmd="helm install objectscale-ui ${helm_repo}/objectscale-portal $dryrun -n $namespace $set_ver --set global.watchAllNamespaces=$watchAllNamespaceFlag --set global.platform=$platform,$registry,$regSecret --set global.storageClassName=$uiStorageClass --devel"
    echomsg log $cmd
    eval $cmd
    if [ $? -ne 0 ]
    then
        echomsg "ERROR: unable to install ObjectScale UI"
    fi

}

function upgrade_portal() 
{
    cmd="helm upgrade objectscale-ui ${helm_repo}/objectscale-portal $dryrun --reuse-values -n $namespace $set_ver --set global.platform=$platform --devel"

    echomsg log $cmd
    eval $cmd
    if [ $? -ne 0 ]
    then
        echomsg "ERROR: unable to upgrade ObjectScale UI"
    fi

}

function apply_app_crd()
{
    echomsg "Applying k8s application crd"
    cmd="kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/application/master/config/crd/bases/app.k8s.io_applications.yaml"
    echomsg log $cmd
    eval $cmd
}


function create_app_yaml() 
{
    appYaml=$1
    appJson=$2
    sed -i 's/"/\\\\"/g' $appJson
    sed -i "s%.*nautilus.dellemc.com/chart-values:.*%    nautilus.dellemc.com/chart-values: \"$(export IFS=; while read -r line ; do echo $line; done < $appJson)\"%" ${appYaml}
	sed -i 's/app.kubernetes.io\/managed-by: Helm/app.kubernetes.io\/managed-by: nautilus/g' $appYaml
    
}

function apply_app_resource()
{
    component=$1
    cmd="kubectl apply -f ./tmp/$component-app.yaml"
    echomsg log $cmd
    eval $cmd
    if [ $? -ne 0 ]
    then
        echomsg error "problem applying $component app resource, check kubectl output"
        exit 1
    fi

}
function install_logging_injector()
{
    component=logging-injector
    echomsg "Installing $component..."
    cmd="helm show values ${helm_repo}/logging-injector > ./tmp/logging-injector-values.yaml"
    echomsg log $cmd
    eval $cmd
    if [ $? -ne 0 ]
    then
        echomsg error "unable to get $component chart values"
        exit 1
    fi
   	helm template --show-only templates/logging-injector-custom-values.yaml logging-injector ${helm_repo}/logging-injector \
		--set useCustomValues=true \
		--set global.platform=$platform,$registry,$regSecret \
    	--set global.objectscale_release_name=objectscale-manager \
    	--set global.rsyslog_client_stdout_enabled=false --devel \
        -f ./tmp/logging-injector-values.yaml > ./tmp/logging-injector-customvalues.yaml
    if [ $? -ne 0 ]
    then
        echomsg error "unable to generate $component custom values"
        exit 1 
    fi 

    $yq_bin eval ./tmp/logging-injector-customvalues.yaml -j -I 0 > ./tmp/logging-injector-customvalues.json
    if [ $? -ne 0 ]
    then
        echomsg error "unable to create $component custom values json file"
        exit 1
    fi

    ## now gen the app resource
    helm template --show-only templates/logging-injector-app.yaml logging-injector ${helm_repo}/logging-injector -n $namespace $set_ver --set global.watchAllNamespaces=$watchAllNamespaceFlag --devel \
	    -f ./tmp/logging-injector-values.yaml -f ./tmp/logging-injector-customvalues.yaml > ./tmp/logging-injector-app.yaml
    if [ $? -ne 0 ]
    then
        echomsg error "unable to create $component application resource yaml"
        exit 1
    fi
    create_app_yaml ./tmp/logging-injector-app.yaml ./tmp/logging-injector-customvalues.json
	sed -i 's/createApplicationResource\\":true/createApplicationResource\\":false/g' ./tmp/logging-injector-app.yaml

    apply_app_resource $component

    echomsg "Installed $component done"

}

## install_kahm creates app resource and applies it to the setup
function install_kahm()
{
    component=kahm
    echomsg "Install $component"
    cmd="helm show values ${helm_repo}/kahm > ./tmp/kahm-values.yaml"
    echomsg log $cmd
    eval $cmd
    if [ $? -ne 0 ]
    then
        echomsg error "unable to get $component chart values"
        exit 1
    fi


   	helm template --show-only templates/kahm-custom-values.yaml kahm ${helm_repo}/kahm \
		--set useCustomValues=true \
		--set global.platform=$platform,$registry,$regSecret \
        --set storageClassName=$secondaryStorageClassName \
        --set postgresql-ha.persistence.storageClass=$secondaryStorageClassName --devel \
    -f ./tmp/kahm-values.yaml > ./tmp/kahm-customvalues.yaml 
    if [ $? -ne 0 ]
    then
        echomsg error "unable to generate $component custom values"
        exit 1
    fi

    $yq_bin eval ./tmp/kahm-customvalues.yaml -j -I 0 > ./tmp/kahm-customvalues.json
    if [ $? -ne 0 ]
    then
        echomsg error "unable to create $component custom values json file"
        exit 1
    fi 

    ## now gen the app resource
    helm template --show-only templates/kahm-app.yaml kahm ${helm_repo}/kahm  -n $namespace $set_ver --set global.watchAllNamespaces=$watchAllNamespaceFlag --devel \
	    -f ./tmp/kahm-values.yaml -f ./tmp/kahm-customvalues.yaml > ./tmp/kahm-app.yaml
    if [ $? -ne 0 ]
    then
        echomsg error "unable to create $component application resource yaml"
        exit 1
    fi

    create_app_yaml ./tmp/kahm-app.yaml ./tmp/kahm-customvalues.json
    sed -i 's/createkahmappResource\\":true/createkahmappResource\\":false/g' ./tmp/kahm-app.yaml

    apply_app_resource $component

}

function install_decks()
{
    component=decks
    cmd="helm show values ${helm_repo}/decks > ./tmp/decks-values.yaml"
    echomsg log "$cmd"
    eval $cmd 
    if [ $? -ne 0 ]
    then
        echomsg error "unable to get $component chart values"
        exit 1
    fi

   	helm template --show-only templates/decks-custom-values.yaml kahm ${helm_repo}/decks \
		--set useCustomValues=true \
		--set global.platform=$platform,$registry,$regSecret \
        --set global.storageClassName=$secondaryStorageClassName \
       	--set decks-support-store.persistentVolume.storageClassName=$secondaryStorageClassName --devel \
    -f ./tmp/decks-values.yaml > ./tmp/decks-customvalues.yaml 
    if [ $? -ne 0 ]
    then
        echomsg error "unable to generate $component custom values"
        exit 1
    fi

    $yq_bin eval ./tmp/decks-customvalues.yaml -j -I 0 > ./tmp/decks-customvalues.json
    if [ $? -ne 0 ]
    then
        echomsg error "unable to create $component custom values json file"
        exit 1
    fi 

    ## now gen the app resource
    helm template --show-only templates/decks-app.yaml decks ${helm_repo}/decks  -n $namespace $set_ver --set global.watchAllNamespaces=$watchAllNamespaceFlag --devel \
	    -f ./tmp/decks-values.yaml -f ./tmp/decks-customvalues.yaml > ./tmp/decks-app.yaml
    if [ $? -ne 0 ]
    then
        echomsg error "unable to create $component application resource yaml"
        exit 1
    fi

    create_app_yaml ./tmp/decks-app.yaml ./tmp/decks-customvalues.json
    sed -i 's/createdecksappResource\\":true/createdecksappResource\\":false/g' ./tmp/decks-app.yaml

    apply_app_resource "decks"

}


function install_objectscale_manager() 
{
    component="objectscale-manager"
    echomsg "Installing $component"
    cmd="helm show values ${helm_repo}/objectscale-manager > ./tmp/objectscale-manager-values.yaml"
    echomsg log "$cmd"
    eval $cmd
    if [ $? -ne 0 ]
    then
        echomsg error "unable to get $component chart values"
        exit 1
    fi

    echomsg "Generating $component install settings..."
    helm template --show-only templates/objectscale-manager-custom-values.yaml objectscale-manager $helm_repo/objectscale-manager \
        --set useCustomValues=true \
        --set global.platform=$platform,$registry,$regSecret \
        --set hooks.registry=$registryName,global.storageClassName=$primaryStorageClassName \
        --set ecs-monitoring.influxdb.persistence.storageClassName=$primaryStorageClassName \
        --set global.monitoring_registry=$registryName \
		--set objectscale-monitoring.influxdb.persistence.storageClassName=$primaryStorageClassName \
	    --set objectscale-monitoring.rsyslog.persistence.storageClassName=$secondaryStorageClassName --devel \
         -f ./tmp/objectscale-manager-values.yaml > ./tmp/objectscale-manager-customvalues.yaml && sed -i -e "/^-/d" -e "/^\#/d" ./tmp/objectscale-manager-customvalues.yaml
    if [ $? -ne 0 ]
    then
        echomsg error "unable to generate $component custom values"
        exit 1
    fi

    $yq_bin eval ./tmp/objectscale-manager-customvalues.yaml -j -I 0 > ./tmp/objectscale-manager-customvalues.json
    if [ $? -ne 0 ]
    then
        echomsg error "unable to create $component custom values json file"
        exit 1
    fi 

    echomsg "Generating $component application resource..."
    ## now gen the app resource
    helm template --show-only templates/objectscale-manager-app.yaml objectscale-manager ${helm_repo}/objectscale-manager  -n $namespace $set_ver --set global.watchAllNamespaces=$watchAllNamespaceFlag --devel -f ./tmp/objectscale-manager-values.yaml -f ./tmp/objectscale-manager-customvalues.yaml > ./tmp/objectscale-manager-app.yaml
    if [ $? -ne 0 ]
    then
        echomsg error "unable to create $component application resource yaml"
        exit 1
    fi

    create_app_yaml ./tmp/objectscale-manager-app.yaml ./tmp/objectscale-manager-customvalues.json
	sed -i 's/createApplicationResource\\":true/createApplicationResource\\":false/g' ./tmp/objectscale-manager-app.yaml

    apply_app_resource "objectscale-manager"

    echomsg "Installed component: $comp"

}

function objectscale_list_components()
{
    echomsg dl
    helm list 
    echomsg dl
    kubectl get app 

}


# initialize variables
progname=$(basename $0)
verbose=0
platform="OpenShift"
watchAllNamespaceFlag="true"
namespace="default"
set_ver=""

yq_bin="./bin/yq_linux_amd64"

# use getopt and store the output into $OPTS
# note the use of -o for the short options, --long for the long name options
# and a : for any option that takes a parameter
OPTS=$(getopt -o "dhvn:" --long "debug,dry-run,help,version:,namespace:,set:,verbose" -n "$progname" -- "$@")
if [ $? != 0 ] ; then echo "Error in command line arguments." >&2 ; usage; exit 1 ; fi
eval set -- "$OPTS"

set_opts=()
while true; do
  # uncomment the next line to see how shift is working
  # echo "\$1:\"$1\" \$2:\"$2\""
  case "$1" in
    -h | --help ) usage; exit; ;;
    --set ) parse_set_opts $2 ; shift 2 ;;
    --version ) chart_version="$2"; shift 2 ;;
    --namespace ) namespace="$2"; shift 2 ;;
    --debug) set -x; shift ;; 
    --dry-run ) dryrun="--dry-run"; shift ;;
    -v | --verbose ) verbose=$((verbose + 1)); shift ;;
    -- ) shift; break ;;
    * ) break ;;
  esac
done

if (( $verbose > 0 )); then

   # print out all the parameters we read in
   cat <<EOM
   set_opts=${set_opts[*]}
   verbose=$verbose
   dryrun=$dryrun
   version=$chart_version
   type=$install_type
   helmrepo=$helm_repo
   sc=$primaryStorageClassName
   namespace=$namespace
   watchAllNamespacesFlag=$watchAllNamespaceFlag
EOM
fi

function set_version()
{
    echomsg "chart version if set..."
    if [ ! -z ${chart_version} ]
    then
       set_ver="--version $chart_version"
    fi
}

case "$install_type" in
    install)
        ## install a locat copy of yq
        if [ ! -x $yq_bin ]
        then 
            yq_payload_line=$(awk '/^__YQ_PAYLOAD_BEGINS__/ { print NR + 1; exit 0; }' $0)

            mkdir -p ./bin

            # extract the embedded yq binary
            tail -n +${yq_payload_line} $0 | base64 -d | tar -zpvx -C ./bin
            chmod 550 $yq_bin
        fi 

        if [ -z ${primaryStorageClassName} ]
        then
            echomsg error " primary storage class not specified"
            exit 1
        fi

        if [ -z ${secondaryStorageClassName} ]
        then
            secondaryStorageClassName=$primaryStorageClassName
        fi
    ;;

esac

set_version

## check for helm and kubectl in the path
helm --help > /dev/null
if [ $? -ne 0 ] 
then 
    echomsg error "helm not found, please install from https://helm.sh and add to your PATH"
    exit 1
fi 

kubectl version 
if [ $? -ne 0 ]
then
    echomsg error "unable to get versions of k8s connection, please fix"
    exit 1
fi

case $install_type in 
    install)
        install_portal
        if [ -d ./tmp ] 
        then
            rm -rf ./tmp
        fi
        mkdir -p ./tmp

        echomsg "Installing ObjectScale components..."
        apply_app_crd
        install_logging_injector
        install_kahm
        install_decks
        install_objectscale_manager
        objectscale_list_components
        helm get notes objectscale-ui
        echomsg dl
        echo
        echomsg "Please wait a few minutes until all ObjectScale have started"
        echomsg dl 
        ;;
    list)
        objectscale_list_components
        ;;
    upgrade)
        echomsg "upgrading portal chart..."
        upgrade_portal
        ;;
    delete|remove|uninstall)
        for comp in decks kahm objectscale-manager logging-injector 
        do
            echomsg "Removing component: $comp"
            kubectl delete app $comp
            helm delete $comp
        done
        echomsg "Removing objectscale-ui"
        helm delete objectscale-ui 
        ;;
    *)
        echomsg error "invalid install type specified: must be one of 'install|list|remove|upgrade"
        usage
        exit 1
        ;;
esac 

exit 0

__YQ_PAYLOAD_BEGINS__

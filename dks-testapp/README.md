# Dell EMC DKS (KAHM DECKS SRSGateway) Test Application Support
The goal of the KAHM and DECKS infrastucture is to provide customers remote support, to report critical events to the SRS Gateway and manage the licenses usage for the customer. The purpose of the test application  is to test the KAHM and DECKS functionality end-to-end. It will check the health of the KAHM and DECKS infrastructure (SRSGateway etc.) by emulating a test application, defining some event routing rules for the application and generate some test events in a controlled environment to verify that the application events are routed to the SRSGateway.

This Helm chart deploys a test application resource and configmaps to be used to generate events and to define the event routing rules. 

 
## Table of Contents

* [Description](#description)
* [Requirements](#requirements)
* [Quick Start](#quick-start)
* [Configuration](#configuration)

## Description

This Helm chart deploys:
- A test Application Resource.
  The Application CR:
  - Allows the user to define the event routing rules for an application.
- A <application-name>-event-rules configmap that contains:
  - Event routing rules to route an application events to the SRSGateway.
- A <application-name>-event-config configmap that contains:
  - what type of events need to generate
  - how many events need to generate
  - reason of the event
  - message of the event 
  - custom label to be added to the event

## Requirements

* A [Helm](https://helm.sh) installation with access to install to one or more namespaces.
* A [KAHM](https://github.com/EMCECS/charts/tree/master/kahm) installation.
* A [DECKS](https://github.com/EMCECS/charts/tree/master/decks) installation.
* A [SRS Gateway](https://github.com/EMCECS/charts/tree/master/srs-gateway) installation.

## Quick Start

1. First, [install and setup Helm](https://docs.helm.sh/using_helm/#quickstart).  *_Note:_* you'll likely need to setup role-based access controls for Helm to have rights to install packages, so be sure to read that part.

2. Setup the [EMCECS Helm Repository](https://github.com/EMCECS/charts).

```bash
$ helm repo add ecs https://emcecs.github.io/charts
$ helm repo update
```

3. Install the DKS test application by using the followings. 
   the default srsGateway custom resource name is "objectscale".
```bash
$ helm install --name dks-testapp ecs/dks-testapp --set srsGateway.name=objectscale
```r
If the dks-testapp image is on private docker registry, you can specify your registry name and secrets at the time of the installation.

```bash
$ helm install --name dks-testapp ecs/dks-testapp --set srsGateway.name=objectscale --set global.registry=my-docker-registry" --set global.registrySecret=my-existing-secrets

```

4. After installing the test application, the test can be run as a "helm test". If the test PASSED, it means all the events generated by the test are successfully delivered to the SRSGateway. If the test  FAILED, it could be one of the following reasons:
 - KAHM pod is not up and running
 - DECKS pod is not up and running
 - SRSGateway regsitration did not complete succesffuly
 - Event routing rules were not set properly to route to the SRS-notifier

The test log can be seen by "kubectl logs" on the test pod.

```bash
$ helm test dks-testapp
$ kubectl logs -f <test-pod> 
```

## Configuration

###  application.testAppName
Can be set to any name you like.
Example helm install command line setting:
```
--set application.testAppName="dks-test1"
```

###  application.event
Configuration to define an event to be generated and how many events.
Example helm install command line setting:
```
--set application.event.type="Critical"
--set application.event.reason="srs-test"
--set application.event.message="test event"
--set application.event.label="srs-event"
--set application.event.labelValue="true"
--set application.event.totalEvents=1
```

###  application.eventRules
Configuration to define the application event rules to be applied on the application events. An application event will get routed to the SRSGateway if the event matches the rule. In the given example below, if the event type is "Critical" and the event has label: "srs-event=true", then it will get routed to the SRSGateway Notifier(objectscale-srs-default).
Example helm install command line setting:
```
--set application.eventRules.label="srs-event"
--set application.eventRules.labelValue="true"
--set application.eventRules.field="type"
--set application.eventRules.fieldValue="type"
```

###  application.srsGateway
Configuration to define the SRSGateway to be tested. The name and namespace should be the SRSGateway customer resource name and namepsace.
```
--set application.srsGateway.name="objectscale"
--set application.eventRules.namespace="default"
```
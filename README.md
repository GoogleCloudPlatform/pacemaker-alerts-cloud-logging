_TLDR_
This document explains how to automate the process of notifying
the interested parties upon a cluster event and reporting
on the events for a period of time.

## Deploying the Alert Script
The Pacemaker supports event driven alerting via script execution.
The basics of the alert agent are explained in this Pacemaker
[document](https://clusterlabs.org/pacemaker/doc/2.1/Pacemaker_Explained/singlehtml/#writing-an-alert-agent).

Download the script file `gcp_crm_alert.sh` from this project
and save it locally in the VM where the Pacemaker cluster is deployed.
Under root user, add exec flag for the script and execute deployment with:

```
chmod +x ./gcp_crm_alert.sh
./gcp_crm_alert.sh -d
```

If the deployment runs successfully,
you will see the following INFO log messages:

* In RHEL

```
gcp_crm_alert.sh:2022-01-24T23:48:30+0000:INFO:'pcs alert recipient add gcp_cluster_alert value=gcp_cluster_alerts id=gcp_cluster_alert_recepient options value=/var/log/crm_alerts_log' rc=0
```

* In SLES

```
gcp_crm_alert.sh:2022-01-25T00:13:27+00:00:INFO:'crm configure alert gcp_cluster_alert /usr/share/pacemaker/alerts/gcp_crm_alert.sh meta timeout=10s timestamp-format=%Y-%m-%dT%H:%M:%S.%06NZ to { /var/log/crm_alerts_log attributes gcloud_timeout=5 gcloud_cmd=/usr/bin/gcloud }' rc=0
```

In an event of cluster node, resource or node failover or failed action,
the Pacemaker triggers the alert mechanism. The details are getting
published in Cloud Logging. Using the following example filter,
you may find the log information:

```
timestamp>="2022-01-25T00:00:00Z" timestamp<="2022-01-25T02:00:00Z"
jsonPayload.CRM_alert_kind="resource"
```

In order to learn more about the GCP Cloud Logging queries,
navitage to the page
[Build queries in the Logs Explorer](https://cloud.google.com/logging/docs/view/building-queries).
Further information about how to create notifications out of the Cloud
Logging, read the page
[Managing Log-based Alerts](https://cloud.google.com/logging/docs/alerting/log-based-alerts).

__This is not an officially supported Google product__

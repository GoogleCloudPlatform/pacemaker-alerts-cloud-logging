#!/bin/bash
# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#
#
# Script for configuring Pacemaker alerting for the cluster events.
# Run the script for deployment with:
#    ./gcp_crm_alert.sh -d
# Print a quick help info:
#    ./gcp_crm_alert.sh -h
#
#
#
# Pacemaker passes instance attributes to alert agents as environment variables.
# The followings are the supported variables and their default values.
gcloud_cmd_default="gcloud"
: ${gcloud_cmd=${gcloud_cmd_default}}
gcloud_timeout_default="10"
: ${gcloud_timeout=${gcloud_timeout_default}}

# This script name
this_script=$(basename $0)

# The location of the alert script deployment
crm_alerts_dir="/usr/share/pacemaker/alerts"
crm_alerts_log="/var/log/crm_alerts_log"
os_nickname=


# Logging the action details. It logs into the console as well as
# into the log file specified in above.
# 1-  log severity
# 2-  log message
#
gcp_crm::log() {
  echo "${this_script}:$(date --iso-8601=seconds):${1}:${2}" \
    | tee -a "${crm_alerts_log}"
}


# Find the OS distribution. Supported are RH and SUSE
#
gcp_crm::validate() {
  local os_cpe_name os_name output rc
  os_cpe_name=$(hostnamectl 2>/dev/null | grep -P -o "cpe:.+")
  os_name=$(grep "PRETTY_NAME" /etc/os-release | cut -f2 -d"=")
  if [[ "${os_cpe_name}" =~ ":suse:" ]] ; then
    os_nickname="suse"
  elif [[ "${os_cpe_name}" =~ ":redhat:" ]] ; then
    os_nickname="redhat"
  else
    gcp_crm::log ERROR "unsupported OS version (${os_cpe_name}) (${os_name})"
    return 1
  fi

  output=$(sudo crm_mon --version 2>&1) ; rc=$?
  main::log INFO "cluster version info returned (${rc}) (${output})"
  return ${rc}
}


# Find the cluster user `hacluster`
# If not found, use the root user for the file access.
#
gcp_crm::find_user() {
  local effective_user
  local cluster_user="hacluster"
  id -u "${cluster_user}" > /dev/null 2>&1
  [[ $? -eq 0 ]] && effective_user="${cluster_user}" || effective_user="root"

  # Make sure the effective user has home directory
  # Silently create the home directory as this is required for
  # the gcloud to function with no warnings
  local homedir usergrp
  homedir=$(eval echo "~${effective_user}")
  usergrp=$(getent group | grep $(id -g "${effective_user}") | cut -f1 -d':')
  if [[ ! -d "${homedir}" ]] ; then
    mkdir -p "${homedir}"
    chown "${effective_user}:${usergrp}" "${homedir}"
    chmod 700 "${homedir}"
    gcp_crm::log INFO "home directory created for ${effective_user} - ${homedir}"
  fi

  # Print out the effective user
  echo "${effective_user}"
}


# Set the log file permissions
#
gcp_crm::log_setup() {
  touch "${crm_alerts_log}"
  chown $(gcp_crm::find_user):root "${crm_alerts_log}"
  chmod 664 "${crm_alerts_log}"
}


# Deploy the alert script into the Pacemaker
#
gcp_crm::alert_deploy() {
  gcp_crm::validate || return $?

  local cmd rc
  declare -a cmd

  if [[ ! -d "${crm_alerts_dir}" ]] ; then
    gcp_crm::log WARNING "'${crm_alerts_dir}' does not exist."
    cmd=( mkdir -p "${crm_alerts_dir}" )
    "${cmd[@]}"
    gcp_crm::log INFO "'${cmd[*]}' rc=$?"
  fi

  local depl_path="${crm_alerts_dir}/${this_script}"
  cp "${0}" "${depl_path}"
  chown $(gcp_crm::find_user):root "${depl_path}"
  chmod 550 "${depl_path}"
  echo "# Deployed on $(date)" >> "${depl_path}"
  gcp_crm::log INFO "created script '${depl_path}'"

  # SUSE and RH support different command line parameters
  # The following is setup procedure for the Pacemaker alerts.
  if [[ "${os_nickname}" = "redhat" ]] ; then

    # Delete previous alert, if any
    cmd=( pcs alert remove gcp_cluster_alert )
    "${cmd[@]}" ; rc=$?
    gcp_crm::log INFO "'${cmd[*]}' rc=${rc}"

    # Create the alert configuration / RedHat
    cmd=( pcs alert create "path=${depl_path}" "id=gcp_cluster_alert" \
      "description=\"Cluster alerting for ${HOSTNAME}\"" \
      options "gcloud_timeout=5" "gcloud_cmd=/usr/bin/gcloud" \
      meta "timeout=10s" "timestamp-format=%Y-%m-%dT%H:%M:%S.%06NZ" )
    "${cmd[@]}" ; rc=$?
    gcp_crm::log INFO "'${cmd[*]}' rc=${rc}"
    if [[ ${rc} -ne 0 ]] ; then return ${rc} ; fi

    # Add the recepient; this will appear in the Cloud Console path
    cmd=( pcs alert recipient add "gcp_cluster_alert" \
      "value=gcp_cluster_alerts" "id=gcp_cluster_alert_recepient" \
      options "value=${crm_alerts_log}" )
    "${cmd[@]}" ; rc=$?
    gcp_crm::log INFO "'${cmd[*]}' rc=${rc}"
    if [[ ${rc} -ne 0 ]] ; then return ${rc} ; fi

    # If you need to find the current active Pacemaker alerts
    # run the command below
    #   pcs alert show

  elif [[ "${os_nickname}" = "suse" ]] ; then

    # Delete previous alert, if any
    cmd=( crm configure delete gcp_cluster_alert )
    "${cmd[@]}" ; rc=$?
    gcp_crm::log INFO "'${cmd[*]}' rc=${rc}"

    # Create the alert configuration / SUSE
    cmd=( crm configure alert "gcp_cluster_alert" "${depl_path}" \
      meta "timeout=10s" "timestamp-format=%Y-%m-%dT%H:%M:%S.%06NZ" \
      to "{" "${crm_alerts_log}" \
        attributes "gcloud_timeout=5" "gcloud_cmd=/usr/bin/gcloud" "}" )
    "${cmd[@]}" ; rc=$?
    gcp_crm::log INFO "'${cmd[*]}' rc=${rc}"
    if [[ ${rc} -ne 0 ]] ; then return ${rc} ; fi

  fi

  return 0
}


# Find a proper python version for gcloud
#
gcp_crm::setup_python() {
  : ${CLOUDSDK_PYTHON=python}
  local pver python_path
  for python_path in /usr/bin/python /usr/bin/python3 python ; do
    pver=$( "${CLOUDSDK_PYTHON}" --version 2>&1 | grep -Po '[0-9]+\.[0-9]+' )
    gcp_crm::log INFO "CLOUDSDK_PYTHON='${CLOUDSDK_PYTHON}' pver='${pver}'"
    if [[ (( ${pver} > 3.4 )) ]] ; then return 0 ; fi
    if [[ (( ${pver} > 2.6 )) ]] ; then return 0 ; fi
    CLOUDSDK_PYTHON="${python_path}"
  done
  gcp_crm::log ERROR "Unable to find proper python version."
  return 1
}


# Cloud logging utility ; parameters:
#  1-  the logging severity: INFO, WARNING, ERROR, FATAL
#  2-  the log message
#
gcp_crm::gcloud_log() {
  gcp_crm::setup_python || return $?
  export CLOUDSDK_PYTHON

  local cmd rc output
  declare -a cmd

  # Send the log to the recepient folder followed by the hostname
  cmd=( timeout "${gcloud_timeout}" "${gcloud_cmd}" "--quiet" "logging" "write" \
    "${HOSTNAME}/${CRM_alert_recipient}" "${2}" "--severity=${1}" "--payload-type=json" )

  # The user may not have the bash set
  output=$(echo "${cmd[@]}" | /bin/bash 2>&1) ; rc=$?

  local log_level dbg_info
  if [[ ${rc} -eq 0 ]] ; then
    log_level="INFO"
  else
    log_level="WARNING"
    dbg_info="user { $( whoami ) }  env { $( env | tr '\012' '#' ) }"
  fi
  gcp_crm::log "${log_level}" \
    "command=(${cmd[*]}) output=(${output}) ${dbg_info} rc=${rc}"

  return ${rc}
}


# Sanity check for the `gcloud` command
#
gcp_crm::gcloud_validate() {
  if [[ ! -f "${gcloud_cmd}" ]]; then
    gcp_crm::log WARNING \
      "gcloud command not found at '${gcloud_cmd}', using default ${gcloud_cmd_default}"
    gcloud_cmd=${gcloud_cmd_default}
  fi
}


# Build the JSON payload for the Cloud Logging message
# Detailed description of the variables can be found in:
# https://clusterlabs.org/pacemaker/doc/2.1/Pacemaker_Explained/singlehtml/#writing-an-alert-agent
# These alerts can be consumed out of the GCP Cloud Logging using the logging based
# alert feature as explained in the documentation:
# https://cloud.google.com/logging/docs/alerting/log-based-alerts
#
gcp_crm::json() {
  local crm_vars crm_var
  declare -a crm_vars
  crm_vars=( \
      "CRM_alert_attribute_name" \
      "CRM_alert_attribute_value" \
      "CRM_alert_desc" \
      "CRM_alert_exec_time" \
      "CRM_alert_interval" \
      "CRM_alert_kind" \
      "CRM_alert_node" \
      "CRM_alert_node_sequence" \
      "CRM_alert_nodeid" \
      "CRM_alert_rc" \
      "CRM_alert_recipient" \
      "CRM_alert_rsc" \
      "CRM_alert_status" \
      "CRM_alert_target_rc" \
      "CRM_alert_task" \
      "CRM_alert_timestamp" \
      "CRM_alert_timestamp_epoch" \
      "CRM_alert_timestamp_usec" \
      "CRM_alert_version" \
    )

  local x=0
  local len=${#crm_vars[@]}

  echo -n "'{"
  for crm_var in ${crm_vars[@]} ; do
    x=$((${x}+1))
    echo -n "\"${crm_var}\":\"${!crm_var}\""
    if [[ ${x} -lt ${len} ]] ; then echo -n "," ; fi
  done
  echo -n "}'"
}


# The main alerting utility
# When executed with the parameter `-d`, this script is getting
# deployed and activated in the Pacemaker.
gcp_crm::main() {
  if [[ "$1" = "-d" ]] ; then
    gcp_crm::log_setup
    gcp_crm::alert_deploy
    return $?
  fi

  # Quick help information
  if [[ "$1" = "-h" ]] ; then
    >&2 echo "Deploy this alert script in pacemaker with"
    >&2 echo "  $0 -d"
    >&2 echo "Deployment and runtime log file is ${crm_alerts_log}"
    return 0
  fi

  gcp_crm::log INFO "parameters ($*)"

  if [[ -z "${CRM_alert_recipient}" ]] ; then
    gcp_crm::log WARNING \
      "requires a recipient configured with a Google Cloud Logging folder"
    return 1
  fi

  local json_info log_level rc
  json_info="$(gcp_crm::json)"

  case $CRM_alert_kind in
    node|fencing )
      log_level="WARNING"
        ;;
    *)
      log_level="INFO"
        ;;
  esac

  gcp_crm::gcloud_validate
  gcp_crm::gcloud_log "${log_level}" "${json_info}" ; rc=$?

  [[ ${rc} -eq 0 ]] && log_level="INFO" || log_level="WARNING"
  gcp_crm::log "${log_level}" "gcloud_log exited ${rc}"
  return ${rc}
}

gcp_crm::main $*
exit $?

# end of gcp_crm_alert.sh

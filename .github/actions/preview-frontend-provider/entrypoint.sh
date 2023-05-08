#!/bin/bash

set -eu

# env from github action inputs
declare -r USE_PUBLIC_RUNNER="${USE_PUBLIC_RUNNER}"
declare BUILD_PATH="${BUILD_PATH}"; [[ ${BUILD_PATH:0:1} == "/" ]] && BUILD_PATH=${BUILD_PATH:1} # If the first character is "/", remove it

# env using this .sh
declare -r GIT_REPO=$(awk -F '/' '{ print $NF }' <<< "${GITHUB_REPOSITORY}") || return 1
declare -r GIT_EVENT_PR_NUMBER=$(jq '.pull_request.number' /github/workflow/event.json) || return 1
declare -r GIT_EVENT_PR_MERGED=$(jq '.pull_request.merged' /github/workflow/event.json) || return 1
declare -r GIT_EVENT_ACTION=$(jq '.action' /github/workflow/event.json) || return 1
declare -r BUCKET_NAME="preview-frontend-provider"
declare -r URL_PREFIX="dev.fe.lunit.io"
declare -r CSV_FILE="app-url-info.csv"

declare CURRENT_DIR=$(pwd)
declare RANDOM_URL

################################################################################
# Functions
################################################################################

init() {
  # download app-url-info.csv from s3
  aws s3 cp "s3://${BUCKET_NAME}/${CSV_FILE}" "${CURRENT_DIR}/${CSV_FILE}" || ( echo "::error:: Failed S3 Download to ${CSV_FILE} in ${BUCKET_NAME} bucket. Use correct ACCESS_KEY" && return 1 )

  # if there is an url belonging to that PR number, get the url
  RANDOM_URL=$(awk -F ',|, ' -v name="${GIT_REPO}" -v pr="${GIT_EVENT_PR_NUMBER}" '$1 == name  && $4 == pr { print $3 }' "${CURRENT_DIR}/${CSV_FILE}")
}

generate_random_url() {
  local RANDOM_STR
  RANDOM_STR=$(tr -dc a-z0-9 </dev/urandom | head -c 9 ; echo '')

  # generate random str
  while : ;do
    local EXIST_RANDOM_STR
    EXIST_RANDOM_STR=$(awk -F ',|, ' -v var="${RANDOM_STR}" '$0~var{ print $2 }' "${CURRENT_DIR}/${CSV_FILE}")

    # if random string exists already, regenerate
    if [[ -n "${EXIST_RANDOM_STR}" ]];then
      RANDOM_STR=$(tr -dc a-z0-9 </dev/urandom | head -c 9 ; echo '')
    else
      RANDOM_URL="${GIT_REPO}-${RANDOM_STR}"
      break
    fi
  done;

  # add url info to csv
  local STR_TO_ADD
  STR_TO_ADD="${GIT_REPO}, ${RANDOM_STR}, ${RANDOM_URL}, ${GIT_EVENT_PR_NUMBER}" # ex) lunity-front, j37ra1518, lunity-front-j37ra1518, 23

  echo "${STR_TO_ADD}" >> "${CURRENT_DIR}/${CSV_FILE}"
}

generate_nginx_conf() {
  local CURRENT_DIR
  CURRENT_DIR=$(pwd)

  cat << EOF > "${CURRENT_DIR}/${RANDOM_URL}.conf"
  server {
    listen       8080;
    server_name  ${RANDOM_URL}.${URL_PREFIX};
    root   /var/nginx/apps/${GIT_REPO}/${RANDOM_URL}/build ;
    index  index.html index.htm;

    location / {
      add_header Cache-Control "max-age=0, no-cache, no-store, must-revalidate";
      add_header Pragma "no-cache";

      try_files '\$uri' '\$uri.html' '\$uri/' '/index.html';
    }
  }
EOF
# Do not blank in front of EOF above
}

upload_to_s3() {
  # upload build files
  aws s3 cp --recursive --quiet --metadata-directive REPLACE --cache-control no-store,no-cache,must-revalidate "${CURRENT_DIR}/${BUILD_PATH}" "s3://${BUCKET_NAME}/apps/${GIT_REPO}/${RANDOM_URL}/build" || ( echo "::error:: Failed S3 Upload to Build in ${BUCKET_NAME} bucket" && return 1 )

  # upload nginx-server.conf, not nginx.conf
  aws s3 cp --quiet "${CURRENT_DIR}/${RANDOM_URL}.conf" "s3://${BUCKET_NAME}/conf.d/${GIT_REPO}/${RANDOM_URL}.conf" || ( echo "::error:: Failed S3 Upload to nginx-server.conf in ${BUCKET_NAME} bucket" && return 1 )

  # upload csv file
  aws s3 cp --quiet "${CURRENT_DIR}/${CSV_FILE}" "s3://${BUCKET_NAME}" || ( echo "::error:: Failed S3 Upload to csv in ${BUCKET_NAME} bucket" && return 1 )

  echo "::notice:: Successfully upload to s3"
}

check_provider_health() {
  if [ "${USE_PUBLIC_RUNNER}" = "false" ];then
    # check whether provider was ready and timeout is 60sec
     for ((cnt=0;cnt<20;cnt++)); do
       local PROVIDER_STATUS_CODE # curl's connect timeout is 3sec
       PROVIDER_STATUS_CODE=$(curl --connect-timeout 3 -k -s -o /dev/null -w "%{http_code}" "https://${RANDOM_URL}.${URL_PREFIX}")

       if [ "${PROVIDER_STATUS_CODE}" != "200" ];then
         sleep 1
       else
         echo "::notice:: Successfully provider is ready to provide preview"
         return 0
      fi
    done

    echo "::error:: timeout 60sec, Can't check provider"

    delete_from_s3
    delete_url_info_from_csv

    return 1
  else
    sleep 5
    echo "::notice:: Skipped provider health check. Because this repo is public."

    return 0
  fi
}

delete_url_info_from_csv() {
  # delete url info at csv and copy to new csv
  awk -F ',|, ' -v git_repo="${GIT_REPO}" -v pr_num="${GIT_EVENT_PR_NUMBER}" '$1 != git_repo || $4 != pr_num {print}' "${CURRENT_DIR}/${CSV_FILE}" > "${CURRENT_DIR}/temp-${CSV_FILE}"

  # and rename new csv to origin csv
  mv "${CURRENT_DIR}/temp-${CSV_FILE}" "${CURRENT_DIR}/${CSV_FILE}"

  # reUpload csv file
  aws s3 cp --quiet "${CURRENT_DIR}/${CSV_FILE}" "s3://${BUCKET_NAME}" || ( echo "::error:: Failed S3 Upload to csv in ${BUCKET_NAME} bucket" && return 1 )
}

delete_from_s3() {
  # find random_url to remove
  local RANDOM_URLS_TO_REMOVE
  RANDOM_URLS_TO_REMOVE=($(awk -F ',|, ' -v git_repo="${GIT_REPO}" -v pr_num="${GIT_EVENT_PR_NUMBER}" '$1 == git_repo && $4 == pr_num {print $3}' "${CURRENT_DIR}/${CSV_FILE}"))

  # delete build files to found
  for RANDOM_URL in "${RANDOM_URLS_TO_REMOVE[@]}"; do
    # apps
    aws s3 rm --recursive --quiet "s3://${BUCKET_NAME}/apps/${GIT_REPO}/${RANDOM_URL}" || ( echo "::error:: Failed S3 Delete Build in ${BUCKET_NAME} bucket" && return 1 )
    # conf.d
    aws s3 rm --quiet "s3://${BUCKET_NAME}/conf.d/${GIT_REPO}/${RANDOM_URL}.conf" || ( echo "::error:: Failed S3 Delete conf in ${BUCKET_NAME} bucket" && return 1 )
  done;
}

################################################################################
# Work Flows
################################################################################

init

if [ "${GITHUB_EVENT_NAME}" == "pull_request" ] && [ "${GIT_EVENT_PR_MERGED}" == "true" ] || [ "${GIT_EVENT_ACTION}" == "\"closed\"" ];then
  delete_from_s3
  echo "::notice:: Successfully delete preview url ${RANDOM_URL}.${URL_PREFIX}"

  delete_url_info_from_csv
  echo "::notice:: Successfully delete url_info about ${RANDOM_URL}.${URL_PREFIX}"

elif [ "${GITHUB_EVENT_NAME}" == "pull_request" ] && [ "${GIT_EVENT_PR_MERGED}" == "false" ];then
  # create a new URL if no URL is assigned to PR
  if [ -z "${RANDOM_URL}" ];then
    generate_random_url
  fi

  generate_nginx_conf # continue to override nginx_conf
  upload_to_s3
  check_provider_health

  # for outputs in action.yml
  echo "random-url=https://${RANDOM_URL}.${URL_PREFIX}" >> $GITHUB_OUTPUT

  echo "::notice:: Successfully get preview url ${RANDOM_URL}.${URL_PREFIX}"
  echo "Deploy preview for _${GIT_REPO}_ ready! <br><br> ✅ Preview <br> https://${RANDOM_URL}.${URL_PREFIX} " >> "${GITHUB_STEP_SUMMARY}"
fi

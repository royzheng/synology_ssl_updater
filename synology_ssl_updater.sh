#! /usr/bin/env bash
set -eu;

GITHUB_API_KEY=""
GITHUB_REPOSITORY=""
SYNO_BASE_URL=""


_debug() {
  local msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
  echo $msg
}
temp_admin_cleanup() {
    local syno_user="$1"
    _debug "清除nas临时管理员$syno_user"
    synouser --del "$syno_user" >/dev/null 2>/dev/null || true
}
temp_admin_create() {
    local syno_user="$1"
    local syno_pass="$2"
    _debug "开始创建nas临时管理员$syno_user"
    synouser --add "$syno_user" "$syno_pass" "" 0 "sc-acmesh-tmp@roy.cc" 0 >/dev/null
    cur_admins=$(synogroup --get administrators | awk -F '[][]' '/Group Members/,0{if(NF>1)printf "%s ", $2}')
    synogroup --member administrators $cur_admins $syno_user >/dev/null
}

TMP_SYNO_CERT_DIR="/tmp/syno_certs"
rm -rf $TMP_SYNO_CERT_DIR
mkdir -p $TMP_SYNO_CERT_DIR
TMP_SYNO_CERT_KEY_PATH="$TMP_SYNO_CERT_DIR/www.key"
TMP_SYNO_CERT_CA_PATH="$TMP_SYNO_CERT_DIR/www.ca.cert"
TMP_SYNO_CERT_FULLCHAIN_PATH="$TMP_SYNO_CERT_DIR/www.pem"
GITHUB_AUTH="Authorization: Bearer $GITHUB_API_KEY"
_debug "开始下载SSL证书"
GITHUBAPI_ENDPOINT="https://api.github.com/repos/$GITHUB_REPOSITORY/releases/tags/certs"
assets=$(curl -s -L \
  -H "Accept: application/vnd.github+json" \
  -H "$GITHUB_AUTH" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "$GITHUBAPI_ENDPOINT")
hash=$(echo "$assets" | jq -r '.assets | map({(.name): .url}) | add')
declare -A hash
while IFS=":" read -r key value; do
    key=$(echo $key | tr -d '"')
    value=$(echo $value | tr -d '"')
    hash["$key"]="$value"
done <<< "$hash"
curl -s -L \
  -H "Accept: application/octet-stream" \
  -H "$GITHUB_AUTH" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -o "$TMP_SYNO_CERT_KEY_PATH" \
  ${hash['www.key']}
curl -s -L \
  -H "Accept: application/octet-stream" \
  -H "$GITHUB_AUTH" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -o "$TMP_SYNO_CERT_FULLCHAIN_PATH" \
  ${hash['www.fullchain.cer']}
curl -s -L \
  -H "Accept: application/octet-stream" \
  -H "$GITHUB_AUTH" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -o "$TMP_SYNO_CERT_CA_PATH" \
  ${hash['www.ca.cer']}
_debug "下载SSL证书完成"

SYNO_USERNAME=sc-acmesh-tmp
SYNO_PASSWORD=WwStkrx990aQ4Zyd

temp_admin_cleanup "$SYNO_USERNAME"
temp_admin_create "$SYNO_USERNAME" "$SYNO_PASSWORD"
_debug "开始上传SSL证书到Nas"
response=$(curl -k -s "$SYNO_BASE_URL/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=SYNO.API.Auth")
api_path=$(echo "$response" | grep "SYNO.API.Auth" | sed -n 's/.*"path" *: *"\([^"]*\)".*/\1/p')
api_version=$(echo "$response" | grep "SYNO.API.Auth" | sed -n 's/.*"maxVersion" *: *\([0-9]*\).*/\1/p')
response=$(curl -k -s "$SYNO_BASE_URL/webapi/$api_path?api=SYNO.API.Auth&version=$api_version&method=login&format=sid&account=$SYNO_USERNAME&passwd=$SYNO_PASSWORD&enable_syno_token=yes")
sid=$(echo "$response" | grep "sid" | sed -n 's/.*"sid" *: *"\([^"]*\).*/\1/p')
token=$(echo "$response" | grep "synotoken" | sed -n 's/.*"synotoken" *: *"\([^"]*\).*/\1/p')
SYNO_API_TOKEN="X-SYNO-TOKEN: $token"
response=$(curl -k -s -X POST "$SYNO_BASE_URL/webapi/entry.cgi" \
    -H "$SYNO_API_TOKEN" \
    -d "api=SYNO.Core.Certificate.CRT" \
    -d "method=list" \
    -d "version=1" \
    -d "_sid=$sid")
id=$(echo "$response" | sed -n "s/.*\"desc\":\"\",\"id\":\"\([^\"]*\).*/\1/p")
nl="\0015\0012"
delim="--------------------------$(date -u +'%Y%m%d%H%M%S')"
content="--$delim${nl}Content-Disposition: form-data; name=\"key\"; filename=\"www.key\"${nl}Content-Type: application/octet-stream${nl}${nl}$(cat "$TMP_SYNO_CERT_KEY_PATH")\0012"
content="$content${nl}--$delim${nl}Content-Disposition: form-data; name=\"cert\"; filename=\"www.fullchain.cer\"${nl}Content-Type: application/octet-stream${nl}${nl}$(cat "$TMP_SYNO_CERT_FULLCHAIN_PATH")\0012"
content="$content${nl}--$delim${nl}Content-Disposition: form-data; name=\"inter_cert\"; filename=\"www.ca.cert\"${nl}Content-Type: application/octet-stream${nl}${nl}$(cat "$TMP_SYNO_CERT_CA_PATH")\0012"
content="$content${nl}--$delim${nl}Content-Disposition: form-data; name=\"id\"${nl}${nl}$id"
content="$content${nl}--$delim${nl}Content-Disposition: form-data; name=\"desc\"${nl}${nl}"
content="$content${nl}--$delim${nl}Content-Disposition: form-data; name=\"as_default\"${nl}${nl}true"
content="$content${nl}--$delim--${nl}"
content="$(printf "%b_" "$content")"
content="${content%_}"
response=$(curl -k -s -X POST "$SYNO_BASE_URL/webapi/entry.cgi?api=SYNO.Core.Certificate&method=import&version=1&SynoToken=$token&_sid=$sid" \
  -H "Content-Type: multipart/form-data; boundary=${delim}" \
  --data-binary "$content")
_debug "上传SSL证书到Nas完成:$response"
curl -k -s "$SYNO_BASE_URL/webapi/$api_path?api=SYNO.API.Auth&version=$api_version&method=logout&_sid=$sid"
temp_admin_cleanup "$SYNO_USERNAME"
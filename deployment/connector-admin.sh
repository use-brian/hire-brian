#!/usr/bin/env bash

read_env_value() {
  local file=$1 wanted=$2 key value
  while IFS='=' read -r key value; do
    if [ "$key" = "$wanted" ]; then printf '%s' "$value"; return 0; fi
  done < "$file"
  return 1
}

upsert_env_value() {
  local file=$1 wanted=$2 value=$3 key line temp
  temp=$(mktemp "${file}.XXXXXX")
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    [ "$key" = "$wanted" ] || printf '%s\n' "$line" >> "$temp"
  done < "$file"
  printf '%s=%s\n' "$wanted" "$value" >> "$temp"
  chown --reference="$file" "$temp"
  chmod --reference="$file" "$temp"
  mv -f "$temp" "$file"
}

remove_env_values() {
  local file=$1 line key candidate remove temp
  shift
  temp=$(mktemp "${file}.XXXXXX")
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    remove=0
    for candidate in "$@"; do [ "$key" = "$candidate" ] && remove=1; done
    [ "$remove" = 1 ] || printf '%s\n' "$line" >> "$temp"
  done < "$file"
  chown --reference="$file" "$temp"
  chmod --reference="$file" "$temp"
  mv -f "$temp" "$file"
}

connector_variable() {
  case "$1" in
    discord) printf ENABLE_DISCORD ;;
    whatsapp) printf ENABLE_WHATSAPP ;;
    wechat) printf ENABLE_WECHAT ;;
    feishu) printf ENABLE_FEISHU ;;
    *) echo "Connector must be discord, whatsapp, wechat, or feishu." >&2; return 1 ;;
  esac
}

new_connector_secret() {
  openssl rand -base64 36 | tr -d '\n'
}

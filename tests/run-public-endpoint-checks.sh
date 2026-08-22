#!/usr/bin/env bash

set -u
set -o pipefail

PASSED=0
FAILED=0

if [[ -z ${MIPILOT_PUBLIC_ENDPOINTS:-} ]]; then
  echo "缺少 MIPILOT_PUBLIC_ENDPOINTS."
  echo '每行格式: 名称<Tab>预期状态码<Tab>strict|insecure<Tab>URL'
  exit 2
fi

while IFS=$'\t' read -r label expected tls_mode url extra; do
  [[ -n $label || -n $expected || -n $tls_mode || -n $url || -n $extra ]] || continue
  if [[ -z $label || ${#label} -gt 64 || $label =~ [[:cntrl:]] || $url =~ [[:cntrl:]] ||
        ! $expected =~ ^[0-9]{3}$ ||
        ( $tls_mode != strict && $tls_mode != insecure ) ||
        ! $url =~ ^https?:// || -n $extra ]]; then
    echo "[FAIL] 公网端点输入格式无效."
    FAILED=$((FAILED + 1))
    continue
  fi

  curl_arguments=(
    -sS
    -o /dev/null
    --noproxy '*'
    --connect-timeout 5
    --max-time 15
    -w $'%{http_code}\t%{time_total}'
  )
  [[ $tls_mode == insecure ]] && curl_arguments+=(-k)

  result="$(curl "${curl_arguments[@]}" "$url" 2>/dev/null)"
  status=$?
  IFS=$'\t' read -r actual elapsed <<<"$result"
  if (( status == 0 )) && [[ $actual == "$expected" && $elapsed =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '[PASS] %s: HTTP %s, %ss\n' "$label" "$actual" "$elapsed"
    PASSED=$((PASSED + 1))
  else
    printf '[FAIL] %s: expected HTTP %s, actual %s, curl=%s\n' \
      "$label" "$expected" "${actual:-000}" "$status"
    FAILED=$((FAILED + 1))
  fi
done <<<"$MIPILOT_PUBLIC_ENDPOINTS"

printf '\nResult: %s passed, %s failed\n' "$PASSED" "$FAILED"
(( FAILED == 0 && PASSED > 0 ))

#!/usr/bin/env bash
# 一加 Ace 2（oneplus_ace2_b）标准构建方案 —— 与用户确认过的固定组合
#
# 用法：
#   GITHUB_TOKEN=xxx ./dispatch-ace2.sh                # 用固定方案触发
#   GITHUB_TOKEN=xxx DRY_RUN=1 ./dispatch-ace2.sh      # 只打印 payload
#
# 与工作流 .github/workflows/Build Kernel OnePlus.yml 的 inputs 一一对应。
set -euo pipefail

REPO="${REPO:-mm53m/Action-Build}"
WORKFLOW="${WORKFLOW:-Build Kernel OnePlus.yml}"
REF="${REF:-FinaSU}"

payload=$(cat <<'JSON'
{
  "ref": "FinaSU",
  "inputs": {
    "FILE": "oneplus_ace2_b",
    "KSU_META": "master/master/",
    "FAST_BUILD": "true",
    "KPM": "N/A",
    "LSM_BBG": "true",
    "NETFILTER": "true",
    "CCM": "true",
    "DROID_SPACES": "true",
    "RE_KERNEL": "true",
    "LZ4_UPDATE": "true",
    "ZRAM": "0/lz4kd/8589934592",
    "SUSFS_META": "",
    "SUSFS_CI": "CI",
    "SUSFS_DEV": "false",
    "SCHED_HMBIRD": "false",
    "UNICODE_BYPASS": "false",
    "SUFFIX": "",
    "RESUBLEVEL": "",
    "DYNAMIC_REPO": "Numbersf",
    "BUILD_TIME": "Wed Jul 15 11:18:49 UTC 2026",
    "SPACE_NOCLEAN": "false",
    "BUILD_NOCACHE": "false"
  }
}
JSON
)

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "$payload"
  exit 0
fi

: "${GITHUB_TOKEN:?需要 GITHUB_TOKEN（repo + workflow 权限）}"

curl -sS -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${REPO}/actions/workflows/$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$WORKFLOW")/dispatches" \
  -d "$payload" \
  -o /dev/null -w 'dispatch %{http_code}\n'

#!/usr/bin/env bash
# ==============================================================================
# fork_center.sh —— 从技术底座 opic-techbase fork 创建能力中心 REPO
# ==============================================================================
# 规则依据: OPIC-TECH-01（opic-design/docs/rules/opic-tech-fork-rule.md）
#   所有能力中心必须直接 fork 自技术底座 opic-techbase。
#
# 用法:
#   bash fork_center.sh <能力中心英文名> <组织名>
#   例: bash fork_center.sh model-center opic-ontology
#
# 输出: 新 REPO 名 = 能力中心英文名（<组织>/<中心名>）
#
# 实现说明（gitcode API 实测行为，2026-10-03）:
#   - gitcode 的 fork API 不支持 namespace 目标参数（一律落到个人空间）、
#     PATCH 仅改显示名不改 path —— 故采用「组织建仓 + mirror push」等价实现，
#     血缘以 git remote upstream + 仓库描述 "forked from ..." 标注。
#   - API 有分钟级限流（建仓/删除 1 次/分钟），脚本内置 429 退避重试。
#
# 前置: git credential store 中存在 gitcode.com 的 opic1 凭证（token）。
# ==============================================================================
set -euo pipefail

CENTER_NAME="${1:-}"
ORG="${2:-}"
UPSTREAM_ORG="${UPSTREAM_ORG:-opic-ontology}"
UPSTREAM_REPO="${UPSTREAM_REPO:-opic-techbase}"
API="https://gitcode.com/api/v5"

[[ -n "$CENTER_NAME" && -n "$ORG" ]] || die "用法: bash fork_center.sh <能力中心英文名> <组织名>"
[[ "$CENTER_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "中心英文名须为小写字母/数字/连字符（REPO 名即它）: $CENTER_NAME"

# ── 凭证 ─────────────────────────────────────────────────────────────────────
TOKEN=$(printf "protocol=https\nhost=gitcode.com\nusername=opic1\n" | git credential fill 2>/dev/null | sed -n 's/^password=//p')
[[ -n "$TOKEN" ]] || die "未取得 gitcode 凭证（git credential fill 失败）"

api() { # api <method> <path> [body]
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -s -m 30 -X "$method" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "$body" "$API$path"
  else
    curl -s -m 30 -X "$method" -H "Authorization: Bearer $TOKEN" "$API$path"
  fi
}

# 限流退避（429 → 等待 65s 重试，最多 3 次）
api_retry() {
  local method="$1" path="$2" body="${3:-}" resp="" n=0
  while :; do
    if [[ -n "$body" ]]; then
      resp=$(curl -s -m 30 -X "$method" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$body" "$API$path")
    else
      resp=$(curl -s -m 30 -X "$method" -H "Authorization: Bearer $TOKEN" "$API$path")
    fi
    if grep -q '"error_code":429' <<<"$resp"; then
      n=$((n + 1))
      [[ $n -ge 3 ]] && die "API 限流重试 3 次仍失败: $path"
      echo "  [限流] 等待 65s 后重试（$n/3）…" >&2
      sleep 65
      continue
    fi
    echo "$resp"
    return 0
  done
}

die() { echo "[FAIL] $*" >&2; exit 1; }
ok()  { echo "[ OK ] $*"; }

# ── ① 前置检查：底座存在、目标仓不存在 ────────────────────────────────────────
resp=$(api GET "/repos/$UPSTREAM_ORG/$UPSTREAM_REPO")
grep -q '"full_name"' <<<"$resp" || die "上游底座仓 $UPSTREAM_ORG/$UPSTREAM_REPO 不可访问"
ok "上游底座: $UPSTREAM_ORG/$UPSTREAM_REPO"

resp=$(api GET "/repos/$ORG/$CENTER_NAME")
if grep -q '"full_name"' <<<"$resp"; then
  die "目标仓 $ORG/$CENTER_NAME 已存在（避免覆盖，终止）"
fi
ok "目标仓可用: $ORG/$CENTER_NAME"

# ── ② 组织下建仓（私有组须 private:true，统一用 true）────────────────────────
DESC="forked from $UPSTREAM_ORG/$UPSTREAM_REPO (OPIC-TECH-01)"
resp=$(api_retry POST "/orgs/$ORG/repos" "{\"name\":\"$CENTER_NAME\",\"private\":true,\"description\":\"$DESC\"}")
grep -q '"full_name"' <<<"$resp" || die "建仓失败: $(echo "$resp" | head -c 200)"
ok "建仓: $ORG/$CENTER_NAME"

# ── ③ mirror push（全部分支 + tags）──────────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git clone --quiet --mirror "https://opic1@gitcode.com/$UPSTREAM_ORG/$UPSTREAM_REPO.git" "$TMP/mirror.git" \
  || die "clone 上游失败"
cd "$TMP/mirror.git"
git push --quiet --mirror "https://opic1@gitcode.com/$ORG/$CENTER_NAME.git" \
  || die "mirror push 失败"
ok "代码推送完成（全部分支 + tags）"

# ── ④ 血缘标注：clone 检查 + 输出接入指引 ─────────────────────────────────────
cd "$TMP"
git clone -q "https://opic1@gitcode.com/$ORG/$CENTER_NAME.git" check
cd check
git remote add upstream "https://opic1@gitcode.com/$UPSTREAM_ORG/$UPSTREAM_REPO.git"
git log --oneline -1 | sed 's/^/  HEAD: /'
ok "血缘: remote upstream 已可添加（见上方命令）"

UPSTREAM="https://gitcode.com/$UPSTREAM_ORG/$UPSTREAM_REPO"
NEWREPO="https://gitcode.com/$ORG/$CENTER_NAME"
printf "%s\n" "────────────────────────────────────────────────────────────────"
printf "新 REPO 创建完成: %s\n" "$NEWREPO"
printf "  fork 源 : %s（OPIC-TECH-01）\n" "$UPSTREAM"
printf "  后续三步（opic-techbase README §九）:\n"
printf "    1. configs/config.yml → database.schema = o<域码>（OPIC-DB-SCHEMA-01）\n"
printf "    2. migrations/ 清示例、落本中心 DDL\n"
printf "    3. 菜单/路由/前端按中心定制\n"
printf "  本地开发:\n"
printf "    git clone %s.git\n" "$NEWREPO"
printf "    cd %s && git remote add upstream %s.git\n" "$CENTER_NAME" "$UPSTREAM"
printf "────────────────────────────────────────────────────────────────\n"
printf "输出 REPO 名: %s\n" "$CENTER_NAME"

#!/usr/bin/env bash
#
# deploy_connect_lambdas.sh
#
# 交互式地把三个 Lambda 函数和三条 contact flow 部署到两个 Amazon Connect 实例。
#
# 处理函数的代码不在本脚本里。每个函数的源码位于
# lambdas/<函数名>/lambda_function.py，打包时直接从那里压缩，
# 因此改代码不需要碰部署逻辑。
#
#   实例 #1，版本必须是「Amazon Connect Customer Basic」
#     Lambda：ConnectGetCustomerModel - 返回某个 CustomerNumber 最近一条记录的
#             ModelNumber
#     Lambda：ConnectGetAgentName - 把 Connect 用户 ID 换成坐席姓名，供弹屏使用
#     Flow  ：Customer Inbound - ScreenPop.json
#     Flow  ：Customer Inbound - AI IVR and Agent Transfer.json
#
#   实例 #2，版本必须是「Amazon Connect Customer」
#     Lambda：ConnectSaveCustomerModel - 把 {CustomerNumber, ModelNumber} 写入
#             DynamoDB（表不存在时自动创建）
#     Flow  ：AI Self-Service IVR - Model Capture.json
#
# 弹屏流程先于入呼流程部署，因为入呼流程的 DefaultAgentUI 事件钩子在导入时
# 是按 flow 名称解析的。
#
# 所有资源名称（三个 Lambda、IAM 角色、DynamoDB 表、三条 flow）都可以带同一个
# 后缀，这样同一账号里可以并存多套部署（运行时询问，或用 NAME_SUFFIX 预设）。
#
# 两个实例的版本会在部署任何资源之前校验。脚本还会要求输入 Lex V2（对话式 AI）
# bot ARN 和 Amazon Q in Connect AI agent ARN，确认两者存在，并改写导入的 flow，
# 使其中每个 ARN 都指向目标实例里的资源。
#
# Amazon Connect 只能调用同区域的 Lambda，所以每个函数都部署到它所服务实例的
# 区域。save 和 get 两个函数共用一张 DynamoDB 表并显式指定区域访问，因此两个
# 实例位于不同区域时依然可用。
#
set -euo pipefail

#-------------------------------------------------------------------------------
# 默认值
#-------------------------------------------------------------------------------
DEFAULT_SAVE_FN="ConnectSaveCustomerModel"
DEFAULT_GET_FN="ConnectGetCustomerModel"
DEFAULT_AGENT_FN="ConnectGetAgentName"
DEFAULT_TABLE="ConnectCustomerModel"
DEFAULT_ROLE="ConnectCustomerModelLambdaRole"
PY_RUNTIME="python3.12"

# Connect 实例的两个版本名称。
EDITION_FULL="Amazon Connect Customer"
EDITION_BASIC="Amazon Connect Customer Basic"

# 每个实例要求的版本。可覆盖，以便同一脚本驱动其他环境：
# EXPECTED_EDITION_1=... EXPECTED_EDITION_2=... ./deploy_connect_lambdas.sh
EXPECTED_EDITION_1="${EXPECTED_EDITION_1:-$EDITION_BASIC}"
EXPECTED_EDITION_2="${EXPECTED_EDITION_2:-$EDITION_FULL}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FLOW_FILE_1="$SCRIPT_DIR/Customer Inbound - AI IVR and Agent Transfer.json"
FLOW_FILE_2="$SCRIPT_DIR/AI Self-Service IVR - Model Capture.json"
FLOW_FILE_3="$SCRIPT_DIR/Customer Inbound - ScreenPop.json"

# 每个函数一个目录，目录名就是该函数的默认名称，里面放 Lambda 原样执行的
# lambda_function.py。
LAMBDA_SRC_DIR="$SCRIPT_DIR/lambdas"

# 追加到每个资源名称之后（Lambda、IAM 角色、DynamoDB 表、所有 flow）。
# 预设它可以跳过询问：
# NAME_SUFFIX="TP" ./deploy_connect_lambdas.sh
NAME_SUFFIX="${NAME_SUFFIX-}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log()  { printf '\033[1;34m[信息]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m[成功]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[警告]\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31m[失败]\033[0m  %s\n' "$*" >&2; exit 1; }

ask() { # ask <提示语> <默认值> -> 输出answer
  local prompt="$1" default="$2" answer
  if [[ -n "$default" ]]; then
    read -r -p "$(printf '%s [%s]：' "$prompt" "$default")" answer
  else
    read -r -p "$(printf '%s：' "$prompt")" answer
  fi
  printf '%s' "${answer:-$default}"
}

ask_required() { # ask_required <提示语> -> 输出非空answer
  local prompt="$1" answer=""
  while [[ -z "$answer" ]]; do
    # read 在 stdin 结束时返回非 0。不判断的话，用管道喂输入且喂少了，
    # 这里会变成一个不停打印提示的死循环。
    if ! read -r -p "$prompt" answer; then
      [[ -n "$answer" ]] || die "输入已结束，但此项仍未提供。"
      break
    fi
    [[ -n "$answer" ]] || warn "此项不能为空。"
  done
  printf '%s' "$answer"
}

# 一个后缀要同时满足 Lambda 函数名、IAM 角色名、DynamoDB 表名和 flow 名称的
# 字符限制，所以 [A-Za-z0-9] 之外的字符统一折叠为 "_"，并始终以 "_" 连接。
# 因此 "TP"、"_TP"、"- TP" 和 "tp/2" 分别变成 _TP、_TP、_TP 和 _tp_2。
norm_suffix() { # norm_suffix <原始输入> -> 输出 "" 或 "_<核心>"
  local core
  core="$(sed -E 's/[^A-Za-z0-9]+/_/g; s/^_+//; s/_+$//' <<<"$1")"
  if [[ -n "$core" ]]; then
    printf '_%s' "$core"
  fi
  return 0
}

# 把 MAX_PACKAGE 实例属性的取值翻译成版本名称：
#   true  -> Amazon Connect Customer（完整版，包含全部 AI 能力）
#   false -> Amazon Connect Customer Basic
#
# 注意：MAX_PACKAGE 没有出现在 Connect 公开 API 文档 DescribeInstanceAttribute
# 的 AttributeType 取值列表里，属于未文档化字段，AWS 可能在不通知的情况下修改。
# 因此读不到或取值不认识时一律返回失败，由调用方报错退出，绝不放行到可能错误
# 的实例上。Connect 的版本信息没有其他 API 可查：DescribeInstance 返回的
# Instance 对象里没有任何版本/套餐字段。
instance_edition() { # instance_edition <区域> <实例ID> -> 输出版本名称
  local region="$1" id="$2" value
  value="$(aws connect describe-instance-attribute \
      --region "$region" --instance-id "$id" \
      --attribute-type MAX_PACKAGE \
      --query 'Attribute.Value' --output text 2>/dev/null)" || return 1
  case "$value" in
    true)  printf '%s' "$EDITION_FULL" ;;
    false) printf '%s' "$EDITION_BASIC" ;;
    *)     return 1 ;;
  esac
}

# 读取并校验一个 Connect 实例 ARN。导出 INSTANCE_ARN、INSTANCE_REGION、
# INSTANCE_ACCOUNT、INSTANCE_ID、INSTANCE_ALIAS 和 INSTANCE_EDITION。
read_instance_arn() { # read_instance_arn <序号> <期望版本>
  local ordinal="$1" expected="$2" arn alias edition

  echo
  log "Connect 实例 #${ordinal} 必须是「${expected}」版本。"
  arn="$(ask_required "$(printf '实例 #%s 的 ARN（arn:aws:connect:<区域>:<账号>:instance/<id>）：' "$ordinal")")"

  [[ "$arn" =~ ^arn:aws[a-z-]*:connect:[a-z0-9-]+:[0-9]{12}:instance/[0-9a-f-]{36}$ ]] \
    || die "「${arn}」不是 Connect 实例 ARN，正确格式为 arn:aws:connect:<区域>:<账号>:instance/<uuid>。"

  INSTANCE_ARN="$arn"
  INSTANCE_REGION="$(cut -d: -f4 <<<"$arn")"
  INSTANCE_ACCOUNT="$(cut -d: -f5 <<<"$arn")"
  INSTANCE_ID="${arn##*/}"

  log "正在校验区域 $INSTANCE_REGION 中的实例 $INSTANCE_ID ..."
  alias="$(aws connect describe-instance \
      --region "$INSTANCE_REGION" --instance-id "$INSTANCE_ID" \
      --query 'Instance.InstanceAlias' --output text 2>/dev/null)" \
    || die "实例 $INSTANCE_ID 在 $INSTANCE_REGION 中不存在，或当前凭证无权 describe 它。"
  # 别名现在只用于展示，版本才是判定依据，所以没有别名也不影响。
  [[ -n "$alias" && "$alias" != "None" ]] || alias="(无别名)"

  edition="$(instance_edition "$INSTANCE_REGION" "$INSTANCE_ID")" \
    || die "$(printf '无法判定实例 %s 的版本：读取 MAX_PACKAGE 实例属性失败。\n         请确认当前凭证具备 connect:DescribeInstanceAttribute 权限。\n         该属性未文档化，若 AWS 已将其移除，请改用实例 ID 白名单来校验。' "$INSTANCE_ID")"

  if [[ "$edition" != "$expected" ]]; then
    die "$(printf '实例 #%s（%s，别名 %s）的版本是「%s」，但这一步需要「%s」。请用正确的实例 ARN 重新运行。' \
        "$ordinal" "$INSTANCE_ID" "$alias" "$edition" "$expected")"
  fi

  INSTANCE_ALIAS="$alias"
  INSTANCE_EDITION="$edition"
  ok "实例 #${ordinal} 校验通过：${alias}（${INSTANCE_ID}，${INSTANCE_REGION}，${edition}）。"
}

# 读取并校验 Lex V2 bot ARN，然后解析出 flow 里要用的别名 ARN。导出
# LEX_BOT_ARN、LEX_BOT_ID、LEX_REGION、LEX_BOT_NAME、LEX_ALIAS_ARN 和
# LEX_ALIAS_NAME。
read_lex_bot_arn() { # read_lex_bot_arn <期望区域>
  local expected_region="$1" arn alias_line

  echo
  log "IVR 流程使用的对话式 AI（Amazon Lex V2）bot。"
  arn="$(ask_required '对话式 AI bot 的 ARN（arn:aws:lex:<区域>:<账号>:bot/<botId>）：')"

  [[ "$arn" =~ ^arn:aws[a-z-]*:lex:[a-z0-9-]+:[0-9]{12}:bot/[A-Z0-9]+$ ]] \
    || die "「${arn}」不是 Lex V2 bot ARN，正确格式形如 arn:aws:lex:us-west-2:991727053196:bot/QIHKIB2VL1。"

  LEX_BOT_ARN="$arn"
  local partition account
  partition="$(cut -d: -f2 <<<"$arn")"
  account="$(cut -d: -f5 <<<"$arn")"
  LEX_REGION="$(cut -d: -f4 <<<"$arn")"
  LEX_BOT_ID="${arn##*/}"

  log "正在校验区域 $LEX_REGION 中的 Lex bot $LEX_BOT_ID ..."
  LEX_BOT_NAME="$(aws lexv2-models describe-bot \
      --region "$LEX_REGION" --bot-id "$LEX_BOT_ID" \
      --query 'botName' --output text 2>/dev/null)" \
    || die "Lex bot $LEX_BOT_ID 在 $LEX_REGION 中不存在，或当前凭证无权 describe 它。"

  [[ "$LEX_REGION" == "$expected_region" ]] \
    || die "Lex bot 位于 ${LEX_REGION}，而 Connect 实例位于 ${expected_region}。Amazon Connect 只能使用同区域的 Lex V2 bot。"

  # flow 引用的是 bot 别名而不是 bot 本身。优先选用导出文件里用的那个别名，
  # 否则取第一个可用的。
  alias_line="$(aws lexv2-models list-bot-aliases \
      --region "$LEX_REGION" --bot-id "$LEX_BOT_ID" \
      --query "botAliasSummaries[?botAliasStatus=='Available'].[botAliasName,botAliasId]" \
      --output text 2>/dev/null | sort)" \
    || die "无法列出 Lex bot $LEX_BOT_ID 的别名。"
  [[ -n "$alias_line" ]] \
    || die "Lex bot ${LEX_BOT_NAME}（${LEX_BOT_ID}）没有可用别名。请先构建 bot 并发布别名。"

  local preferred
  preferred="$(grep -i -m1 $'^TestBotAlias\t' <<<"$alias_line" || true)"
  [[ -n "$preferred" ]] || preferred="$(head -n1 <<<"$alias_line")"
  LEX_ALIAS_NAME="$(cut -f1 <<<"$preferred")"
  LEX_ALIAS_ARN="arn:${partition}:lex:${LEX_REGION}:${account}:bot-alias/${LEX_BOT_ID}/$(cut -f2 <<<"$preferred")"
  ok "Lex bot 校验通过：${LEX_BOT_NAME}，别名 ${LEX_ALIAS_NAME}。"
}

# 读取并校验 Q in Connect AI agent 的 ARN。导出 AI_AGENT_ARN、AI_AGENT_NAME、
# ASSISTANT_ID 和 ASSISTANT_ARN。
read_ai_agent_arn() { # read_ai_agent_arn <期望区域>
  local expected_region="$1" arn region resource agent_id

  echo
  log "IVR 流程使用的 Amazon Q in Connect AI agent。"
  arn="$(ask_required 'AI Agent 的 ARN（arn:aws:wisdom:<区域>:<账号>:ai-agent/<assistantId>/<agentId>[:版本]）：')"

  if [[ ! "$arn" =~ ^arn:aws[a-z-]*:wisdom:[a-z0-9-]+:[0-9]{12}:ai-agent/[0-9a-f-]{36}/[0-9a-f-]{36}(:([0-9]+|\$[A-Z]+))?$ ]]; then
    die "「${arn}」不是 AI agent ARN，正确格式形如 arn:aws:wisdom:us-west-2:991727053196:ai-agent/14fe4db3-cca0-4c91-b484-ee7dc6a0e9aa/a0c8d2a9-1d13-4d46-9cc7-6418eac7365e:\$SAVED。"
  fi

  AI_AGENT_ARN="$arn"
  region="$(cut -d: -f4 <<<"$arn")"
  resource="${arn#*:ai-agent/}"     # <assistantId>/<agentId>[:版本]
  ASSISTANT_ID="${resource%%/*}"
  agent_id="${resource#*/}"
  agent_id="${agent_id%%:*}"        # 去掉 :$SAVED / :$LATEST / :N 限定符
  ASSISTANT_ARN="arn:$(cut -d: -f2 <<<"$arn"):wisdom:${region}:$(cut -d: -f5 <<<"$arn"):assistant/${ASSISTANT_ID}"

  log "正在校验区域 $region 中的 AI agent $agent_id ..."
  AI_AGENT_NAME="$(aws qconnect get-ai-agent \
      --region "$region" --assistant-id "$ASSISTANT_ID" --ai-agent-id "$agent_id" \
      --query 'aiAgent.name' --output text 2>/dev/null)" \
    || die "在 $region 的 assistant $ASSISTANT_ID 下找不到 AI agent ${agent_id}。请检查 ARN 和凭证权限。"

  [[ "$region" == "$expected_region" ]] \
    || die "AI agent 位于 ${region}，而 Connect 实例位于 ${expected_region}，两者必须在同一区域。"

  ok "AI agent 校验通过：${AI_AGENT_NAME}。"
}

#-------------------------------------------------------------------------------
# 运行前检查
#-------------------------------------------------------------------------------
command -v aws >/dev/null 2>&1 || die "未找到 aws 命令，请先安装 AWS CLI v2。"
command -v zip >/dev/null 2>&1 || die "未找到 zip 命令，请先安装 zip。"
command -v python3 >/dev/null 2>&1 || die "未找到 python3，改写 contact flow 导出文件时需要它。"
[[ -f "$FLOW_FILE_1" ]] || die "找不到 flow 导出文件：$FLOW_FILE_1"
[[ -f "$FLOW_FILE_2" ]] || die "找不到 flow 导出文件：$FLOW_FILE_2"
[[ -f "$FLOW_FILE_3" ]] || die "找不到 flow 导出文件：$FLOW_FILE_3"

# 期望版本必须是已知取值，否则任何实例都不可能通过校验。
for _edition in "$EXPECTED_EDITION_1" "$EXPECTED_EDITION_2"; do
  [[ "$_edition" == "$EDITION_FULL" || "$_edition" == "$EDITION_BASIC" ]] \
    || die "期望版本「${_edition}」无效，只能是「${EDITION_BASIC}」或「${EDITION_FULL}」。"
done
unset _edition

# 在这里就失败，而不是等问完十几个问题、建好 IAM 角色之后才失败。
for _fn_dir in "$DEFAULT_SAVE_FN" "$DEFAULT_GET_FN" "$DEFAULT_AGENT_FN"; do
  [[ -f "$LAMBDA_SRC_DIR/$_fn_dir/lambda_function.py" ]] \
    || die "找不到 Lambda 处理函数源码：$LAMBDA_SRC_DIR/$_fn_dir/lambda_function.py"
done
unset _fn_dir

echo
echo "=============================================================="
echo " Amazon Connect + Lambda + DynamoDB + contact flow 部署"
echo "=============================================================="
echo
echo " 实例 #1 必须是「${EXPECTED_EDITION_1}」版本"
echo "   -> Lambda $DEFAULT_GET_FN  （读回最新的 ModelNumber）"
echo "   -> Lambda $DEFAULT_AGENT_FN     （为弹屏解析坐席姓名）"
echo "   -> 流程   $(basename "$FLOW_FILE_3")"
echo "   -> 流程   $(basename "$FLOW_FILE_1")"
echo
echo " 实例 #2 必须是「${EXPECTED_EDITION_2}」版本"
echo "   -> Lambda $DEFAULT_SAVE_FN （写入 CustomerNumber + ModelNumber）"
echo "   -> 流程   $(basename "$FLOW_FILE_2")"
echo
echo " 实例版本通过 MAX_PACKAGE 实例属性判定（true 为完整版，false 为 Basic）。"
echo " 随后还会要求输入对话式 AI（Lex V2）bot ARN 和 Amazon Q in Connect"
echo " AI agent ARN。所有输入都会先校验通过才会创建任何资源，一旦不符即退出。"
echo

#-------------------------------------------------------------------------------
# 交互输入 - 两个实例、bot 和 AI agent 全部提前校验
#-------------------------------------------------------------------------------
read_instance_arn 1 "$EXPECTED_EDITION_1"
GET_INSTANCE_ARN="$INSTANCE_ARN"
GET_REGION="$INSTANCE_REGION"
GET_ACCOUNT="$INSTANCE_ACCOUNT"
GET_INSTANCE_ID="$INSTANCE_ID"
GET_INSTANCE_ALIAS="$INSTANCE_ALIAS"
GET_INSTANCE_EDITION="$INSTANCE_EDITION"

read_instance_arn 2 "$EXPECTED_EDITION_2"
SAVE_INSTANCE_ARN="$INSTANCE_ARN"
SAVE_REGION="$INSTANCE_REGION"
SAVE_ACCOUNT="$INSTANCE_ACCOUNT"
SAVE_INSTANCE_ID="$INSTANCE_ID"
SAVE_INSTANCE_ALIAS="$INSTANCE_ALIAS"
SAVE_INSTANCE_EDITION="$INSTANCE_EDITION"

[[ "$SAVE_ACCOUNT" == "$GET_ACCOUNT" ]] \
  || die "两个实例分属不同账号（$GET_ACCOUNT / ${SAVE_ACCOUNT}），本脚本只在单个账号内部署。"
ACCOUNT_ID="$SAVE_ACCOUNT"

[[ "$SAVE_INSTANCE_ID" != "$GET_INSTANCE_ID" ]] \
  || die "两个 ARN 指向同一个实例。「${EXPECTED_EDITION_1}」和「${EXPECTED_EDITION_2}」必须是两个不同的实例。"

# bot 和 AI agent 由实例 #2 上的 flow 使用。
read_lex_bot_arn  "$SAVE_REGION"
read_ai_agent_arn "$SAVE_REGION"

# 后缀排在最前，这样下面每个名称提示都能把最终名称作为默认值给出。它用于让
# 同一账号/实例中的多套部署互不冲突。
echo
NAME_SUFFIX="$(norm_suffix "$(ask '所有资源名称的后缀，例如 TP（留空表示不加）' "$NAME_SUFFIX")")"
[[ -z "$NAME_SUFFIX" ]] || log "所有资源名称都将以「${NAME_SUFFIX}」结尾。"

flow_name_in_file() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["Metadata"]["name"])' "$1"; }

echo
SAVE_FN="$(ask '写入型号的 Lambda 函数名称' "${DEFAULT_SAVE_FN}${NAME_SUFFIX}")"
GET_FN="$(ask  '读取型号的 Lambda 函数名称' "${DEFAULT_GET_FN}${NAME_SUFFIX}")"
AGENT_FN="$(ask '解析坐席姓名的 Lambda 函数名称' "${DEFAULT_AGENT_FN}${NAME_SUFFIX}")"
TABLE_NAME="$(ask 'DynamoDB 表名' "${DEFAULT_TABLE}${NAME_SUFFIX}")"
ROLE_NAME="$(ask  'IAM 执行角色名' "${DEFAULT_ROLE}${NAME_SUFFIX}")"
# 弹屏 flow 的名称先问，因为入呼流程的 DefaultAgentUI 钩子要改写成它最终的名字。
FLOW_NAME_3="$(ask '实例 #1 上弹屏 flow 的名称' "$(flow_name_in_file "$FLOW_FILE_3")${NAME_SUFFIX}")"
FLOW_NAME_1="$(ask '实例 #1 上 flow 的名称' "$(flow_name_in_file "$FLOW_FILE_1")${NAME_SUFFIX}")"
FLOW_NAME_2="$(ask '实例 #2 上 flow 的名称' "$(flow_name_in_file "$FLOW_FILE_2")${NAME_SUFFIX}")"

# 导出文件里钩子的显示名称，也就是 prepare_flow.py 需要改写的那个键，
# 这样即使加了后缀或改了名字，钩子依然能解析到 FLOW_NAME_3。
SCREENPOP_NAME_IN_FILE="$(flow_name_in_file "$FLOW_FILE_3")"

# 一张表由两个函数共用，默认放在 save 实例所在区域。
if [[ "$SAVE_REGION" == "$GET_REGION" ]]; then
  TABLE_REGION="$SAVE_REGION"
else
  warn "两个实例位于不同区域：$SAVE_REGION 与 ${GET_REGION}。"
  warn "每个 Lambda 必须待在自己实例所在的区域，但它们会共用一张表。"
  TABLE_REGION="$(ask '共用 DynamoDB 表所在的区域' "$SAVE_REGION")"
fi

CALLER_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)" \
  || die "无法调用 STS，请检查 AWS 凭证。"
[[ "$CALLER_ACCOUNT" == "$ACCOUNT_ID" ]] \
  || die "当前凭证属于账号 ${CALLER_ACCOUNT}，而实例 ARN 属于 ${ACCOUNT_ID}。"

TABLE_ARN="arn:aws:dynamodb:${TABLE_REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}"

cat <<EOF

--------------------------------------------------------------
 账号                  ：$ACCOUNT_ID
 实例 #1               ：${GET_INSTANCE_ALIAS}（${GET_INSTANCE_ID}，${GET_REGION}）
   版本                ：$GET_INSTANCE_EDITION
   Lambda              ：$GET_FN
   Lambda              ：$AGENT_FN
   Flow（弹屏）        ：$FLOW_NAME_3
   Flow                ：$FLOW_NAME_1
 实例 #2               ：${SAVE_INSTANCE_ALIAS}（${SAVE_INSTANCE_ID}，${SAVE_REGION}）
   版本                ：$SAVE_INSTANCE_EDITION
   Lambda              ：$SAVE_FN
   Flow                ：$FLOW_NAME_2
   Lex V2 bot          ：$LEX_BOT_NAME / $LEX_ALIAS_NAME
   Q in Connect AI agent：$AI_AGENT_NAME
 DynamoDB 表（共用）   ：${TABLE_NAME}（${TABLE_REGION}）
 IAM 角色              ：$ROLE_NAME
 运行时                ：$PY_RUNTIME
--------------------------------------------------------------
EOF

CONFIRM="$(ask '确认继续？' 'y')"
[[ "$CONFIRM" =~ ^[Yy] ]] || die "已由用户取消。"

#-------------------------------------------------------------------------------
# 1. DynamoDB 表
#    分区键：CustomerNumber (S)   排序键：CreatedAt (S, ISO-8601 UTC)
#    ISO-8601 按字典序即为时间序，所以「最新一条」就是键序里的最后一条。
#-------------------------------------------------------------------------------
log "正在检查 $TABLE_REGION 中的 DynamoDB 表 $TABLE_NAME ..."
if aws dynamodb describe-table --region "$TABLE_REGION" --table-name "$TABLE_NAME" >/dev/null 2>&1; then
  # 上一次中断的运行可能把表留在 CREATING 状态。
  aws dynamodb wait table-exists --region "$TABLE_REGION" --table-name "$TABLE_NAME"

  # 复用键结构不同的表会破坏「最新一条」查询，所以先校验而不是默默用错表。
  EXISTING_HASH="$(aws dynamodb describe-table \
    --region "$TABLE_REGION" --table-name "$TABLE_NAME" \
    --query "Table.KeySchema[?KeyType=='HASH']|[0].AttributeName" --output text)"
  EXISTING_RANGE="$(aws dynamodb describe-table \
    --region "$TABLE_REGION" --table-name "$TABLE_NAME" \
    --query "Table.KeySchema[?KeyType=='RANGE']|[0].AttributeName" --output text)"

  if [[ "$EXISTING_HASH" != "CustomerNumber" || "$EXISTING_RANGE" != "CreatedAt" ]]; then
    die "表 $TABLE_NAME 已存在于 ${TABLE_REGION}，但键结构不兼容（HASH=${EXISTING_HASH}，RANGE=${EXISTING_RANGE}），期望 HASH=CustomerNumber、RANGE=CreatedAt。请换一个表名，或删除现有表。"
  fi
  ok "表已存在且键结构兼容，直接复用。"
else
  log "正在创建表 ${TABLE_NAME}（按需计费）..."
  aws dynamodb create-table \
    --region "$TABLE_REGION" \
    --table-name "$TABLE_NAME" \
    --attribute-definitions \
        AttributeName=CustomerNumber,AttributeType=S \
        AttributeName=CreatedAt,AttributeType=S \
    --key-schema \
        AttributeName=CustomerNumber,KeyType=HASH \
        AttributeName=CreatedAt,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --no-cli-pager >/dev/null
  aws dynamodb wait table-exists --region "$TABLE_REGION" --table-name "$TABLE_NAME"
  ok "表创建完成。"
fi

#-------------------------------------------------------------------------------
# 2. IAM 执行角色（全局，三个函数共用）
#-------------------------------------------------------------------------------
TRUST_DOC="$WORKDIR/trust.json"
cat >"$TRUST_DOC" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

POLICY_DOC="$WORKDIR/policy.json"
cat >"$POLICY_DOC" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TableData",
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:Query",
        "dynamodb:DescribeTable"
      ],
      "Resource": [
        "${TABLE_ARN}",
        "${TABLE_ARN}/index/*"
      ]
    },
    {
      "Sid": "AutoCreateTable",
      "Effect": "Allow",
      "Action": [
        "dynamodb:CreateTable",
        "dynamodb:ListTables"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DescribeConnectAgents",
      "Effect": "Allow",
      "Action": [
        "connect:DescribeUser"
      ],
      "Resource": "${GET_INSTANCE_ARN}/agent/*"
    }
  ]
}
EOF

log "正在检查 IAM 角色 $ROLE_NAME ..."
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  # 重新应用信任策略，这样一个 Lambda 无法 assume 的既有角色会被修正，
  # 而不是等到 create-function 时才失败。
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "file://$TRUST_DOC" >/dev/null \
    || die "无法更新角色 $ROLE_NAME 的信任策略，请检查 IAM 权限。"
  ok "角色已存在，已重新应用信任策略。"
  ROLE_CREATED=false
else
  # 繁忙的账号可能已达 RolesPerAccount 配额，此处失败时原始报错完全看不出
  # 该怎么继续。
  #
  # 角色描述必须是纯 ASCII/Latin-1：IAM 对 description 的校验正则是
  # [\u0009\u000A\u000D\u0020-\u007E\u00A1-\u00FF]*，中文字符会被
  # ValidationError 拒绝，所以这里固定用英文。
  if ! CREATE_ROLE_ERR="$(aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document "file://$TRUST_DOC" \
      --description "Execution role for the Amazon Connect customer model Lambda functions" \
      --no-cli-pager 2>&1 >/dev/null)"; then
    if grep -qi "RolesPerAccount\|LimitExceeded" <<<"$CREATE_ROLE_ERR"; then
      die "$(printf '当前账号已达 IAM 角色配额上限，无法创建角色 %s。\n         请重新运行，并在「IAM 执行角色名」处填入一个已存在的 Lambda\n         执行角色；或删除无用角色，或申请提升配额。\n         AWS 返回：%s' "$ROLE_NAME" "$CREATE_ROLE_ERR")"
    fi
    die "无法创建角色 ${ROLE_NAME}：$CREATE_ROLE_ERR"
  fi
  ok "角色创建完成。"
  ROLE_CREATED=true
fi

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null \
  || die "无法为 $ROLE_NAME 附加 AWSLambdaBasicExecutionRole。"
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "CustomerModelTableAccess" \
  --policy-document "file://$POLICY_DOC" >/dev/null \
  || die "无法为 $ROLE_NAME 设置 CustomerModelTableAccess 内联策略。"
ok "策略已附加。"

ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"

if [[ "$ROLE_CREATED" == true ]]; then
  log "等待 15 秒让 IAM 角色生效 ..."
  sleep 15
fi

#-------------------------------------------------------------------------------
# 3. 部署包
#    处理函数代码位于 lambdas/<函数名>/lambda_function.py，可以像普通源码一样
#    编辑、diff 和 lint。打包时会压缩该函数目录下的全部内容，所以将来某个函数
#    增加额外模块时这里无需改动。
#-------------------------------------------------------------------------------
build_package() { # build_package <源目录名> <zip名>
  local dirname="$1" zip_name="$2"
  local src="$LAMBDA_SRC_DIR/$dirname"

  [[ -f "$src/lambda_function.py" ]] \
    || die "找不到 Lambda 处理函数源码：$src/lambda_function.py"

  # zip 是往既有压缩包里追加，上一次中断留下的 zip 会把旧代码一起打进去。
  rm -f "$WORKDIR/$zip_name"
  (cd "$src" && zip -q -r "$WORKDIR/$zip_name" . -x '*.pyc' -x '__pycache__/*') \
    || die "无法打包 ${src}。"
}

# 目录名就是各函数的默认名称，因此即使使用了 NAME_SUFFIX，每个已部署函数的
# 源码出处也一目了然。
build_package "$DEFAULT_SAVE_FN"  save.zip
build_package "$DEFAULT_GET_FN"   get.zip
build_package "$DEFAULT_AGENT_FN" agent.zip
ok "部署包构建完成。"

#-------------------------------------------------------------------------------
# 4. 部署/更新函数，并把每个函数挂到它对应的实例上
#-------------------------------------------------------------------------------
deploy_function() { # deploy_function <名称> <区域> <zip> <描述> [环境变量]
  local name="$1" region="$2" zip_path="$3" description="$4"
  # 默认使用共用表的那组环境变量；坐席姓名函数会覆盖它，因为它访问的是
  # Connect 而不是 DynamoDB。默认值单独赋值，因为写成
  # "${5:-Variables={A=1}}" 时 bash 会在内层花括号处结束参数展开，
  # 把外层花括号当成字面量留下来。
  local env_vars="${5:-}"
  if [[ -z "$env_vars" ]]; then
    env_vars="Variables={TABLE_NAME=$TABLE_NAME,TABLE_REGION=$TABLE_REGION}"
  fi

  if aws lambda get-function --region "$region" --function-name "$name" >/dev/null 2>&1; then
    # zip 包无法更新容器镜像型函数，所以提前给出清晰提示，而不是抛一个
    # 让人费解的 API 错误。
    local package_type
    package_type="$(aws lambda get-function --region "$region" --function-name "$name" \
      --query 'Configuration.PackageType' --output text)"
    [[ "$package_type" == "Zip" ]] \
      || die "$region 中的函数 $name 已存在且 PackageType=${package_type}。本脚本部署的是 zip 包，请换一个函数名。"

    # 上一次中断的运行可能把函数留在 Pending 状态，那样 update-function-code
    # 会失败。
    aws lambda wait function-active-v2 --region "$region" --function-name "$name"

    log "正在更新 $region 中已存在的函数 $name ..."
    aws lambda update-function-code \
      --region "$region" --function-name "$name" \
      --zip-file "fileb://$zip_path" --no-cli-pager >/dev/null
    aws lambda wait function-updated --region "$region" --function-name "$name"
    aws lambda update-function-configuration \
      --region "$region" --function-name "$name" \
      --role "$ROLE_ARN" --handler lambda_function.lambda_handler \
      --runtime "$PY_RUNTIME" --timeout 30 --memory-size 256 \
      --environment "$env_vars" \
      --description "$description" --no-cli-pager >/dev/null
    aws lambda wait function-updated --region "$region" --function-name "$name"
  else
    log "正在 $region 中创建函数 $name ..."
    aws lambda create-function \
      --region "$region" --function-name "$name" \
      --runtime "$PY_RUNTIME" --role "$ROLE_ARN" \
      --handler lambda_function.lambda_handler \
      --zip-file "fileb://$zip_path" \
      --timeout 30 --memory-size 256 \
      --environment "$env_vars" \
      --description "$description" --no-cli-pager >/dev/null
    aws lambda wait function-active-v2 --region "$region" --function-name "$name"
  fi
  ok "$name 已部署到 ${region}。"
}

allow_connect() { # allow_connect <函数名> <区域> <实例ARN>
  local name="$1" region="$2" instance_arn="$3"
  local sid="AllowAmazonConnectInvoke"
  aws lambda remove-permission \
    --region "$region" --function-name "$name" --statement-id "$sid" >/dev/null 2>&1 || true
  aws lambda add-permission \
    --region "$region" --function-name "$name" \
    --statement-id "$sid" \
    --action lambda:InvokeFunction \
    --principal connect.amazonaws.com \
    --source-account "$ACCOUNT_ID" \
    --source-arn "$instance_arn" --no-cli-pager >/dev/null
  ok "$name 的资源策略已限定到实例 ${instance_arn##*/}。"
}

associate_connect() { # associate_connect <函数名> <区域> <实例ID>
  local name="$1" region="$2" instance_id="$3"
  local arn="arn:aws:lambda:${region}:${ACCOUNT_ID}:function:${name}"
  local existing output

  # 先查当前的关联关系，这样就不必依赖「已关联」时具体的错误文案。
  if existing="$(aws connect list-lambda-functions \
        --region "$region" --instance-id "$instance_id" \
        --query 'LambdaFunctions[]' --output text 2>/dev/null)"; then
    if tr '\t' '\n' <<<"$existing" | grep -qxF -- "$arn"; then
      ok "$name 已关联到实例 ${instance_id}，无需处理。"
      return 0
    fi
  fi

  if output="$(aws connect associate-lambda-function \
        --region "$region" \
        --instance-id "$instance_id" \
        --function-arn "$arn" 2>&1)"; then
    ok "已把 $name 关联到实例 ${instance_id}。"
  elif grep -qi "DuplicateResource" <<<"$output"; then
    ok "$name 已关联到实例 ${instance_id}。"
  else
    warn "无法自动关联 ${name}：$output"
    warn "请手动添加：Connect 控制台 -> 流程 -> AWS Lambda -> $arn"
  fi
}

deploy_function "$SAVE_FN" "$SAVE_REGION" "$WORKDIR/save.zip" \
  "把来自 Amazon Connect 的 CustomerNumber 和 ModelNumber 写入 DynamoDB 表 $TABLE_NAME"
deploy_function "$GET_FN" "$GET_REGION" "$WORKDIR/get.zip" \
  "从 DynamoDB 表 $TABLE_NAME 返回某个 CustomerNumber 最新的 ModelNumber"
deploy_function "$AGENT_FN" "$GET_REGION" "$WORKDIR/agent.zip" \
  "把 Connect 用户 ID 解析成坐席姓名，供弹屏流程使用" \
  "Variables={CONNECT_INSTANCE_ID=$GET_INSTANCE_ID,CONNECT_REGION=$GET_REGION}"

allow_connect "$SAVE_FN"  "$SAVE_REGION" "$SAVE_INSTANCE_ARN"
allow_connect "$GET_FN"   "$GET_REGION"  "$GET_INSTANCE_ARN"
allow_connect "$AGENT_FN" "$GET_REGION"  "$GET_INSTANCE_ARN"

associate_connect "$SAVE_FN"  "$SAVE_REGION" "$SAVE_INSTANCE_ID"
associate_connect "$GET_FN"   "$GET_REGION"  "$GET_INSTANCE_ID"
associate_connect "$AGENT_FN" "$GET_REGION"  "$GET_INSTANCE_ID"

#-------------------------------------------------------------------------------
# 5. Contact flow
#    导出文件来自另一个实例，其中每个 ARN 都必须先重新指向，Connect 才会接受。
#-------------------------------------------------------------------------------
PREP="$WORKDIR/prepare_flow.py"
cat >"$PREP" <<'PYCODE'
#!/usr/bin/env python3
"""改写 Amazon Connect flow 导出文件，使其可以导入到别的实例。

把 Lambda / Lex V2 / Q in Connect 的 ARN 指向本次部署创建的资源，按显示名称
重新映射 contact flow 和队列引用，并删除目标实例中不存在对应 flow 的事件钩子。
"""
import argparse
import json
import re
import sys

LAMBDA_RE = r'arn:aws[a-z-]*:lambda:[a-z0-9-]+:[0-9]{12}:function:[A-Za-z0-9_-]+'
LEX_ALIAS_RE = r'arn:aws[a-z-]*:lex:[a-z0-9-]+:[0-9]{12}:bot-alias/[A-Z0-9]+/[A-Z0-9]+'
AI_AGENT_RE = (r'arn:aws[a-z-]*:wisdom:[a-z0-9-]+:[0-9]{12}:ai-agent/[0-9a-f-]{36}'
               r'/[0-9a-f-]{36}(?::(?:\$[A-Z]+|[0-9]+))?')
ASSISTANT_RE = r'arn:aws[a-z-]*:wisdom:[a-z0-9-]+:[0-9]{12}:assistant/[0-9a-f-]{36}'
INSTANCE_RES_RE = r'arn:aws[a-z-]*:connect:[a-z0-9-]+:[0-9]{12}:instance/[0-9a-f-]{36}/[^"]+'
# AWS 托管的坐席工作区视图（ShowView 使用）属于 "aws" 而不属于某个账号，因此
# 无需重新映射，但 ARN 里仍带着区域，需要跟随目标实例。
AWS_VIEW_RE = r'arn:aws[a-z-]*:connect:[a-z0-9-]+:aws:view/[A-Za-z0-9_.-]+(?::[A-Za-z0-9$]+)?'

# 事件钩子只接受某一种特定类型的 flow，所以当导出文件里的名称在目标实例中
# 不存在时，同类型的默认 flow 是安全的替代品。各实例在这里有差异：同一条 flow
# 在一个实例里叫 "Default agent whisper"，在另一个实例里叫
# "Default agent whisper - Transfer to Agent"。DefaultAgentUI 故意不在此列 —
# 它指向的是一条普通 CONTACT_FLOW，只有有人专门建过才存在。
HOOK_FLOW_TYPES = {
    'AgentWhisper': 'AGENT_WHISPER',
    'CustomerWhisper': 'CUSTOMER_WHISPER',
    'OutboundWhisper': 'OUTBOUND_WHISPER',
    'CustomerQueue': 'CUSTOMER_QUEUE',
    'CustomerHold': 'CUSTOMER_HOLD',
    'AgentHold': 'AGENT_HOLD',
    'AgentTransfer': 'AGENT_TRANSFER',
    'QueueTransfer': 'QUEUE_TRANSFER',
}


def emit(colour, level, msg):
    sys.stderr.write('\033[1;%sm[%s]\033[0m  %s\n' % (colour, level, msg))


def info(msg):
    emit('34', '信息', msg)


def warn(msg):
    emit('33', '警告', msg)


def fail(msg):
    emit('31', '失败', msg)
    sys.exit(1)


def load_entries(path):
    """`aws ... --output json` 产出的原始列表。"""
    if not path:
        return []
    with open(path) as handle:
        return json.load(handle) or []


def load_map(path):
    """从 `aws ... --output json` 列表里取出 {"Name": "Arn"}。"""
    return {e['Name']: e['Arn'] for e in load_entries(path)
            if e.get('Name') and e.get('Arn')}


def arn_by_name(entries, name):
    for entry in entries:
        if name and entry.get('Name') == name:
            return entry.get('Arn')
    return None


def default_of_type(entries, flow_type):
    """目标实例中某一类型的 flow，优先取 AWS 自带的那条。"""
    matches = [e for e in entries if e.get('Type') == flow_type and e.get('Arn')]
    if not matches:
        return None, None
    matches.sort(key=lambda e: (not str(e.get('Name', '')).startswith('Default'),
                                str(e.get('Name', ''))))
    return matches[0]['Arn'], matches[0].get('Name')


def display_name(meta, param):
    node = (meta.get('parameters') or {}).get(param)
    return node.get('displayName') if isinstance(node, dict) else None


def retarget_aws_views(text, region):
    """把 AWS 托管视图 ARN 的区域改成目标实例所在区域。"""
    if not region:
        return text
    for old in sorted(set(re.findall(AWS_VIEW_RE, text))):
        new = re.sub(r'(:connect:)[a-z0-9-]+(:aws:view/)',
                     lambda m: m.group(1) + region + m.group(2), old)
        if new != old:
            info('AWS 视图：%s -> %s' % (old, new))
            text = text.replace(old, new)
    return text


def rename_hook_flows(data, renames):
    """把事件钩子指向 flow 实际部署时用的名称。

    钩子是按显示名称解析的，而导出文件里带的是被引用 flow 在源实例中的名字。
    若不改写，加了后缀或在名称提示处自定义过，钩子就会被静默删除。
    """
    if not renames:
        return
    meta_actions = (data.get('Metadata') or {}).get('ActionMetadata') or {}
    for meta in meta_actions.values():
        if not isinstance(meta, dict):
            continue
        hooks = (meta.get('parameters') or {}).get('EventHooks') or {}
        for hook, node in hooks.items():
            if isinstance(node, dict) and node.get('displayName') in renames:
                old = node['displayName']
                node['displayName'] = renames[old]
                info('事件钩子 %s：「%s」-> 「%s」' % (hook, old, renames[old]))
        flow_meta = meta.get('contactFlow')
        if isinstance(flow_meta, dict) and flow_meta.get('text') in renames:
            flow_meta['text'] = renames[flow_meta['text']]


def replace_arns(text, pattern, replacement, label):
    if not replacement:
        return text
    for old in sorted(set(re.findall(pattern, text))):
        if old != replacement:
            info('%s：%s -> %s' % (label, old, replacement))
            text = text.replace(old, replacement)
    return text


def fix_display_names(node, args):
    """元数据里的显示名称只是外观，但留着过期的值看起来就像 bug。"""
    if isinstance(node, dict):
        for key, value in node.items():
            if key in ('LambdaFunctionARN', 'AliasArn') and isinstance(value, dict):
                new = args.lambda_name if key == 'LambdaFunctionARN' else args.lex_alias_name
                if new and 'displayName' in value:
                    value['displayName'] = new
            elif key == 'lexV2BotName' and args.lex_bot_name:
                node[key] = args.lex_bot_name
            elif key == 'lexV2BotAliasName' and args.lex_alias_name:
                node[key] = args.lex_alias_name
            elif key == 'aiAgentName' and args.ai_agent_name:
                node[key] = args.ai_agent_name
            fix_display_names(value, args)
    elif isinstance(node, list):
        for item in node:
            fix_display_names(item, args)


def remap_instance_resources(data, flows, queue_map):
    """返回 (旧ARN -> 新ARN, {动作ID -> 需要跳转到的ID})。"""
    meta_actions = (data.get('Metadata') or {}).get('ActionMetadata') or {}
    arn_map, drop_next = {}, {}

    for action in data.get('Actions') or []:
        ident = action.get('Identifier')
        meta = meta_actions.get(ident) or {}
        params = action.get('Parameters') or {}

        if action.get('Type') == 'UpdateContactEventHooks':
            hooks = params.get('EventHooks') or {}
            meta_hooks = (meta.get('parameters') or {}).get('EventHooks') or {}
            for hook, old_arn in list(hooks.items()):
                if not isinstance(old_arn, str) or '/contact-flow/' not in old_arn:
                    continue
                name = (meta_hooks.get(hook) or {}).get('displayName')
                target = arn_by_name(flows, name)
                if not target:
                    target, picked = default_of_type(
                        flows, HOOK_FLOW_TYPES.get(hook, ''))
                    if target:
                        warn('事件钩子 %s：目标实例中不存在 flow「%s」，'
                             '改用它的「%s」。'
                             % (hook, name or old_arn, picked))
                        if isinstance(meta_hooks.get(hook), dict):
                            meta_hooks[hook]['displayName'] = picked
                        flow_meta = meta.get('contactFlow')
                        if isinstance(flow_meta, dict) and flow_meta.get('id') == old_arn:
                            flow_meta['text'] = picked
                if target:
                    arn_map[old_arn] = target
                else:
                    warn('事件钩子 %s 指向 flow「%s」，目标实例中没有这条 flow，'
                         '该钩子将被删除。'
                         % (hook, name or old_arn))
                    hooks.pop(hook, None)
                    meta_hooks.pop(hook, None)
            if not hooks:
                nxt = (action.get('Transitions') or {}).get('NextAction')
                if not nxt:
                    fail('动作 %s 的事件钩子全部丢失，且没有 NextAction 可以跳转。' % ident)
                drop_next[ident] = nxt

        elif action.get('Type') == 'UpdateContactTargetQueue':
            old_arn = params.get('QueueId')
            if not isinstance(old_arn, str) or '/queue/' not in old_arn:
                continue
            name = display_name(meta, 'QueueId')
            target = queue_map.get(name) if name else None
            if not target:
                if not queue_map:
                    fail('目标实例没有任何标准队列，无法重新映射队列「%s」。'
                         % (name or old_arn))
                fallback = sorted(queue_map)[0]
                target = queue_map[fallback]
                warn('目标实例中不存在队列「%s」，改为路由到「%s」。'
                     % (name or old_arn, fallback))
            arn_map[old_arn] = target

    return arn_map, drop_next


def drop_actions(data, drop_next):
    """删除动作，并把所有指向它们的 transition 顺延到后面的动作。"""
    if not drop_next:
        return

    def resolve(target):
        seen = set()
        while target in drop_next:
            if target in seen:
                fail('删除不可用动作时发现 transition 形成了环。')
            seen.add(target)
            target = drop_next[target]
        return target

    def rewire(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == 'NextAction' and isinstance(value, str):
                    node[key] = resolve(value)
                else:
                    rewire(value)
        elif isinstance(node, list):
            for item in node:
                rewire(item)

    rewire(data.get('Actions'))
    if data.get('StartAction') in drop_next:
        data['StartAction'] = resolve(data['StartAction'])
    data['Actions'] = [a for a in data['Actions']
                       if a.get('Identifier') not in drop_next]
    meta_actions = (data.get('Metadata') or {}).get('ActionMetadata') or {}
    for ident in drop_next:
        meta_actions.pop(ident, None)
    info('已删除 %d 个引用了缺失资源的动作。' % len(drop_next))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--flow-file', required=True)
    parser.add_argument('--out-file', required=True)
    parser.add_argument('--instance-id', required=True)
    parser.add_argument('--name')
    parser.add_argument('--lambda-arn')
    parser.add_argument('--lambda-name')
    parser.add_argument('--lex-alias-arn')
    parser.add_argument('--lex-bot-name')
    parser.add_argument('--lex-alias-name')
    parser.add_argument('--ai-agent-arn')
    parser.add_argument('--ai-agent-name')
    parser.add_argument('--assistant-arn')
    parser.add_argument('--flow-map')
    parser.add_argument('--queue-map')
    parser.add_argument('--region')
    parser.add_argument('--rename-flow', action='append', default=[],
                        metavar='OLD=NEW',
                        help='在目标实例中查找之前，先改写事件钩子的显示名称')
    args = parser.parse_args()

    renames = {}
    for pair in args.rename_flow:
        if '=' not in pair:
            fail('--rename-flow 需要 OLD=NEW 形式，收到的是 %r' % pair)
        old, new = pair.split('=', 1)
        if old and new:
            renames[old] = new

    with open(args.flow_file) as handle:
        data = json.load(handle)

    rename_hook_flows(data, renames)
    arn_map, drop_next = remap_instance_resources(
        data, load_entries(args.flow_map), load_map(args.queue_map))
    drop_actions(data, drop_next)
    fix_display_names(data, args)
    if args.name:
        data.setdefault('Metadata', {})['name'] = args.name

    text = json.dumps(data, indent=2)
    for old, new in arn_map.items():
        if old != new:
            info('实例内资源：%s -> %s' % (old, new))
            text = text.replace(old, new)
    text = replace_arns(text, LAMBDA_RE, args.lambda_arn, 'Lambda')
    text = replace_arns(text, LEX_ALIAS_RE, args.lex_alias_arn, 'Lex bot 别名')
    text = replace_arns(text, AI_AGENT_RE, args.ai_agent_arn, 'AI agent')
    text = replace_arns(text, ASSISTANT_RE, args.assistant_arn, 'Q in Connect assistant')
    text = retarget_aws_views(text, args.region)

    stale = sorted({arn for arn in re.findall(INSTANCE_RES_RE, text)
                    if 'instance/%s/' % args.instance_id not in arn})
    if stale:
        fail('以下引用仍然属于另一个 Connect 实例：\n  '
             + '\n  '.join(stale))

    json.loads(text)  # 防止产出无效 JSON
    with open(args.out_file, 'w') as handle:
        handle.write(text)


if __name__ == '__main__':
    main()
PYCODE

flow_id_by_name() { # flow_id_by_name <flows-json> <名称>
  python3 - "$1" "$2" <<'PYCODE'
import json, sys
entries = json.load(open(sys.argv[1])) or []
for entry in entries:
    if entry.get("Name") == sys.argv[2]:
        print("%s\t%s" % (entry.get("Id", ""), entry.get("Type", "")))
        break
PYCODE
}

list_flows_json() { # list_flows_json <区域> <实例ID> <输出文件>
  aws connect list-contact-flows \
    --region "$1" --instance-id "$2" \
    --query 'ContactFlowSummaryList[].{Name:Name,Arn:Arn,Id:Id,Type:ContactFlowType}' \
    --output json >"$3"
}

deploy_flow() { # deploy_flow <区域> <实例ID> <源文件> <flow名称> <lambda-arn> <lambda名称> [with-ai|no] [prepare_flow.py 的额外参数...]
  local region="$1" instance_id="$2" src="$3" name="$4" lambda_arn="$5" lambda_name="$6" with_ai="${7:-no}"
  # with-ai 之后的参数会原样交给 prepare_flow.py，入呼流程就是这样拿到
  # 弹屏钩子所需的 --rename-flow 的。
  shift $(( $# < 7 ? $# : 7 ))
  local -a extra_prep_args=("$@")
  local flows="$WORKDIR/flows-${instance_id}.json"
  local queues="$WORKDIR/queues-${instance_id}.json"
  local prepared="$WORKDIR/flow-${instance_id}.json"
  local existing id type

  log "正在为实例 $instance_id 准备 flow「${name}」..."
  list_flows_json "$region" "$instance_id" "$flows"
  aws connect list-queues \
    --region "$region" --instance-id "$instance_id" --queue-types STANDARD \
    --query 'QueueSummaryList[].{Name:Name,Arn:Arn}' --output json >"$queues"

  local -a prep_args=(
    --flow-file "$src" --out-file "$prepared" --name "$name"
    --instance-id "$instance_id" --region "$region"
    --lambda-arn "$lambda_arn" --lambda-name "$lambda_name"
    --flow-map "$flows" --queue-map "$queues"
  )
  if [[ "$with_ai" == "with-ai" ]]; then
    prep_args+=(
      --lex-alias-arn "$LEX_ALIAS_ARN" --lex-bot-name "$LEX_BOT_NAME"
      --lex-alias-name "$LEX_ALIAS_NAME"
      --ai-agent-arn "$AI_AGENT_ARN" --ai-agent-name "$AI_AGENT_NAME"
      --assistant-arn "$ASSISTANT_ARN"
    )
  fi
  # ${a[@]+...} 让数组为空时在 `set -u` 下依然可用。
  prep_args+=(${extra_prep_args[@]+"${extra_prep_args[@]}"})

  python3 "$PREP" "${prep_args[@]}" \
    || die "无法为实例 $instance_id 改写 $(basename "$src")。"

  existing="$(flow_id_by_name "$flows" "$name")"
  id="$(cut -f1 <<<"$existing")"
  type="$(cut -f2 <<<"$existing")"

  if [[ -n "$id" ]]; then
    [[ "$type" == "CONTACT_FLOW" ]] \
      || die "实例 $instance_id 中已有名为「${name}」的 flow，但类型是 ${type}。请换一个 flow 名称。"
    warn "实例 $instance_id 中已存在名为「${name}」的 flow。"
    local overwrite
    overwrite="$(ask "是否覆盖它的内容？" 'y')"
    [[ "$overwrite" =~ ^[Yy] ]] || die "已取消：flow「${name}」保持原样。"
    aws connect update-contact-flow-content \
      --region "$region" --instance-id "$instance_id" \
      --contact-flow-id "$id" --content "file://$prepared" --no-cli-pager >/dev/null \
      || die "Connect 拒绝了 flow「${name}」的新内容。"
    ok "flow「${name}」已更新（${id}）。"
  else
    id="$(aws connect create-contact-flow \
        --region "$region" --instance-id "$instance_id" \
        --name "$name" --type CONTACT_FLOW --status PUBLISHED \
        --description "由 deploy_connect_lambdas.sh 部署" \
        --content "file://$prepared" \
        --query 'ContactFlowId' --output text --no-cli-pager)" \
      || die "Connect 拒绝了 flow「${name}」。请修正报告中的引用后重新运行。"
    ok "flow「${name}」已创建（${id}）。"
  fi
  DEPLOYED_FLOW_ID="$id"
}

associate_lex_bot() { # associate_lex_bot <区域> <实例ID>
  local region="$1" instance_id="$2" existing output
  if existing="$(aws connect list-bots \
        --region "$region" --instance-id "$instance_id" --lex-version V2 \
        --query 'LexBots[].LexV2Bot.AliasArn' --output text 2>/dev/null)"; then
    if tr '\t' '\n' <<<"$existing" | grep -qxF -- "$LEX_ALIAS_ARN"; then
      ok "Lex bot 别名已关联到实例 ${instance_id}。"
      return 0
    fi
  fi
  if output="$(aws connect associate-bot \
        --region "$region" --instance-id "$instance_id" \
        --lex-v2-bot "AliasArn=$LEX_ALIAS_ARN" 2>&1)"; then
    ok "已把 Lex bot ${LEX_BOT_NAME}（${LEX_ALIAS_NAME}）关联到实例 ${instance_id}。"
  elif grep -qi "ResourceConflict\|DuplicateResource" <<<"$output"; then
    ok "Lex bot 已关联到实例 ${instance_id}。"
  else
    die "无法把 Lex bot 关联到实例 ${instance_id}：$output"
  fi
}

associate_assistant() { # associate_assistant <区域> <实例ID>
  local region="$1" instance_id="$2" existing output
  if existing="$(aws connect list-integration-associations \
        --region "$region" --instance-id "$instance_id" \
        --integration-type WISDOM_ASSISTANT \
        --query 'IntegrationAssociationSummaryList[].IntegrationArn' \
        --output text 2>/dev/null)"; then
    if tr '\t' '\n' <<<"$existing" | grep -qxF -- "$ASSISTANT_ARN"; then
      ok "Q in Connect assistant 已关联到实例 ${instance_id}。"
      return 0
    fi
  fi
  if output="$(aws connect create-integration-association \
        --region "$region" --instance-id "$instance_id" \
        --integration-type WISDOM_ASSISTANT \
        --integration-arn "$ASSISTANT_ARN" 2>&1)"; then
    ok "已把 Q in Connect assistant 关联到实例 ${instance_id}。"
  else
    warn "无法自动关联 Q in Connect assistant：$output"
    warn "如果 flow 创建失败，请先在实例 $instance_id 上启用 Amazon Q in Connect，然后重新运行。"
  fi
}

# 实例 #1，先部署弹屏：入呼流程的 DefaultAgentUI 钩子是按 flow 名称在实例当前
# 的 flow 列表里解析的，所以这条 flow 必须早于入呼流程被准备，否则钩子会被删除。
deploy_flow "$GET_REGION" "$GET_INSTANCE_ID" "$FLOW_FILE_3" "$FLOW_NAME_3" \
  "arn:aws:lambda:${GET_REGION}:${ACCOUNT_ID}:function:${AGENT_FN}" "$AGENT_FN"
FLOW_ID_3="$DEPLOYED_FLOW_ID"

# 实例 #1：GET 函数 + 转外部号码的流程。--rename-flow 把弹屏 flow 的真实名称
# 传进钩子，因为钩子里存的还是导出文件中的名字（没有后缀，也没被自定义过）。
deploy_flow "$GET_REGION" "$GET_INSTANCE_ID" "$FLOW_FILE_1" "$FLOW_NAME_1" \
  "arn:aws:lambda:${GET_REGION}:${ACCOUNT_ID}:function:${GET_FN}" "$GET_FN" no \
  --rename-flow "${SCREENPOP_NAME_IN_FILE}=${FLOW_NAME_3}"
FLOW_ID_1="$DEPLOYED_FLOW_ID"

# 实例 #2：SAVE 函数 + AI agent IVR 流程，后者还需要把 Lex bot 和
# Q in Connect assistant 挂到实例上。
associate_lex_bot  "$SAVE_REGION" "$SAVE_INSTANCE_ID"
associate_assistant "$SAVE_REGION" "$SAVE_INSTANCE_ID"
deploy_flow "$SAVE_REGION" "$SAVE_INSTANCE_ID" "$FLOW_FILE_2" "$FLOW_NAME_2" \
  "arn:aws:lambda:${SAVE_REGION}:${ACCOUNT_ID}:function:${SAVE_FN}" "$SAVE_FN" with-ai
FLOW_ID_2="$DEPLOYED_FLOW_ID"

#-------------------------------------------------------------------------------
# 6. 冒烟测试 - 用 save 函数写入，再用 get 函数读回
#-------------------------------------------------------------------------------
RUN_TEST="$(ask '是否运行一次端到端冒烟测试？' 'y')"
if [[ "$RUN_TEST" =~ ^[Yy] ]]; then
  TEST_NUMBER="+15551234567"
  cat >"$WORKDIR/save_payload.json" <<EOF
{"Details":{"Parameters":{"CustomerNumber":"$TEST_NUMBER","ModelNumber":"Archer AX73"}}}
EOF
  cat >"$WORKDIR/get_payload.json" <<EOF
{"Details":{"Parameters":{"CustomerNumber":"$TEST_NUMBER"}}}
EOF

  log "正在调用 ${SAVE_FN}（${SAVE_REGION}）..."
  aws lambda invoke --region "$SAVE_REGION" --function-name "$SAVE_FN" \
    --cli-binary-format raw-in-base64-out \
    --payload "file://$WORKDIR/save_payload.json" \
    "$WORKDIR/save_out.json" --no-cli-pager >/dev/null
  echo "  -> $(cat "$WORKDIR/save_out.json")"

  log "正在调用 ${GET_FN}（${GET_REGION}）..."
  aws lambda invoke --region "$GET_REGION" --function-name "$GET_FN" \
    --cli-binary-format raw-in-base64-out \
    --payload "file://$WORKDIR/get_payload.json" \
    "$WORKDIR/get_out.json" --no-cli-pager >/dev/null
  echo "  -> $(cat "$WORKDIR/get_out.json")"

  # 删掉探针记录，避免反复运行堆积测试数据。
  TEST_CREATED_AT="$(sed -n 's/.*"CreatedAt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$WORKDIR/save_out.json" | head -n 1)"
  if [[ -n "$TEST_CREATED_AT" ]]; then
    aws dynamodb delete-item \
      --region "$TABLE_REGION" --table-name "$TABLE_NAME" \
      --key "{\"CustomerNumber\":{\"S\":\"$TEST_NUMBER\"},\"CreatedAt\":{\"S\":\"$TEST_CREATED_AT\"}}" \
      --no-cli-pager >/dev/null && ok "冒烟测试记录已删除。"
  else
    warn "无法确定冒烟测试记录的主键，该记录保留在表中。"
  fi

  # 坐席姓名函数需要真实的 Connect 用户 ID 才能返回姓名，所以这个探针只验证
  # 它可被调用，并且遇到未知 ID 时能优雅降级。
  cat >"$WORKDIR/agent_payload.json" <<'EOF'
{"Details":{"Parameters":{"LastAgentID":"00000000-0000-0000-0000-000000000000"}}}
EOF
  log "正在调用 ${AGENT_FN}（${GET_REGION}）..."
  aws lambda invoke --region "$GET_REGION" --function-name "$AGENT_FN" \
    --cli-binary-format raw-in-base64-out \
    --payload "file://$WORKDIR/agent_payload.json" \
    "$WORKDIR/agent_out.json" --no-cli-pager >/dev/null
  echo "  -> $(cat "$WORKDIR/agent_out.json")"
  if grep -q '"Status": *"SUCCESS"' "$WORKDIR/agent_out.json"; then
    ok "$AGENT_FN 遇到未知坐席 ID 时未报错。"
  else
    warn "$AGENT_FN 对未知坐席 ID 没有返回 SUCCESS。请检查角色 $ROLE_NAME"
    warn "是否有权对实例 $GET_INSTANCE_ID 调用 connect:DescribeUser。"
  fi
fi

#-------------------------------------------------------------------------------
# 汇总
#-------------------------------------------------------------------------------
cat <<EOF

==============================================================
 部署完成
==============================================================
 DynamoDB 表：${TABLE_NAME}（区域 ${TABLE_REGION}，两个函数共用）
   分区键    ：CustomerNumber（String）
   排序键    ：CreatedAt（String，ISO-8601 UTC）

 实例 #1     ：${GET_INSTANCE_ALIAS}（${GET_INSTANCE_ID}，${GET_REGION}）
   版本      ：$GET_INSTANCE_EDITION
   读取函数  ：arn:aws:lambda:${GET_REGION}:${ACCOUNT_ID}:function:${GET_FN}
     入参    ：CustomerNumber
     返回    ：Status、Found、CustomerNumber、ModelNumber、CreatedAt
   坐席姓名函数：arn:aws:lambda:${GET_REGION}:${ACCOUNT_ID}:function:${AGENT_FN}
     入参    ：LastAgentID（Connect 用户 ID）
     返回    ：Status、Found、LastAgentID、LastAgentName
   Flow      ：${FLOW_NAME_3}（${FLOW_ID_3}）
   Flow      ：${FLOW_NAME_1}（${FLOW_ID_1}）
     DefaultAgentUI 事件钩子 -> $FLOW_NAME_3

 实例 #2     ：${SAVE_INSTANCE_ALIAS}（${SAVE_INSTANCE_ID}，${SAVE_REGION}）
   版本      ：$SAVE_INSTANCE_EDITION
   写入函数  ：arn:aws:lambda:${SAVE_REGION}:${ACCOUNT_ID}:function:${SAVE_FN}
     入参    ：CustomerNumber、ModelNumber
     返回    ：Status、CustomerNumber、ModelNumber、CreatedAt
   Flow      ：${FLOW_NAME_2}（${FLOW_ID_2}）
   Lex V2 bot：${LEX_BOT_ARN}（别名 ${LEX_ALIAS_NAME}）
   AI agent  ：$AI_AGENT_ARN

 三条 flow 均已发布，并且已指向上面列出的 Lambda 函数、Lex bot 和 AI agent。
 flow 中通过 \$.External.ModelNumber、\$.External.Found 和
 \$.External.LastAgentName 读取返回值。

 仍需手工完成：
   - 为两条入呼 flow 申领或指派电话号码（「${FLOW_NAME_3}」是事件钩子流程，
     不需要单独的号码）
   - 在实例 $GET_INSTANCE_ID 上启用 Amazon Connect Customer Profiles，并开启
     弹屏读取的计算属性（_last_agent_id、_last_channel、_new_customer、
     _most_frequent_channel、_frequent_caller）；未开启时这些字段渲染为空
   - 检查「${FLOW_NAME_1}」中的外呼号码
     （TransferParticipantToThirdParty 仍是原导出文件里的号码）

 未传 CustomerNumber 时，save 和 get 两个函数都会回退到来电者号码
 （Details.ContactData.CustomerEndpoint.Address）。
==============================================================
EOF

# Amazon Connect AI IVR + 型号采集

两个 Amazon Connect 实例配合工作：AI 自助 IVR 负责采集来电者的产品型号，客户侧流程再把这个值取回来，用于路由和坐席弹屏。

`deploy_connect_lambdas.sh` 一次部署全部内容：一张 DynamoDB 表、三个 Lambda 函数，以及三条 contact flow（实例 #1 两条，实例 #2 一条）。所有输入都会先校验通过，才会创建任何资源。

## 工作方式

```
实例 #1 "Amazon Connect Customer Basic"          实例 #2 "Amazon Connect Customer"
Customer Inbound - AI IVR and Agent Transfer     AI Self-Service IVR - Model Capture
  1. 接起来电，开启日志与录音                      1. Lex V2 bot + Q in Connect AI agent
  2. 将 DefaultAgentUI 事件钩子指向                  与来电者对话
     Customer Inbound - ScreenPop                 2. ConnectSaveCustomerModel 把
  3. 将来电者转到 IVR 号码           ────────▶         {CustomerNumber, ModelNumber}
  4. 来电者返回本流程                                  写入 DynamoDB
  5. ConnectGetCustomerModel 读取     ◀────────
     最新的 ModelNumber
  6. 存为 QueueName 联系属性
  7. 转入 BasicQueue 等待坐席

实例 #1 "Customer Inbound - ScreenPop"（坐席接起时由事件钩子触发）
  1. 用来电号码查 Customer Profiles，查不到则新建档案
  2. 读取计算属性（_last_agent_id、_last_channel、_new_customer、
     _most_frequent_channel、_frequent_caller）
  3. ConnectGetAgentName 把 _last_agent_id 这个用户 ID 换成坐席姓名
  4. 用 ShowView 在坐席工作区渲染 detail 视图
```

弹屏流程通过 `UpdateContactEventHooks` 的 `DefaultAgentUI` 钩子挂在入呼流程上，钩子**按 flow 名称**解析，所以部署脚本会先部署弹屏流程，再部署入呼流程。

Save 与 Get 两个 Lambda 共用一张 DynamoDB 表，并通过显式指定的区域访问，因此两个实例可以位于不同区域。`ConnectGetAgentName` 不使用该表，它调用 `connect:DescribeUser`。

| 表 | `ConnectCustomerModel` |
|---|---|
| 分区键 | `CustomerNumber`（String，归一化为 `+数字`） |
| 排序键 | `CreatedAt`（String，ISO-8601 UTC） |

ISO-8601 时间戳按字典序即为时间序，所以取「最新一条」只需一次倒序查询加 `Limit=1`。

## 文件说明

| 文件 | 用途 |
|---|---|
| `deploy_connect_lambdas.sh` | 部署脚本，下文内容均围绕它 |
| `Customer Inbound - AI IVR and Agent Transfer.json` | 实例 #1 的入呼 flow 导出文件 |
| `Customer Inbound - ScreenPop.json` | 实例 #1 的坐席弹屏 flow 导出文件 |
| `AI Self-Service IVR - Model Capture.json` | 实例 #2 的 flow 导出文件 |


## 前置条件

- PATH 中可用的 AWS CLI v2、`zip`、`python3`
- 与两个 Connect 实例同账号的凭证
- 所需权限：`connect:*`（describe/list/create flow、`DescribeInstanceAttribute`、关联 bot 与 Lambda）、`lambda:*`、执行角色相关的 `iam:*`、表相关的 `dynamodb:*`、`lex:DescribeBot`、`lex:ListBotAliases`、`qconnect:GetAIAgent`
- 一个已构建且别名可用的 Lex V2 bot，需与实例 #2 同区域
- 一个 Amazon Q in Connect AI agent，需与实例 #2 同区域

## 运行方式

```bash
./deploy_connect_lambdas.sh
```

按顺序需要回答：

| 提示 | 说明 |
|---|---|
| 实例 #1 ARN | 版本必须是 **Amazon Connect Customer Basic** |
| 实例 #2 ARN | 版本必须是 **Amazon Connect Customer** |
| Conversational AI bot ARN | `arn:aws:lex:us-west-2:<acct>:bot/QIHKIB2VL1` |
| AI Agent ARN | `arn:aws:wisdom:us-west-2:<acct>:ai-agent/<assistantId>/<agentId>:$SAVED` |
| 资源名后缀 | 留空表示不加，例如 `AC`。会作用于下面所有名称 |
| Save / Get Lambda 名称 | 默认 `ConnectSaveCustomerModel`、`ConnectGetCustomerModel` 加后缀 |
| Agent-name Lambda 名称 | 默认 `ConnectGetAgentName` 加后缀 |
| DynamoDB 表名 | 默认 `ConnectCustomerModel` 加后缀 |
| IAM 执行角色名 | 默认 `ConnectCustomerModelLambdaRole` 加后缀 |
| 弹屏 flow 名称 | 默认 `Customer Inbound - ScreenPop` 加后缀。先问它，因为入呼流程的钩子要改写成这个名字 |
| 各实例的 flow 名称 | 默认为导出文件中的名称加后缀 |
| 表所在区域 | 仅当两个实例位于不同区域时才会询问 |
| Proceed? | 在此之前不会创建任何资源 |
| 是否运行冒烟测试 | 写入一条探针记录、读回、再删除 |

### 资源名后缀

后缀用于让同一账号/实例中的多次部署互不冲突，**三个 Lambda 函数、IAM 角色、DynamoDB 表、三条 flow 全部生效**。该提示排在 AI Agent ARN 之后、所有名称提示之前，因此后续每个名称提示显示的默认值都已带上后缀，按回车即可。

入呼流程里的 `DefaultAgentUI` 钩子写的是导出文件中的弹屏 flow 名称（不带后缀）。脚本会把「弹屏 flow 名称」提示的实际结果通过 `--rename-flow` 传给改写步骤，所以加了后缀或改了名字，钩子依然能正确指向。

同一个后缀要同时满足 Lambda 函数名、IAM 角色名、DynamoDB 表名和 flow 名称的字符限制，所以脚本会做归一化：`[A-Za-z0-9]` 之外的字符统一折叠为 `_`，并始终以 `_` 连接。

| 输入 | 实际后缀 | 示例结果 |
|---|---|---|
| `AC` | `_AC` | `ConnectGetCustomerModel_AC` |
| `_AC` / `-AC` / `- AC` | `_AC` | `ConnectCustomerModelLambdaRole_AC` |
| `v2` | `_v2` | `ConnectCustomerModel_v2` |
| `ac/2` | `_ac_2` | `AI Self-Service IVR - Model Capture_ac_2` |
| 留空 | 无 | `ConnectSaveCustomerModel` |

想要别的写法（比如 `... Model Capture - AC`），在对应的名称提示处直接输入完整名称即可覆盖默认值。

也可以用环境变量跳过该提示：

```bash
NAME_SUFFIX="AC" ./deploy_connect_lambdas.sh
```

### 实例版本是怎么判定的

版本校验的作用是防止 flow 部署到错误的实例。Connect API **没有**任何字段直接给出实例版本：`DescribeInstance` 返回的 `Instance` 对象里只有 `Arn`、`Id`、`InstanceAlias`、`IdentityManagementType`、`InstanceStatus`、`InboundCallsEnabled`、`OutboundCallsEnabled`、`InstanceAccessUrl`、`ServiceRole`、`CreatedTime`、`StatusReason`、`Tags`，`CreateInstance` 也没有版本入参。切换版本是控制台上对整个实例的 Enable/Disable 开关。

脚本改用 `MAX_PACKAGE` 实例属性来判定：

```bash
aws connect describe-instance-attribute --region <区域> \
  --instance-id <实例ID> --attribute-type MAX_PACKAGE
```

| `MAX_PACKAGE` | 判定版本 |
|---|---|
| `true` | Amazon Connect Customer（完整版，含全部 AI 能力） |
| `false` | Amazon Connect Customer Basic |

> **注意**：`MAX_PACKAGE` 没有出现在公开文档 `DescribeInstanceAttribute` 的 `AttributeType` 取值列表中（文档只列到 `MESSAGE_STREAMING`），属于未文档化字段，AWS 可能在不通知的情况下调整。脚本在读不到该属性、或取值不是 `true`/`false` 时会直接报错退出，绝不会放行到可能错误的实例上。

顺带一提，**别名不可能等于这两个版本名**：`InstanceAlias` 的约束是 `^(?!d-)([\da-zA-Z]+)([-]*[\da-zA-Z])*$`、最长 45 字符，只允许字母数字和连字符，带空格的 `Amazon Connect Customer Basic` 在物理上就无法作为别名。别名现在只用于日志展示，没有别名也不影响部署。

切换到其他环境时可覆盖期望版本（取值只能是上表中的两个版本名）：

```bash
EXPECTED_EDITION_1="Amazon Connect Customer" \
EXPECTED_EDITION_2="Amazon Connect Customer" ./deploy_connect_lambdas.sh
```

## 部署前的检查项

1. 两个实例 ARN 格式正确、确实存在、版本符合要求，且必须是同账号下的两个不同实例。
2. Lex bot 存在、位于实例 #2 所在区域，并且有可用别名（优先选 `TestBotAlias`）。
3. AI agent 在其 assistant 下确实存在，且与实例 #2 同区域。
4. 当前凭证所属账号与实例所在账号一致。

任一项失败都会输出 `[FAIL]` 并在创建任何资源之前退出。

## Flow 改写

导出文件中的 ARN 属于它最初所在的那个实例，直接导入会被 Connect 拒绝。脚本内嵌的 Python 步骤会在上传前重写每个导出文件：

- Lambda、Lex bot alias、AI agent 与 Q in Connect assistant 的 ARN，全部指向本次运行校验过或新建的资源。
- AWS 托管的坐席工作区视图 ARN（`arn:aws:connect:<region>:aws:view/detail:1`）中的区域改写为目标实例所在区域。
- `--rename-flow OLD=NEW` 先把事件钩子的显示名改成 flow 实际部署时用的名字，再做按名查找。
- 事件钩子和队列**按名称**在目标实例中重新映射。名称不存在时，钩子回退到目标实例中同类型的默认 flow（`Default agent whisper - Transfer to Agent` → `Default agent whisper`）。`DefaultAgentUI` 没有同类型默认值，因此弹屏 flow 必须先部署。
- 完全找不到对应资源的钩子（例如只存在于源实例的弹屏 flow）会被删除，并重新接线相邻节点的 transition，不留悬空引用。
- 最后再扫一遍，若仍有 ARN 指向其他实例就直接失败，而不是把注定被拒的内容交给 API 报一个含义模糊的错误。

## 重复运行

可以放心重复执行。已存在的表和角色会被复用（表的键结构会先校验），Lambda 走原地更新，已建立的关联会跳过，遇到同名 flow 会先询问再覆盖其内容。Flow ID 保持不变，因此指向该 flow 的配置不会失效。

## 部署完成后

- 为两条入呼 flow 分别申领或指派电话号码。`Customer Inbound - ScreenPop` 是事件钩子流程，不需要单独的号码。
- 在实例 #1 上启用 Customer Profiles，并开启弹屏读取的计算属性：`_last_agent_id`、`_last_channel`、`_new_customer`、`_most_frequent_channel`、`_frequent_caller`。未开启时这些字段渲染为空，流程本身不会报错。
- 检查 `Customer Inbound - AI IVR and Agent Transfer` 中 `TransferParticipantToThirdParty` 模块的外呼号码：它仍是原导出文件里的号码，需要改成实例 #2 的 IVR 号码。
- 如果 `associate-lambda-function` 报了 `ServiceQuotaExceededException`，见下方故障排查。

## Lambda 接口约定

三个函数都能处理 Connect 流程事件、直接测试事件以及 API Gateway 请求体，返回扁平的字符串 map，供 `$.External.*` 读取。

| | 入参 | 返回 |
|---|---|---|
| `ConnectSaveCustomerModel` | `CustomerNumber`、`ModelNumber` | `Status`、`CustomerNumber`、`ModelNumber`、`CreatedAt` |
| `ConnectGetCustomerModel` | `CustomerNumber` | `Status`、`Found`、`CustomerNumber`、`ModelNumber`、`CreatedAt` |
| `ConnectGetAgentName` | `LastAgentID`（Connect 用户 ID） | `Status`、`Found`、`LastAgentID`、`LastAgentName` |

未传 `CustomerNumber` 时，Save 与 Get 都回退到来电者号码（`Details.ContactData.CustomerEndpoint.Address`）。Get 函数先用归一化后的号码查询，再尝试几种常见变体，因此 `+15551234567` 与 `15551234567` 会命中同一条记录。

`ConnectGetAgentName` 的实例 ID 取自环境变量 `CONNECT_INSTANCE_ID`（部署时写入实例 #1），未设置时回退到 `Details.ContactData.InstanceARN`。坐席已删除或 ID 属于其他实例时返回 `Found=false` 和空的 `LastAgentName`，不抛异常，弹屏照常渲染。

## 故障排查

**`This account is at the IAM roles quota`** — 在 IAM 角色提示处填入一个已存在的 Lambda 执行角色，或删除无用角色，或申请提升配额。

**`无法判定实例 ... 的版本：读取 MAX_PACKAGE 实例属性失败`** — 先确认凭证有 `connect:DescribeInstanceAttribute` 权限。若手动执行 `describe-instance-attribute --attribute-type MAX_PACKAGE` 也报参数无效，说明 AWS 已经改动了这个未文档化属性，此时应把版本校验换成实例 ID 白名单，或改用实例 tag。

**`实例 #N ... 的版本是「X」，但这一步需要「Y」`** — ARN 传反了，或者这个实例确实不是所需版本。用 `aws connect list-instances` 配合上面的 `describe-instance-attribute` 逐个确认，再重新运行。

**`Lex bot ... has no available alias`** — 先构建 bot 并发布别名；flow 引用的是别名 ARN，而不是 bot 本身。

**`Could not associate the Q in Connect assistant automatically`** — 在实例 #2 上启用 Amazon Q in Connect 后重新运行。assistant 未关联时，IVR flow 无法创建。

**`These references still belong to another Connect instance`** — 导出文件里存在目标实例没有的资源。请按相同名称创建该资源，或从导出文件中移除对应模块。

**`Could not associate ConnectGetAgentName automatically: ServiceQuotaExceededException`** — 该实例已关联的 Lambda 数量到顶。注意 Service Quotas 里显示的「AWS Lambda functions per instance」可能高于实例实际执行的上限，所以数量没到显示值也可能被拒。处理方式：申请提升该配额，或在 Connect 控制台 → Flows → AWS Lambda 中解除一个不再使用的函数关联，然后重新运行脚本。未关联时弹屏流程仍能创建和运行，只是 `ConnectGetAgentName` 调用失败，走 `NoMatchingError` 分支，`Last Agent ID` 一栏为空。

**`Event hook DefaultAgentUI points at flow ... Dropping the hook`** — 目标实例里没有同名的弹屏 flow。`DefaultAgentUI` 没有同类型默认值可回退，所以务必让弹屏 flow 先于入呼 flow 部署（脚本已按此顺序调用）。

**函数已存在且 `PackageType=Image`** — 脚本部署的是 zip 包，请换一个函数名。

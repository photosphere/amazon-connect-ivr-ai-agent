# Amazon Connect AI IVR + 型号采集

两个 Amazon Connect 实例配合工作：AI 自助 IVR 负责采集来电者的产品型号，客户侧流程再把这个值取回来，用于路由和坐席弹屏。

`deploy_connect_lambdas.sh` 一次部署全部内容：一张 DynamoDB 表、两个 Lambda 函数，以及每个实例各一条 contact flow。所有输入都会先校验通过，才会创建任何资源。

## 工作方式

```
实例 #1 "Amazon Connect Customer Basic"          实例 #2 "Amazon Connect Customer"
Customer Inbound - AI IVR and Agent Transfer     AI Self-Service IVR - Model Capture
  1. 接起来电，开启日志与录音                      1. Lex V2 bot + Q in Connect AI agent
  2. 将来电者转到 IVR 号码           ────────▶       与来电者对话
  3. 来电者返回本流程                              2. ConnectSaveCustomerModel 把
  4. ConnectGetCustomerModel 读取     ◀────────       {CustomerNumber, ModelNumber}
     最新的 ModelNumber                                写入 DynamoDB
  5. 存为 QueueName 联系属性
  6. 转入 BasicQueue 等待坐席
```

两个 Lambda 共用一张 DynamoDB 表，并通过显式指定的区域访问，因此两个实例可以位于不同区域。

| 表 | `ConnectCustomerModel` |
|---|---|
| 分区键 | `CustomerNumber`（String，归一化为 `+数字`） |
| 排序键 | `CreatedAt`（String，ISO-8601 UTC） |

ISO-8601 时间戳按字典序即为时间序，所以取「最新一条」只需一次倒序查询加 `Limit=1`。

## 文件说明

| 文件 | 用途 |
|---|---|
| `deploy_connect_lambdas.sh` | 部署脚本，下文内容均围绕它 |
| `Customer Inbound - AI IVR and Agent Transfer.json` | 实例 #1 的 flow 导出文件 |
| `AI Self-Service IVR - Model Capture.json` | 实例 #2 的 flow 导出文件 |


## 前置条件

- PATH 中可用的 AWS CLI v2、`zip`、`python3`
- 与两个 Connect 实例同账号的凭证
- 所需权限：`connect:*`（describe/list/create flow、关联 bot 与 Lambda）、`lambda:*`、执行角色相关的 `iam:*`、表相关的 `dynamodb:*`、`lex:DescribeBot`、`lex:ListBotAliases`、`qconnect:GetAIAgent`
- 一个已构建且别名可用的 Lex V2 bot，需与实例 #2 同区域
- 一个 Amazon Q in Connect AI agent，需与实例 #2 同区域

## 运行方式

```bash
./deploy_connect_lambdas.sh
```

按顺序需要回答：

| 提示 | 说明 |
|---|---|
| 实例 #1 ARN | 必须是别名为 **Amazon Connect Customer Basic** 的实例 |
| 实例 #2 ARN | 必须是别名为 **Amazon Connect Customer** 的实例 |
| Conversational AI bot ARN | `arn:aws:lex:us-west-2:<acct>:bot/QIHKIB2VL1` |
| AI Agent ARN | `arn:aws:wisdom:us-west-2:<acct>:ai-agent/<assistantId>/<agentId>:$SAVED` |
| 资源名后缀 | 留空表示不加，例如 `AC`。会作用于下面所有名称 |
| Save / Get Lambda 名称 | 默认 `ConnectSaveCustomerModel`、`ConnectGetCustomerModel` 加后缀 |
| DynamoDB 表名 | 默认 `ConnectCustomerModel` 加后缀 |
| IAM 执行角色名 | 默认 `ConnectCustomerModelLambdaRole` 加后缀 |
| 各实例的 flow 名称 | 默认为导出文件中的名称加后缀 |
| 表所在区域 | 仅当两个实例位于不同区域时才会询问 |
| Proceed? | 在此之前不会创建任何资源 |
| 是否运行冒烟测试 | 写入一条探针记录、读回、再删除 |

### 资源名后缀

后缀用于让同一账号/实例中的多次部署互不冲突，**两个 Lambda 函数、IAM 角色、DynamoDB 表、两条 flow 全部生效**。该提示排在 AI Agent ARN 之后、所有名称提示之前，因此后续每个名称提示显示的默认值都已带上后缀，按回车即可。

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

### 使用其他实例别名

别名校验的作用是防止 flow 部署到错误的实例。比较时只看字母和数字，因此 `AmazonConnectCustomerBasic` 与 `amazon-connect-customer-basic` 都算匹配；但要求完整相等，所以在需要 `Amazon Connect Customer` 的位置绝不会接受 `Amazon Connect Customer Basic`。切换到其他环境时可覆盖：

```bash
EXPECTED_ALIAS_1="connect-us" EXPECTED_ALIAS_2="connect-us-2025" ./deploy_connect_lambdas.sh
```

## 部署前的检查项

1. 两个实例 ARN 格式正确、确实存在、别名符合要求，且必须是同账号下的两个不同实例。
2. Lex bot 存在、位于实例 #2 所在区域，并且有可用别名（优先选 `TestBotAlias`）。
3. AI agent 在其 assistant 下确实存在，且与实例 #2 同区域。
4. 当前凭证所属账号与实例所在账号一致。

任一项失败都会输出 `[FAIL]` 并在创建任何资源之前退出。

## Flow 改写

导出文件中的 ARN 属于它最初所在的那个实例，直接导入会被 Connect 拒绝。脚本内嵌的 Python 步骤会在上传前重写每个导出文件：

- Lambda、Lex bot alias、AI agent 与 Q in Connect assistant 的 ARN，全部指向本次运行校验过或新建的资源。
- 事件钩子和队列**按名称**在目标实例中重新映射。名称不存在时，钩子回退到目标实例中同类型的默认 flow（`Default agent whisper - Transfer to Agent` → `Default agent whisper`）。
- 完全找不到对应资源的钩子（例如只存在于源实例的弹屏 flow）会被删除，并重新接线相邻节点的 transition，不留悬空引用。
- 最后再扫一遍，若仍有 ARN 指向其他实例就直接失败，而不是把注定被拒的内容交给 API 报一个含义模糊的错误。

## 重复运行

可以放心重复执行。已存在的表和角色会被复用（表的键结构会先校验），Lambda 走原地更新，已建立的关联会跳过，遇到同名 flow 会先询问再覆盖其内容。Flow ID 保持不变，因此指向该 flow 的配置不会失效。

## 部署完成后

- 为两条 flow 分别申领或指派电话号码。
- 检查 `Customer Inbound - AI IVR and Agent Transfer` 中 `TransferParticipantToThirdParty` 模块的外呼号码：它仍是原导出文件里的号码，需要改成实例 #2 的 IVR 号码。

## Lambda 接口约定

两个函数都能处理 Connect 流程事件、直接测试事件以及 API Gateway 请求体，返回扁平的字符串 map，供 `$.External.*` 读取。

| | 入参 | 返回 |
|---|---|---|
| `ConnectSaveCustomerModel` | `CustomerNumber`、`ModelNumber` | `Status`、`CustomerNumber`、`ModelNumber`、`CreatedAt` |
| `ConnectGetCustomerModel` | `CustomerNumber` | `Status`、`Found`、`CustomerNumber`、`ModelNumber`、`CreatedAt` |

未传 `CustomerNumber` 时，两者都回退到来电者号码（`Details.ContactData.CustomerEndpoint.Address`）。Get 函数先用归一化后的号码查询，再尝试几种常见变体，因此 `+15551234567` 与 `15551234567` 会命中同一条记录。

## 故障排查

**`This account is at the IAM roles quota`** — 在 IAM 角色提示处填入一个已存在的 Lambda 执行角色，或删除无用角色，或申请提升配额。

**`Lex bot ... has no available alias`** — 先构建 bot 并发布别名；flow 引用的是别名 ARN，而不是 bot 本身。

**`Could not associate the Q in Connect assistant automatically`** — 在实例 #2 上启用 Amazon Q in Connect 后重新运行。assistant 未关联时，IVR flow 无法创建。

**`These references still belong to another Connect instance`** — 导出文件里存在目标实例没有的资源。请按相同名称创建该资源，或从导出文件中移除对应模块。

**函数已存在且 `PackageType=Image`** — 脚本部署的是 zip 包，请换一个函数名。

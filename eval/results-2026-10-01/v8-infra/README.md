# v8 实验室基础设施的证据（2026-10-01）

全部是合成数据。

- `handover-pack-n3.json`：技能 `handover-pack` 的 6 个虚构场景，每个跑 3 次（`eval/run_skill_evals.py --skills handover-pack --n 3`，
  Qwen3.6-35B-A3B NVFP4）：18/18 通过，第一次就合格（含不重问的修补）15/18。解读见 `skills/handover-pack/BENCHMARK.md`。
- `access-e2e-live.json`：`eval/tools/access_e2e.py` 对部署好的 v8 实例、经 Spark 真的 sshd 跑一遍：发邀请、邀请钥匙不能跑命令、
  用邀请钥匙兑换、邀请钥匙随后失效、bridge 上的成员路由（个人库被拒、普通成员看不到 Spark 健康、组织管理员看得到且有 GB10 统一内存和在线的模型）、
  经 bridge 共享 1 MB 原件、经 bridge 拉一份加密备份并用派生的钥匙打开（里面没有明文）、成员钥匙不能跑命令也不能开隧道、断开、
  `authorized_keys` 和开始前逐字节相同（只记哈希前缀）、断开后钥匙被拒：19/19。
- `spaces-c-e2e-live.json`（合同 C，共享空间的遗留项）：`eval/tools/spaces_c_e2e.py` 对部署好的实例跑一遍，三台合成的 Mac 都经 Spark 真的
  sshd 和各自的 bridge：成员甲用自己发的设备邀请接入第二台 Mac、`/v1/access/devices` 列出待签清单、甲签 `device.add` 和 `org.device_add`
  之后第二台能读、是组织空间的管理员；乙加入（邀请钉住 Spark 自己的主机公钥）并共享会议里 20 秒的原音，第二台 Mac 解开、长度和签名里的
  片段一致，Spark 上那个文件是 `MLB1` 密文、数据目录和日志里找不到声音里的哨兵，同一段录音的第二段原音被拒；同一个共享原样重发和重新做都
  只算一次；乙的快照随它引用的甲的素材一起移除；乙撤回原音后文件从 Spark 上消失、再取回答 410；甲以签名操作把乙（乙自己的 Mac）加为组织
  管理员；甲断开第二台 Mac、清单列出要退的空间和组织、`device.remove`（换钥匙）和 `org.device_remove` 之后清单为空；全部断开后
  `authorized_keys` 和开始前逐字节相同（只记哈希前缀）：29/29，21.7 秒。
- 测试：Mac（Python 3.12，SQLCipher 4.12.0）和 Spark（aarch64，`systemd-run --user --scope -p MemoryMax=1500M`）上的完整 pytest，
  数字见集成说明。

# iOS 源码与封存协议

工程源码位于 `mac/iOS/`，共享封存与配对协议位于 `mac/Packages/MindloomLink/`，发件箱和 SSH 发送实现位于 `mac/Packages/MindloomPhoneKit/`。

协议使用 X25519、HKDF-SHA256 与 ChaCha20-Poly1305，把合成条目封给 Mac；Spark 收件箱保存密文，Mac 取件后删除密文。SSH 密钥受强制命令限制，配对时固定主机公钥，撤销配对后拒绝继续投递。

合成数据的模拟器封存、投递、取件和撤销测量见 [EVALUATION.md §12](EVALUATION.md#12-封存协议模拟器测试)。本页描述源码与协议。

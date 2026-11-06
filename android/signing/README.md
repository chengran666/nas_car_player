# 播放器固定签名

`player.keystore` 是原 `C:/Users/cheng/.android/debug.keystore` 的完整副本，没有生成新密钥。debug 与 release 都使用它，因此现有应用仍可覆盖安装，设备识别码的签名范围不变。

Android 签名可以自行生成，不需要付费或私有 CA。这里沿用原密钥，是为了保留已安装应用的身份。

换电脑时，请把 `player.keystore` 连同项目一起复制到新电脑的 `android/signing/`。这份文件已经被 Git 忽略，单独 Git 克隆不会带上它；需要另外备份。不要重新生成密钥或把它上传到公开仓库。无需替换新电脑上其他项目的 debug 密钥。

现有 debug 密钥使用 Android 默认别名和密码，Gradle 已配置。恢复出厂设置或更换安卓用户仍可能改变设备识别码，固定签名不能避免这种情况。

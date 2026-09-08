# U-Boot 网页救砖

`ubi` 变体的 U-Boot 里内置了一个恢复页面 —— **Airoha Web U-Boot**。**机器刷坏了，插上网线用浏览器就能救回来** —— 不用串口，不用在电脑上架 TFTP 服务器，不用装任何工具。

当前版本 **0.3.0**，在 `master-airoha` 线上维护，XG-040G-MD 与 XG-040G-MF 共用同一份页面。0.1.x 的开发历史归档在 `archive/master-XG-040G-MD-httpd`。

> 想要图文版、从零开始的操作教程（含实拍接线图与串口截图），见 **[网页救砖指南](https://loong1996.github.io/ImmortalWrt-Airoha/recovery-guide.html)**。本文档是技术参考，覆盖设计取舍与踩过的坑。

> 只对 `ubi` 变体有效。`stock` 用原厂引导，不经过这个 U-Boot。

---

## 怎么用

### 进恢复页

四条路，只有最后一条需要串口：

| 什么时候 | 怎么进 |
| --- | --- |
| 想主动刷机 | **按住 reset 上电**，一直按着，等面板五个绿灯开始**流水**再松手（约 15 秒） |
| 机器起不来了 | **什么都不用做** —— 从 NAND 引导失败后会自己循环起网页，插上网线即可 |
| 闪存还是原厂布局 | **什么都不用做** —— `_firstboot` 里 `ubi part ubi` 挂不上就走 `_no_ubi`，不动闪存直接起网页 |
| 手上接着串口 | 引导菜单上用 ↑/↓ **选到第 9 项** 回车 —— `bootmenu_8` 直接 `httpd`，不经 `_firstboot`，不用掐 reset 的时机 |

这段时间里有一部分是 bootmenu 的等待。`button reset` 读的是那一瞬间的电平，不是累计计时，所以「一直按住」比「按几下」可靠。**流水灯亮起来就是进去了。**

第三条是**首次迁移**唯一不用掐时机的路，见下面第 ② 步。第四条走的是另一条代码路径：`check_buttons` 与 `_no_ubi` 都在 `_firstboot` 里，而第 9 项是 bootmenu 自己的条目，互不依赖。

### 传文件

1. 网线插到 **LAN 2~4 任意一个**。**LAN 1 无效**：它是 2.5G 口，走 GDM4 接外置 PHY EN8811H，U-Boot 里没有这条通路的驱动，也不带这颗 PHY 每次上电要灌的 MD32 固件；LAN 2~4 挂在 SoC 内置交换机上，U-Boot 只注册了这一个口（串口那行 `Using airoha-gdm1 device`）。换了机型就逐个口试，电脑拿到 `192.168.1.100` 的那个口就是对的
2. 电脑或手机的网口设成自动获取 IP，会拿到 `192.168.1.100`
3. 浏览器打开 **`192.168.1.1`**
4. 左栏「日常刷机」里选 `...-ubi-squashfs-sysupgrade.itb`，点「上传并刷写」
5. 确认框里核对文件名与大小，点「仍要写入」

**不用先配静态 IP** —— U-Boot 里带了个最小 DHCP 服务器，专门为了省掉这一步，那正是救砖流程最容易卡住的地方。

### 页面里有什么

左栏一项一个任务，每页只提交自己那几个字段，所以不存在「这两样不能一起传」的报错：

| 页 | 字段 | C 侧做什么 |
| --- | --- | --- |
| 日常刷机 | `firmware` | `ubi_write_production`：删 `fit` 与 `rootfs_data`，按文件长度重建 `fit` 写入 |
| 引导升级 | `bl2` `fip` `firmware`（可选） `format` | BL2 走 `mtd`；FIP 在位写 `fip` 卷；勾了「重建 UBI」先整个擦掉 `ubi` 分区 |
| 刷回原厂 | — | 单独的 `POST /stock?off=`，**body 就是镜像本身**（不是 multipart）。边收边写，逐块 `mtd_erase()` + `mtd_write()`，**位置保持**；偏移须按擦除块对齐，默认 `0x0` 整片。**没有大小上限** |
| 写入 UBI 卷 | `fvol_<name>`… `ubivol` `ubifile` `stay` | 出厂数据卷按 `HTTPD_FACTORY_VOLS` 校验长度后 `ubi write`；任意卷 `ubi check \|\| ubi create` 再写；`stay` 写完不重启 |
| 备份下载 | — | `GET /dump?vol=<名>` 走 `ubi read`，`GET /dump?off=&len=` 直接调 `mtd_read()`，**位置保持**（文件偏移 == flash 偏移，与 `dd` 同格式）。流式，只在内存里拿一个窗口；`len` 留空表示读到片尾；`GET /dumpinfo` 回最近一次的 crc32 与读不出的块数，见[下下节](#030-续心跳备份环境重启) |
| 设备详情 | — | 三段。网络那段另有 `GET /netset?ip=&mask=&save=`（静态地址）、`GET /netdhcp`（向上级路由要）与 `GET /netdhcpd?on=`（DHCP 服务开关）；前两者延后到答复发出之后才动手，并顺带关掉 DHCP 服务。`GET /info` 返回 JSON：设备树 `model` / `compatible`、DRAM、MTD 几何与分区、MAC、U-Boot 版本、UBI 卷表（含有没有 `fip` 卷）。卷表按卷名排序，ID 列是 UBI 卷号（按创建先后分配，不同迁移路径得到的号不同）；卷没有固定物理地址，所以不列 |
| 诊断 | — | 三段。「快速检查」`GET /check`，16 项分五组，见[下一节](#030拦截横幅体检日志)与[下下节](#030-续心跳备份环境重启)；「全片扫描」`GET /scan?off=`，一次 4 MiB，页面累加；「串口日志」`GET /log`，`?from=` 只回新字节、正文第一行是新偏移 |
| 环境变量 | — | `GET /env` 只读列出全部 env；`GET /envreset` 跑 `env default -a && saveenv` |
| 启动与重启 | — | `GET /reboot` 答复发出并被确认之后才 `reset`；`GET /boot` 执行 `bootcmd`；`GET /bootonce` 让下次开机停在本页 |
| 关于 | — | 静态 |

页面还在后台每 3 秒问一次 `GET /ping`，那是它判断设备还在不在的唯一依据。

页面本身**不含任何机型串** —— 机型、闪存、卷表都是请求时读出来的，所以两款机器共用同一份 HTML，第三块板也是。

`/info` 里的 `uploadmax` 是 `httpd_parse()` 拿来卡 `Content-Length` 的那个上限（`upload_max()`，512 MiB 板子约 248.8 MiB）。报出来是为了让页面在**文件还在磁盘上的时候**就说不，而不是传了两百多兆之后才被 400。

它只管**要先整个进内存才写**的那几页（引导升级、日常刷机、写入 UBI 卷），那些文件本来就只有几兆到十几兆。「刷回原厂」不受它管 —— 见下面的 `POST /stock`。

上传结束设备回一行 `{"ok":1}`，页面自己切到「上传完成」；勾了「写入后不重启」就留在原页、把表单清空。能在上传前查出来的错误 —— 出厂卷长度不对、偏移没按擦除块对齐或超出容量、卷名非法 —— 设备直接回 400，原因显示在进度条下面，此时什么都还没写。

### 0.3.0：拦截、横幅、体检、日志

四样都是同一份用户日志引出来的：机器停在 BL2 报 `No volume named fip` —— BL2 写进去了，`fip` 卷没建。页面当时允许勾「重建 UBI」却只传 BL2，而写入失败只在串口上可见，没串口的用户看到的就是「刷完没反应」。

**拦截。** 页面与 C 侧 `httpd_validate()` 各拦一遍：页面不是唯一的客户端，而且页面只认自己那份 `/info`，拿不到或过期了就形同虚设。C 侧在回 200 之前查 —— 200 一出，写入失败就只在串口上可见。查的顺序：勾了「重建 UBI」却没带 U-Boot 文件，400 `rebuilding UBI without a U-Boot FIP would leave nothing to boot`；不重建、也不是整片刷回原厂时，按 `/info` 的方式先挂一次 UBI。挂不上，凡是要写卷的（固件、U-Boot、出厂卷、任意卷）都拒；只写 BL2 也拒，除非勾了「写入后不重启」—— 写完一重启，BL2 找不到 `fip` 卷照样停。挂上了但没有 `fip` 卷，这次又没带 U-Boot 文件、又会重启，同样拒。页面的确认框把同样几条做成硬错误（不出「仍要写入」）：日常刷机与写入 UBI 卷在没有 UBI 或没有 `fip` 卷时拦下（创建卷勾了不重启可放行）；引导升级没有 UBI 时必须勾重建，有 UBI 没 `fip` 卷时必须带 U-Boot 文件。

**顶部横幅。** `/info` 的 `ubi` 对象多了 `fip` 字段。页面加载后两种情况亮红条：`ubi` 为 `null`（首次迁移：三样一起传并勾重建）；有 UBI 但没 `fip` 卷（现在跑的 U-Boot 只在内存里，断电就没）。串口 xmodem 灌进来的 U-Boot 正是第二种。

**健康检查（`GET /check`）。** 在「诊断」页的「快速检查」段，进入该页时自动跑一次，C 侧顺序跑：闪存型号；扫全片坏块（`mtd_block_isbad`，落在 `bl2` 分区那块的算异常）；`bl2` 分区 `0x800` 处有没有 FIP 容器头 `0xaa640001` —— BL2 与 FIP 都是 fiptool 打的包，共用这个魔数，原厂与 tcboot 的引导也在同一位置放同一个头，所以它只回答「有没有东西可启动」，分不出是谁的；UBI 能否挂载、卷数、坏块、空闲 LEB；`fip` 卷整卷读一遍（静态卷，UBI 读时校 CRC）再看头；`fit` 卷读头 4 KiB 看 `0xd00dfeed`，并拿 `totalsize` 对卷内长度；`ubootenv` / `ubootenv2` 在不在（名字来自 `CONFIG_ENV_UBI_VOLUME*`）；`HTTPD_FACTORY_VOLS` 里的出厂卷读不读得到、是不是全 `ff` 的空卷，`HTTPD_FACTORY_MAC`（defconfig 里 `ri:0x3e`）指到的那个卷顺带把里面的 MAC 显示出来；最后一行是 U-Boot 自己的 `ethaddr`（MAC 用十六进制手拼，`%pM` 与中文混在一个格式串里会乱码）。每项绿 / 橙 / 红加一句人话，同一段也打到串口。读取落在 `$loadaddr`，上传进行中回 503。「复制诊断信息」把设备详情与检查结果拼成纯文本，群里求助贴这个。

**启动日志（`GET /log`）。** 打开 U-Boot 自带的 `CONFIG_CONSOLE_RECORD`（64 KiB），把 `gd->console_out` 原样吐出来，页面去掉 ANSI 转义后显示，可复制。`203` 补上一处上游的遗漏：重定位后 `console_record_init()` 重新分配缓冲，重定位前录的横幅、CPU、DRAM 三行会丢，现在先搬过来。缓冲满了不覆盖、只丢新的，末尾标一句「日志缓冲已满」—— 64 KiB 对一次救砖绰绰有余。侧栏单独一页，进入时自动读。`/info` 多一个 `log` 字段，没开录制的固件不显示这一页。重定位前那段录在早期 malloc 区的小缓冲里，显式设为 2 KiB（`CONSOLE_RECORD_OUT_SIZE_F`，上游默认 1 KiB；实机重定位前只打横幅、CPU、DRAM 约 120 字节），搬完后清掉它留下的溢出标志，免得 64 KiB 的缓冲被误报为满。

菜单标题与 `show_about` 跟着升到 0.3.0，`envver` 4 → 5。

**先看再写。** `files/httpd/preview.py page.html` 生成一个能直接在浏览器里打开的预览：所有请求由页内的桩应答，右下角切换设备状态（正常 / 没有 UBI / 没有 `fip` 卷 / 不带日志 / `/info` 失败）与提交结局（成功 / 400 / 断线）。改页面先在这里对齐布局与措辞，再进 C。桩给的数据就是真实端点给的数据，所以对齐的是同一份东西。

### 0.3.0 续：心跳、备份、环境、重启

**心跳（`GET /ping`）。** 上一轮把「设备到底还在不在」留给了用户自己猜 —— 页面是静态的，路由器重启了、正在写、网线松了，看上去全都一样。现在页面每 3 秒问一次 `/ping`，回的是 `{"up":<开机毫秒数>}`，单次超时 2.5 秒，**连续两次失败**才算断。侧栏左下角一颗点（绿 已连接 / 黄 无响应 / 红 已断开），断了才弹全屏说明框。

弹框只在页面确实做不了任何事的时候出现，而且分口径 —— 因为「断开」的原因决定了用户该不该慌：

| 情形 | 说什么 | 有没有「重新连接」 |
| --- | --- | --- |
| 不知道为什么 | 已断开与路由器连接。检查网线与电源。面板齐闪说明在写入，等它写完 | 有，另外每 2 秒自动重试 |
| 刚点了重启 | 设备正在重启，约 1–2 分钟，回来后自动刷新 | 没有 |
| 「写入后不重启」提交完 | 设备正在写入，面板齐闪，**不要断电** | 没有 |

**自己发起的读取不弹框。** 体检和整片备份会让设备静默几十秒，但那两页上本来就写着在读什么 —— 再盖一层框是噪音。这两种情况只让左下角的点变色、写「设备忙…」，超过约两分钟还不回来才退回通用提示。

**`up` 倒退就是重启过了。** 恢复时如果 `up` 比上次小，页面 `location.reload()`：卷表、env、体检结果全是重启前的，留着比没有更坏。同一次上电内恢复则不刷新，不打断手上的事。

顺带把上一轮设计的「写入结果回报」整个删了。它只有在勾了「写入后不重启」时才看得见（正常路径写完就 `reset`，静态变量随之清零），而那唯一的场景现在由心跳白拿：设备写卷时不响应，写完服务恢复，心跳回来就把进度条改成「设备写完了」。C 侧不用记任何东西。

**备份下载（`GET /dump`）。** 侧栏单独一页。UBI 卷逐个一行，`ri` / `bosa` 排最前并标「出厂数据」；下面一块按 flash 偏移与长度取任意区段，「整片下载」把偏移归零、长度留空。

**原厂机能不能用它备份？** 能，但要先有串口。原厂跑的是 tcboot，那里面没有这个页面 —— 得先做[首次迁移](#首次迁移从-tcboot--原厂-换到-ubi-布局)的 ①②，串口 xmodem 把 preloader 与 fip 送进 RAM，让我们的 U-Boot 在内存里起来。**这两步一个字节都不写闪存**，所以进到网页那一刻闪存还是完整的原厂内容。原厂布局没有 UBI，卷列表会直接说「UBI 未挂载，只能用下面的原始区段」——而原始区段读的是**裸 mtd 主设备，不经过 UBI，也不看分区表**，所以私有布局照样读得出来，`romfile`、`config` 这些也都在里面。偏移 0、长度 `0xEBA0000` 就是原厂的 `all_flash`；连原厂不用的尾部一起要就把长度留空（等同 `0x10000000`）。原厂系统还进得去的话，[U 盘 dd](backup-and-restore.md) 那条路更全（逐分区、带 md5）；`/dump` 补的是「系统进不去、但还能接串口」的那一档。

要紧的是**它补上的那个时间窗**：首次迁移的 ① ② 两步全在 RAM 里跑，进到网页那一刻闪存还是完整的原厂内容，而下一步勾「重建 UBI」就把 `ri`（MAC、SN）、`bosa`（光模块校准）一起擦了。[原厂备份](backup-and-restore.md)那条 telnet + U 盘 dd 的路更全（还能拿到 `romfile`、有 md5），但前提是原厂系统还进得去。`/dump` 服务的是**系统已经进不去、或者当时忘了备份、人已经站在网页上**的情况 —— 那时它是唯一还能抢救出厂数据的机会。「引导升级」的重建开关旁和「刷回原厂」的说明里各有一句话指向它。

实现上**它是流式的**：只在内存里拿一个
窗口（最大 8 MiB），浏览器抽多少就补多少。
`Content-Length` 给的是完整长度，**多大都是一个文件**。

一开始不是这么写的 —— 最早的版本把整段读进内存再发，
而 512 MiB 的板子上 `$loadaddr` 之上只剩约 248 MiB，256 MiB 的整片
放不下，于是页面把它切成两段让用户分两次下。
**那不是功能，那是把我们的内存预算搬给了用户看。**
改成流式之后分块只是 `dump_fill()` 内部的事，页面上连个开关都没有。

三件事让流式可行：

* **`httpd_tx()` 本来就是按偏移拉的。** 命中窗口就是一次 memcpy；
  落在窗口后面（重传）就按那个窗口的**检查点**重读一次。
* **坏块让「输出偏移 → flash 偏移」不是一个乘法。**
  所以向前跑的时候把每个窗口起点的 flash 偏移记下来
  （`dump_ckpt[]`，512 项够 4 GiB 的片子），往回跳直接查表。
* **crc32 只在向前那一遍累加**，重传不会把同一段算两次。
  好处是它算的是**真正发出去的字节**，比对一个暂存区做校验和
  说得更多；代价是它要等传完才有，所以 `/dumpinfo` 的序号是在
  **传完**时才跳的 —— 页面能拿到这个数，本身就证明传到了头。

填一个窗口会把网络循环堵一下（几百毫秒），TCP 等得起；
副作用是设备不再「先静默几十秒再开始传」，进度条一上来就动。

落点仍然不能用 `$loadaddr`：`httpd_rx()` 会把每一个新连接的
请求头写进那里。现在只要空出一个窗口，所以从可用内存顶部
往下取一小块就够，间隔 2 MiB 招呼住请求头和体检在 `$loadaddr`
上的读取。上传会冲穿任何间隔，所以下载期间的 POST 直接回 400 ——
悄悄截断会让用户拿到一份自以为好的坏备份。同一时刻只允许一个
下载，第二个从**另一个**缓冲区回 503（用 `dump_fail()` 会写坏正在传的
那份的响应头）。

**被放弃的下载得能收回来。** 用户在浏览器里点取消、关掉标签页、网线一
松 —— 传输永远到不了末尾，`dump_busy` 就一直挂着，之后**每一次上传都会
被 503 挡掉**；而页面是个单页应用、正常操作不会重新加载，用户只能自己
按 F5。所以 `dump_tx()` 每发出一次就记一下时间，`DUMP_IDLE_MS`（15 秒）
内一个字节都没出去，下一个请求就把缓冲区接管过去。误伤一个只是暂停了的
下载也不会让谁拿到坏备份：crc32 只在向前那一遍累加，接管之后序号根本
不会跳，`/dumpinfo` 就是不报。

### 刷回原厂是流式的：`POST /stock`

整片镜像放不进内存。`$loadaddr` 到 U-Boot 重定位后的落脚点之间，512 MiB
的板子只有约 249 MiB，而 256 MiB 芯片的裸镜像正好 256 MiB。**分段是我们
的问题，不是用户的问题** —— 所以这条路不再把镜像留在内存里：字节一边到
一边往闪存写，上传多大就不再是个问题。

它**故意不是 multipart**。页面上别的表单都带好几个字段、也都小到可以整个
暂存，那套代码一行没动。流式解 multipart 意味着增量扫 boundary、还要推断
负载在哪里结束 —— 而结尾定界符判断错两个字节，最后一个擦除块里就是两个
字节的脏数据。裸 body 没有这个问题：**偏移在请求行里、长度在 Content-Length 里，第一个包到手就全知道了**。

环形缓冲只需要吸收乱序。栈自己会把 `[rcv_nxt, rcv_nxt + rcv_wnd)` 之外的
段丢掉（`net/tcp.c`），而 `rcv_wnd` 是 `PKTBUFSRX * TCP_MSS`，只有几十 KiB
—— 四个擦除块就够，代码里取到 4 MiB 封顶。`rx()` 返回值就是"从这一段开头
算起收下了多少字节"，放不下就返回 0，对方自然会重传：

```c
tmp_len = tcp->rx(tcp, buf_offs, buf, len);
if (tmp_len < 0) { RST; destroy; }
if (tmp_len) tcp_hole(tcp, tcp_seq_num, tmp_len);
```

**代价是：传失败不再意味着闪存没动过。** 这是流式的定义，辩不掉，所以改成
让失败可以活下来：出错**不重启**，页面还在内存里跑着。

既然如此，**两种失败就必须分开说**，`st_fail()` 按有没有动过第一个擦除块
挑状态码：

| | 何时 | 闪存 | 页面 |
|---|---|---|---|
| `400` | 头还没解完就挡下（偏移没对齐、超容量、接收环放不下） | 未改动 | 「设备拒绝了上传（400）」，改完重来 |
| `500` | 开始写之后擦除或写入失败 | **不一致** | 「设备写入失败（500）」，顶部挂常驻红条 |

连接直接断掉时页面并不知道写到哪儿了，所以**按 500 处理**。

成功的响应体是一行，页面把它拆开摆在自己的完成页上：

```
ok 268435456 bytes crc32 3f2a91c4 skipped 0
```

`crc32` 算的是**设备实际收到的字节**，跟 `/dumpinfo` 备份时报的是同一个
算法同一段数据 —— 备份记一次、写回核一次，读出到写回这条链路就闭合了。
`skipped` 是路上跳过的坏块数，镜像里对应那几块的内容没有落盘（也落不了，
见下一节）。

页面这一侧对应的是单独一页 `p13`：拿到 200 的时候镜像已经整份落盘、设备
正要重启，落回「上传完成」页（那上面写着"设备正在自行写入"，还列一张未来
时的步骤清单）是说反了。

### 位置保持：文件偏移就是 flash 偏移

坏块的处理有两种做法，差别不在代码量而在**这份文件跟谁通用**。

`cmd/mtd.c` 里 `mtd read` / `mtd write` 共用的那个循环是**压缩式**的：

```c
if (mtd_is_aligned_with_block_size(mtd, off) && mtd_block_isbad(mtd, off)) {
        off += mtd->erasesize;
        continue;              /* io_op.datbuf 不动 */
}
```

flash 偏移前进而内存指针不动，于是文件里第 N 个字节落在哪，取决于它
前面有几个坏块。0.3.0 起初两侧都照着它做，结果是**只和自己通用**：
社区里流传的原厂 `all_flash.bin` 基本都是 `dd if=/dev/mtd0` 出来的
（坏块在文件里占着位子），这种文件写进一台有坏块的机器，坏块之后的
一切整体前移一个擦除块 —— 而原厂引导按绝对偏移找东西。

现在两侧都是**位置保持**，和 `dd` 同格式：

| | `dd if=/dev/mtd0` | `/dump` 与「刷回原厂」 |
| --- | --- | --- |
| 文件偏移 ↔ flash 偏移 | 恒等 | 恒等 |
| 读到坏块 | 照读 | **照读**，读失败才填 `0xff` 并记一笔 |
| 写到坏块 | 照写（写不进去） | 跳过不写，**源指针照常前进** |

读侧因此**根本不看坏块标记** —— `mtd_read()` 自己不跳，跳过的逻辑
本来就是我们加的。被软件标坏但内容还在的块（用久了磨损标坏的那种）
也就跟着捞回来了。只有 `mtd_read()` 真的失败（`-EBADMSG`，ECC 纠不
回来）才填 `0xff`，那时本来也没有别的东西可给。这同时修掉一个毛病：
以前一个块读不出，整份 235 MiB 的备份直接中止。

写侧那道 `mtd_block_isbad()` 则不能省，而且是**承重**的。`nanddev_erase()`：

```c
if (nanddev_isbad(nand, pos) || nanddev_isreserved(nand, pos)) {
        if (nanddev_isreserved(nand, pos)) return -EIO;
        /* remove bad block from BBT */
        nanddev_bbt_set_block_status(nand, entry, NAND_BBT_BLOCK_STATUS_UNKNOWN);
}
return nand->ops->erase(nand, pos);
```

对坏块它**把 BBT 条目摘掉再照擦不误** —— 擦除连 OOB 一起擦，出厂坏块
标记就在 OOB 第 0 字节。那块从此被当好块用，以后往里存的东西会静静
地坏掉。命令层的 `mtd erase` 有 isbad 保护，`mtd_erase()` 这个 API
没有，所以逐块循环里那道检查是唯一的防线。

剩下不完美的一点是物理性的：**块死了就是死了**。备份之后新坏一块，
它的内容取不回来 —— 但损伤是局部的（丢那一块），而不是压缩式下的
全局错位。串口日志里会列出跳过的块地址。

**能核对的备份才是备份。** 传完后 `GET /dumpinfo` 回报名字、长度与
crc32。页面读不到隐藏 frame 的**响应头**，所以它先问一次记下序号、再开始
下载、然后轮询到序号变化为止，把每一份追加成一行（不覆盖，
因为一次备多个卷的人需要每一份的 crc32）。本地 `crc32 文件名`
一比就知道有没有坏。

响应**体**倒是读得到，这正好解决了另一个问题：下载走隐藏 frame，设备的
400 / 503 / 507 全都渲染在里面、用户一个字也看不见，只能等轮询在四分钟
后放弃。而**真下载会被浏览器接走、frame 不触发 `load`，只有错误页会**
—— 那就是信号。`dlrefused()` 拿这个事件把 frame 里的文字读出来贴到状态
行上，顺手停掉轮询。四行代码，把所有拒绝从「静默四分钟」变成当场看见。

**环境变量（`GET /env`）。** 只读，按名字排序，页面上带过滤框和「只看关键项」开关（`bootcmd` / `bootdelay` / `bootmenu_*` / `envver` / `ethaddr*` / `boot_*` / `httpd_*` / `ubi_*` / `check_buttons` 与网络那几个）。**不做编辑** —— 一个救砖页面把 `bootcmd` 改坏是很差的交易；唯一提供的写入是下面那个整体恢复，它不可能让环境落到这一版没见过的状态。

**恢复默认环境（`GET /envreset`）。** `env default -a && saveenv`，走确认框。`ethaddr` 是手工放回去的：`env default -a` 会连它一起清掉，出厂 MAC 在 `ri` 卷里、下次启动时脚本会重新导出，但**这一次启动**不会 —— 页面上写着「出厂 MAC 不受影响」，所以代码得让这句话是真的。UBI 挂不上时 `saveenv` 会失败，回 `ok` 而不是 `ok saved`，页面据此说「已恢复，但保存失败，断电即失」。

**重启（`GET /reboot`）。** 侧栏最下面一页。答复发出并被 TCP 确认之后才 `reset`，和刷写走同一个形状（`reboot_pending` + `net_set_state(NETLOOP_SUCCESS)`，回到 `do_httpd` 再动手）—— 在 tx 回调里 `reset` 会把响应丢掉，页面看到的就成了「连接中断」而不是「正在重启」。

**体检长到 16 项、分五组。** 平铺 16 行已经读不动，所以 `/check` 的每一项多回一个 `g` 字段，页面按它插分组标题。新增的六项都是「没有串口就查不出来」的那类：

| 组 | 新增项 | 查的是什么 |
| --- | --- | --- |
| 引导 | `envver` | 闪存里的值 vs **这一版编进去的默认值**，落后就说下次正常启动会自动刷新 |
| 引导 | `bootcmd` | 同上逐字比对，不同就是被人改过，原文一并列出 |
| 引导 | 引导菜单 | 条目数 vs 默认条目数 |
| UBI | 磨损 | `ubi->max_ec` / `mean_ec`，超过 20000 次转黄 |
| UBI | 固件 | FIT 里的 `description` 与 `timestamp` —— 回答「现在闪存里躺的是哪一版」，求助贴里最值钱的一行 |
| 环境 | `ubootenv` / `ubootenv2` | 各读头 4 字节（U-Boot 自己的环境 CRC）比对，说得出两份是不是同一个环境 |

外加「U-Boot MAC」现在会和出厂卷里读到的 MAC 对一遍，不同就提示「重建 UBI 后常见，将备份的出厂卷写回即可」。

**「可写空间」算的是刷机可用量，不是 `avail_pebs`。** 只报 `avail_pebs` 的话，一台正常跑着的机器永远是 0 MiB 并顶着黄条：OpenWrt 首次启动会把 `rootfs_data` 铺满 `fit` 没占的每一块。而写固件的两条路（板子自己的 `ubi_write_production` 和内置的 `DEF_WRITE_FIT`）都是**先删 `fit` 与 `rootfs_data`、再建新 `fit`**，所以这两个卷是可用量而不是占用量。现在把它们的 `reserved_pebs` 计进去，并把「其中现在空闲多少、多少是写入时腾出来的」一并写在那一行上，好和上面的卷表对得起来。引导器不在这个名单里：写 `fip` 是在卷自己的预留里原地写，不需要腾任何东西。

**「引导菜单预览」的序号是串口上的按键，不是变量名里的 `n`。** U-Boot 的 bootmenu 只有一位快捷键（`1`~`9`，然后 `a`~`z`，`0` 留给 Exit），所以 `bootmenu_0` 在屏幕上是 `1.`、`bootmenu_9` 是 `a.`。照变量名从 0 标起会跟用户眼前的菜单差一位。

两处实现上的坑：

* **`env_get_default()` 不能用来比 `bootcmd`。** 它在环境未就绪的路径上答复，而那条路走的是一个 **32 字节的静态缓冲区** —— `bootcmd` 和菜单条目回来时是截断的，拿它比「改没改过」永远是「改过」。改成直接扫 `default_environment[]`（`name=value` 平铺、空串结尾）。
* **读 FIT 的描述不能只读头 4 KiB。** sysupgrade 的 FIT 有十几 MB，是因为镜像数据就存在 struct block 里，于是 strings block 被顶到了文件末尾 —— 而 libfdt 解一个属性名要同时用到两头。所以分两次读（头部最多 128 KiB + strings block）拼到一起，再改写头里的偏移让它自洽。拼不出来就只报「是一个 FIT」，不猜。

**内存推导过程也进日志了。** `206` / `310` 的地址混叠探测原本一声不吭，只有最后 `DRAM: 512 MiB` 一行。现在每一步都打：锚点地址与原值、每个候选写到哪、写完锚点读回什么、结论和 dts 是否一致。`dram_init()` 跑在 `console_init_f` 之后，所以这几行落在重定位前的录制缓冲里，**没有串口也能在「诊断」的「串口日志」段看到**。写的过程里顺手补了个洞：探测循环从 512 MiB 起，真装了更小颗粒的板子每个候选都会绕回、答出 512 MiB，U-Boot 就会把不存在的内存交给内核 —— 现在 dts 低于 512 MiB 时直接采信 dts、跳过探测。

### 面板灯是唯一的进度来源

| 面板 | 含义 | 能拔网线吗 |
| --- | --- | --- |
| 五灯**流水** | 网线还在用：在等你上传，或「刷回原厂」正在边收边写 | ❌ |
| 五灯**齐闪** | 正在写 flash，上传已结束 | ✅ 随便拔 |
| 熄灭后重启 | 写完了 | ✅ |

灯语回答的就是一个问题：**网线现在能不能拔**。流水＝还在用，齐闪＝用完了。断电则是任何时候都别做，这一条不靠灯区分，页面上每一处写入前都写着。

**上传结束后网页就没用了。** `net_loop()` 在写入开始前就返回，连接已经关闭，浏览器和设备之间没有通道 —— 页面上那句「写入期间页面收不到任何消息」说的就是这件事。

**「刷回原厂」是例外，它边收边写**，所以写的时候连接还开着、`net_loop()` 还在跑。于是它**全程保持流水**、根本不切齐闪：流水的含义本来就是「网线还在用」，而这一页从头到尾都在用。原先它在写第一块时去起了齐闪，可流水由 `net_loop()` 的超时回调驱动、并没有停，两套图形同时点同一排灯，看上去既在流水又在闪 —— 这是报上来的那个现象。现在流式那条路一次都不调 `httpd_blink_start()`，写完时用 `httpd_led_stop()` 熄灯，和别的路一样以「灭掉再重启」收尾。`httpd_blink_start()` 里仍然留了一句 `httpd_led_stop()`：今天没有调用方需要它，但这一类叠加正是刚踩过的坑，让「起齐闪」自带「停流水」比指望调用方记得便宜。

「进度到哪儿了」这个问题由页面回答 —— 流式那页有自己的进度条，不需要灯来兼职。

**齐闪**期间拔网线随时安全，写 flash 不经过网络；要命的是断电。

「写入后不重启」的场合灯会从齐闪回到流水 —— 那就是写完了，可以刷新页面传下一个。写卷期间设备不响应网络，这时再传只会报连接中断。

### 传了固件就等于恢复出厂，只换引导器不是

`ubi_write_production`（写 `fit` 卷）会先删掉 `rootfs_data` 给新卷腾地方，所以**这次上传里只要带了固件，配置必然被清空**，勾没勾别的选项都一样。

**只传 `preloader.bin` / `bl31-uboot.fip`、不传固件**的那种日常更新引导器则不清配置。`954` 之前会 —— 那是个 bug，见补丁清单里 `954` 那节。

系统还能进的话，请用 `sysupgrade -c` 保留配置。这个页面的定位是「系统起不来了」。

---

## 首次迁移：从 tcboot / 原厂 换到 ubi 布局

只有这一次需要串口，之后再也不用。

**① 串口进 BootROM，xmodem 传两个文件**

按住 reset 上电，看到 `Press x` 时按 `x`，依次传：

```
immortalwrt-airoha-an7581-nokia_xg-040g-md-ubi-preloader.bin      ← BootROM 收，进 SRAM
immortalwrt-airoha-an7581-nokia_xg-040g-md-ubi-bl31-uboot.fip     ← BL2 收，进 DRAM
```

传两个是硬约束：BootROM 只把 BL2 收进 SRAM，那里放不下 431 KB，它也不解析 FIP 里的 BL33。

reset 按不按都行 —— 下一步不需要掐时机。

**② U-Boot 在 RAM 里起来，直接进网页**

`_firstboot` 在碰 flash 之前连着两道闸，任意一道拦下都落到网页：

```
_firstboot=setenv _firstboot ; run check_buttons ; ubi part ubi || run _no_ubi ; run ethaddr_factory ; ...
_no_ubi=echo ; echo This flash carries no usable UBI. Leaving it alone. ; echo ... ; setenv bootmenu_0 "Start web recovery server at http://$ipaddr=run boot_httpd_forever" ; bootmenu 3 ; run boot_httpd_forever
```

`_no_ubi` 里那句 `setenv bootmenu_0` 是这段能成立的关键：`bootmenu_default=0`，而未初始化环境里的 `bootmenu_0` 是「Initialize environment.=run _firstboot」—— 菜单一超时就会绕回 `_firstboot`，再挂不上 UBI、再进菜单，转圈。把第 1 项当场换成「起网页」，超时执行的就是我们要的那条，且它 `while true` 不返回。改的是内存里的副本，没有 `saveenv`，下次开机不留痕。结尾那句 `run boot_httpd_forever` 是兜底：用户在菜单上选了 Exit 或选了一条会返回的条目时，仍然落到网页，而不是继续往下走进 `ubi_format`。

| 走法 | 做什么 | 代价 |
| --- | --- | --- |
| **什么都不做** | `ubi part ubi` 在原厂布局上挂不上 → `_no_ubi` 把菜单停 3 秒，超时自动进 `boot_httpd_forever` | 不用抢，超时就是你要的 |
| **reset 一直按着** | `run check_buttons` 接住，同样进 `httpd` | 没有时间窗口 |
| **在那 3 秒里按任意键** | 停在菜单上，可以改走 TFTP 或进命令行 | 只给串口用户 |

第一道是按键。第二道是 flash 自己，也是首次迁移真正靠得住的那道：没有它，RAM 里的 U-Boot 会直奔 `_init_env`，在异构 flash 布局上建卷失败、回落 `ubi_format`（`ubi detach ; mtd erase ubi && ubi part ubi ; reset`），于是**两件事同时发生** —— 刚传进来的 U-Boot 随 `reset` 一起没了，而 `ubi` 分区已经被擦干净：`bl2` 分区里的原厂 BL2 还在，可它要加载的 FIP 没了，下一次上电停在 `ERROR: Failed to decompress image` 然后 PANIC。只能再走一轮 xmodem。

> 早先只有 `check_buttons` 这一道，文档也写着「松了 reset 就在 3 秒里选第 9 项」—— 那条路在**首次迁移这一轮根本不存在**：没初始化过的机器默认环境里 `bootdelay=0`、`bootmenu_delay=0`，菜单不停顿，而把它们抬到 3 的 `_switch_to_menu` 在 `_firstboot` 里边，来不及。第 9 项要等迁移完成、环境存下来之后才用得上。
>
> 擦 flash 从此只发生在用户在网页上勾了「重建 UBI」的时候 —— 那时该写回去的镜像已经在这次上传里了。启动流程不再替他做这个决定。

看到流水灯就成了（按着 reset 的这时松手）。

**③ 网页一次传完三样**

左栏切到「引导升级」：

| 格子 | 文件 |
| --- | --- |
| BL2 | `...-ubi-preloader.bin` |
| U-Boot | `...-ubi-bl31-uboot.fip` |
| 固件 | `...-ubi-squashfs-sysupgrade.itb` |
| 重建 UBI（开关） | **必须打开** —— 旧布局上没有有效的 UBI，不擦就建不了卷 |

**④ 自动重启，完成**

`_firstboot` 会建出 `ubootenv` / `ubootenv2` / `ri` / `bosa`，然后正常引导。

> ⚠️ **重建 UBI 会擦掉出厂 MAC。** `ri` 卷没了，`ethaddr_factory` 读不到，MAC 变成默认值。从[原厂备份](backup-and-restore.md)里把 `ri` 写回去即可，随时能做，不影响使用。

### 日常更新引导器就不用勾了

BL2 走 `mtd`，完全不碰 UBI；FIP 走 `httpd_write_fip`，它自己只换 `fip` 那一个卷，连 `rootfs_data` 都不动（`954`，见下）。**只要 `ubi part ubi` 挂得上，就不要开重建。**

覆盖正在运行的 U-Boot 是安全的：SPI-NAND 不能 XIP，当前这份早就解压在 DRAM 里跑了，和 flash 上的副本没关系。

---

## 补丁清单

都在 `package/boot/uboot-airoha/patches/`：

| 补丁 | 做什么 |
| --- | --- |
| `202-net-add-httpd-recovery-server` | 全部的 httpd —— 新增 `net/httpd.c`，外加 `net.c` / `Kconfig` / `Makefile` / `net-legacy.h` 四处挂接；`Kconfig` 里四个选项：`CMD_HTTPD`、`HTTPD_FACTORY_VOLS`（出厂数据卷名与长度）、`HTTPD_FACTORY_MAC`（出厂 MAC 在哪个卷的哪个偏移）、`CMD_HTTPD_STOCK_RESTORE`（按板启用裸写） |
| `203-console-record-keep-pre-relocation-output` | 重定位后保留重定位前的 console 录制内容，`GET /log` 才能从横幅看起 |
| `950-configs-xg-040g-md-enable-httpd` | MD defconfig：`PROT_TCP` / `CMD_HTTPD` / `CYCLIC`，`HTTPD_FACTORY_VOLS="ri:0x40000 bosa:0x40000"`，`HTTPD_FACTORY_MAC="ri:0x3e"`，`CMD_HTTPD_STOCK_RESTORE=y`，`CONSOLE_RECORD` 64 KiB（重定位前 2 KiB） |
| `951-defenvs-xg-040g-md-httpd-recovery` | MD 触发路径，与两条 httpd 专用的 env 脚本 |
| `952-xg-040g-md-bootmenu-web-recovery-branding` | MD 引导菜单署名、手动开服务的菜单项、`envver` 自动刷新、`ethaddr` 两道闸 |
| `954-xg-040g-md-httpd-fip-preserve-rootfs-data` | MD defenv 加 `httpd_write_fip`（网页更新引导器不清配置） |
| `960` / `961` / `962` | MF 的同一套：defconfig、触发路径、菜单 |

页面本身不在补丁里手改：源文件是 fork 的 `package/boot/uboot-airoha/files/httpd/page.html`，`gen.py` 把它逐行转成 C 字符串塞进 `net/httpd.c` 的 `PAGE_BEGIN` / `PAGE_END` 之间。改页面 → 跑脚本 → 重新生成 `202`。

0.1.x 里 `953`（刷回原厂）和 `954`（`httpd_write_fip`）各自带的 `net/httpd.c` 片段在 0.2.0 都并回了 `202`，理由和下面那段一样：它们改的是同一个我们自己新增的文件。剩下的按板差异全部退到 defconfig 与 defenv 里。

`206` / `310`（DRAM 容量探测）编号挨着但**与网页救砖无关**，是独立的 bug 修复，影响所有 an7581 / an7583 设备 —— 见[设备变体 → 内存容量](variants.md#内存容量)。分开放是为了以后单独提上游时不用再拆。它们现在会把整个推导过程打到 console，所以「诊断」的串口日志段看得到 —— 唯一的交集就是这个。

> **为什么只有一个 httpd 补丁**
>
> 开发时它是五个（骨架 → 上传 → DHCP 与面板灯 → 引导器 → 页面），合进主线时压成了一个。
>
> `patches/` 目录的语义是「**对上游源码的修改集**」，不是提交历史。`net/httpd.c` 是我们新增的文件，让它被五个补丁层层重写的代价是实打实的：构建时同一个文件反复 apply 五次、想知道最终形态得在脑子里叠四层 diff、上游同步时冲突面变成五份。而且没有哪一层是可以单独回退的 —— 你不会想只去掉「DHCP」或「页面」，它们本来就是一个功能。
>
> 对照同目录里合理的分法：`100`–`111` 是 backport，一个补丁对应上游一个 commit；`200` / `201` 是两件互不相干的事。**分开要有理由，「开发时是分步做的」不算理由。**
>
> 开发过程的原貌（五个补丁、21 个提交）留在 `archive/master-XG-040G-MD-httpd`。

### `951` 改了什么

```
check_buttons=if button reset ; then httpd ; fi              ← 原来是 run boot_tftp
boot_ubi=run boot_production ; run boot_httpd_forever        ← 原来是 boot_tftp_forever
boot_httpd_forever=while true ; do httpd ; sleep 1 ; done    ← 新增
_firstboot=... ; run check_buttons ; run ethaddr_factory ...  ← 开头插入按键检查
httpd_write_bl2=mtd erase bl2 && mtd write bl2 $loadaddr 0x800 $filesize
httpd_format_ubi=ubi detach ; mtd erase ubi && ubi part ubi
```

`httpd_write_bl2` 用 `mtd write` 的 offset 参数让 mtd 自己跳过前 `0x800` 字节（BootROM 在那里找 FIP），省掉官方脚本里 `mw.b $loadaddr 0xff 0x800` 那一步 —— 因为 part 是**就地刷写**的，不搬到 `$loadaddr`。

`httpd_format_ubi` 是去掉 `reset` 的 `ubi_format`，好让同一次会话接着写卷。

**TFTP 一条没删**：bootmenu 的第 2、4、5、6 项照旧，`boot_tftp*` 全套变量都在。自动路径走浏览器，手动路径留 TFTP。

### `952` 改了什么

菜单原来看不出这是哪来的固件 —— 和一份原厂 UBI 引导长得一模一样，进到菜单里的人也没有路径找回项目。

```
bootmenu_title=  \e[1;39mAiroha Web U-Boot 0.2.0\e[0m    ← 加了版本号，并去掉原来的三对括号
bootmenu_8=\e[31mStart web recovery server (http://192.168.1.1)\e[0m=httpd ; run bootmenu_confirm_return
bootmenu_9=About - github.com/Loong1996/ImmortalWrt-Airoha=run show_about ; run bootmenu_confirm_return
show_about=echo ; echo Web recovery U-Boot by Loong ; echo Guide: ... ; echo Project: ... ; echo Author: ... ; echo
```

`httpd_start_server()` 开头也照着打一遍，给看串口、不看网页的人：

```
Airoha Web U-Boot 0.2.0 by Loong
Project https://github.com/Loong1996/ImmortalWrt-Airoha
Guide   https://loong1996.github.io/ImmortalWrt-Airoha/recovery-guide.html
Using airoha-gdm1 device, MAC xx:xx:xx:xx:xx:xx
Listening for HTTP on 192.168.1.1 port 80
Handing out DHCP leases from 192.168.1.1
Press Ctrl-C to abort
```

**那行 MAC 是排障用的，不是装饰。** `net_check_prereq()` 只对 `BOOTP` / `DHCP` / `LINKLOCAL` 那一支校验 MAC，`HTTPD` 走的是 `FASTBOOT_*` / `TFTPSRV` 那一支，只检查 IP。所以出厂 MAC 丢了、`CONFIG_NET_RANDOM_ETHADDR` 顶上随机 MAC 的板子，一样会打印 `Listening for HTTP`，一样什么都不回 —— 浏览器还在按 ARP 缓存里的旧 MAC 发包。**「服务起来了但页面打不开」，先看这一行。**

几处需要知道的：

- **屏幕上显示 9 和 10，env 里是 `bootmenu_8` / `bootmenu_9`。** `cmd/bootmenu.c` 的快捷键是 `'1' + index`，下标 0 那项画成「1.」。
- **第 10 项画出来是「a.」不是「10.」。** 快捷键只有一个字符：1–9 之后接 a–z，0 留给 Exit。所以仓库地址写在标题里而不是藏在按键后面 —— 不按也要能看见，按下去才补上作者页。
- **标题去掉了原来的 `( ( ( ... ) ) )`。** 标题从第 3 列画起（`bootmenu_print_entry` 用 `ANSI_CURSOR_POSITION`），而 `_bootmenu_update_title` 会把完整的 `$ver`（72 字符）追加在后面。80 列下留给 `$ver` 的只有 36 列，版本号后半截连 commit hash 一起被截掉；去掉那三对括号腾出 12 列，r 号和 hash 就都能看全了（日期仍会截，无所谓）。末尾补了 `\e[0m`，免得 `_bootmenu_update_title` 没跑时后面的输出继承亮白。
- **第 9 项是红的**，和写引导器的那两项同色：它是刷机入口，且一旦进去，机器就离开菜单直到被中断。
- **版本号写了两遍**：`bootmenu_title` 里一份（`952`），`net/httpd.c` 的 `WEB_VERSION` 一份（`202`）。env 是纯文本，看不见 C 宏。改版本要同时动这两个补丁（MF 还有 `962`），并把 `envver` 加一 —— 网页侧栏那个 `0.2.0` 用的就是后者。

> **老机器升级引导器后看不到新菜单 —— `envver` 之后会自动处理。**
>
> `CONFIG_ENV_IS_IN_UBI`：`ubootenv` 卷里存的是**完整一份**环境，加载时整个盖掉编译进固件的默认值。已经初始化过 env 的机器换了新 FIP，菜单还是旧的 —— 新加的 `bootmenu_8` / `bootmenu_9` 根本不在它的环境里。
>
> `952` 加了自动刷新（见下一节 [`envver`](#envver-新-u-boot-自己刷新落后的菜单)），**从 `envver=1` 这版固件开始**升级引导器就不用手动做什么了。手动的办法留着备用：菜单选 `0. Exit` 进命令行，跑：
>
> ```
> env default -a -k
> saveenv
> reset
> ```
>
> `-k` 是 `H_NOCLEAR`：**不清空现有环境**，只把默认环境覆盖上去。默认环境里没有 `ethaddr` 这一行，所以 MAC 留得住 —— 这正是它比第 8 项 `Reset all settings to factory defaults` 好的地方，后者把 `ubootenv` 卷整个清零，`ethaddr` 跟着一起没。`env default` 也能把 saved env 里**根本不存在**的变量补进来（`env_set_default_vars()` 直接从 `default_environment` 导入），所以新增的 `bootmenu_8` / `bootmenu_9` 是能这样加进去的。
>
> 只想动某几个变量就点名：`env default -f bootmenu_title bootmenu_8 bootmenu_9`。
>
> 首次迁移过来的机器走 `_firstboot`，直接就是新的，不用管这一段。

### `envver`：新 U-Boot 自己刷新落后的菜单

默认环境里带一个 `envver`，`board/airoha/an7581/an7581_rfb.c` 里挂一个 `EVT_POST_PREBOOT` 钩子：saved env 的 `envver` 落后于编译进去的默认值，就把描述菜单的那几个变量重新导入一遍，然后 `saveenv`。

时机在 `preboot` 跑完之后、`bootdelay_process()` 和 `autoboot_command()` 画菜单之前 —— env 已加载，菜单还没画。

重新导入的**只有**这些：

```
envver  bootmenu_title  bootmenu_1..bootmenu_9  show_about
```

运行时状态刻意不在列表里：`bootdelay` / `bootmenu_delay`（`_switch_to_menu` 把 0 抬到 3，重置会让菜单闪现即超时）、`bootmenu_0`（初始化后被换成 `bootmenu_0d` 的内容）、还有 `ethaddr` —— 它压根不在默认环境里，`env_set_default_vars()` 的 import 碰不到它。**这就是它比 `env default -a -k` 温和的地方**，后者会把 59 个变量全推平。

> **为什么放在启动时，而不是刷 FIP 的时候**
>
> `env default` 导入的是**当前正在运行的**那个 U-Boot 编译进去的 `default_environment`。刷 FIP 时顺手刷新，装进 env 卷的是**旧版**的默认值 —— 菜单会永远落后固件一版。刚写进 flash 的新 FIP 还没运行，它的默认环境此刻根本不在内存里。**只有新 U-Boot 自己能做对这件事。**
>
> 顺带解释了菜单第 5 项 `boot_tftp_write_fip` 为什么刷完要 `run reset_factory`：清空 env 卷不是「导入旧默认值」，是让新 U-Boot 启动时发现 env 无效、回落到自己的默认环境。那条路是对的，代价是 `ethaddr` 跟着一起没。

改菜单时记得 `envver` 加一，否则老机器不会刷新。

> **刷新之后要自己把 `$ver` 补回标题。**
>
> 追加版本号的 `_bootmenu_update_title` 第一件事就是 `setenv _bootmenu_update_title` 把自己清空 —— 它只为「环境首次初始化」而存在。所以钩子重新导入 `bootmenu_title` 之后，saved env 里已经没有任何人能把版本号加回去，菜单会一直显示没有版本的标题。这是从 0.1.0 网页直接升上来的机器踩到的：菜单项全对，标题却光秃秃。
>
> 现在由钩子自己补。两条路不会重复追加：**环境被重建**时跑的是那个 env 脚本，而那种情况下 `envver` 恰好匹配、钩子不触发；**固件升级**时钩子触发，而脚本早已自删除。钩子放在共用的 an7581 board 文件里是安全的：别的板子默认环境里没有 `envver`，`env_get_default_into()` 返回负值就直接 return。`saveenv` 是尽力而为 —— 首次迁移会在 `_init_env` 建出 env 卷之前走到这里，而它本来就跑在默认环境上，不需要这次写入。

### 刷回原厂与写入偏移（`CMD_HTTPD_STOCK_RESTORE`）

回原厂原本是这个页面唯一去不了的方向 —— 要么用 tcboot 自带的 web 界面（迁走之后它就没了），要么串口加 TFTP 服务器，而后者正是这个页面存在的意义所在。

**为什么一个只有 `bl2` + `ubi` 布局的 U-Boot 能刷回原厂布局：** 分区表不在 flash 上，它来自设备树，跟着引导程序和内核一起走。把原厂字节写回原厂偏移，原厂的分区表也就跟着回来了。`mtd write` 对裸设备按字节偏移写，从不过问分区叫什么。

必须用裸设备也是同一个原因：`bl2` 到 `0x20000` 结束、`ubi` 从那里开始，**谁都够不到从偏移 0 起的整片写入**。裸设备不再写死 `spi-nand0`，是运行时取「不属于任何分区的那个 MTD」。

页面上是一个文件加一个「写入偏移」，默认 `0x0`：

| 偏移 | 效果 |
| --- | --- |
| `0x0` + 整片 `all_flash.bin` | 真正退回原厂，本页面随之消失 |
| 某个原厂分区的起始，如 `0xC0000` + 那个分区的备份 | 只写那一段 |

C 侧只查两件事，都在上传时查、查不过回 400：偏移按擦除块对齐，偏移加长度不超过容量。**不校验镜像内容，也不校验机型** —— MD 与 MF 的 `all_flash.bin` 长度相同、布局相同，页面分辨不出来，刷错机型之后只能靠串口。擦除长度按擦除块向上取整（`mtd erase` 拒绝非整数倍的长度），写入长度就是文件长度。

出厂数据 `ri` / `bosa` 不在这一页，在「写入 UBI 卷」页的「出厂数据」组：

> ### ⚠️ 单个出厂数据只能按 UBI 卷写，不能按原厂偏移裸写
>
> 原厂把 `ri` 放在物理偏移 `0x5200000`，而这套布局的 `ubi` 分区是 `0x20000`~`0x10000000` —— **那个偏移在 ubi 肚子里 80 MiB 处**。
>
> 往那儿 `mtd write`：
>
> 1. 会撕掉 UBI 每个 PEB 的 EC / VID header，连卷表一起毁掉；
> 2. **而且根本达不到目的** —— `ethaddr_factory` 执行的是 `ubi read 0x90000000 ri`，读的是**卷**，从来不是那个物理偏移。
>
> 两个 `ri` 只是同名：内容一样、长度一样、MAC 同样在 `+0x3e`，**容器不同**。所以恢复它要用 `ubi write $loadaddr ri 0x40000`。
>
> 同理，原厂那 13 个 mtd 分区在 ubi 布局下**无一例外落在 ubi 区内，没有一个能安全写**。「写入偏移」是给已经退回原厂布局、或者明知自己在干什么的人用的。

哪些卷算出厂数据、各多长，由 defconfig 里的 `CONFIG_HTTPD_FACTORY_VOLS="ri:0x40000 bosa:0x40000"` 说了算；`net/httpd.c` 里没有卷名。页面从 `/info` 拿到这个列表后才画出那两行，字段名是 `fvol_<卷名>`。长度必须正好相等，差一个字节都拒收 —— 这是 MAC 所在的卷。

「任意卷」那一组是 `ubi check <name> || ubi create <name> <文件长度> dynamic` 再 `ubi write`：卷在就在位写，不在就按文件长度建。这里故意不查长度 —— `ubi write` 自己会在动手前拒绝超出预留的写入，它知道真实数字而这里只能猜。

**`UPLOAD_MAX` 按 DRAM 实算。** 上传落在 `$loadaddr` 就地刷写，所以能放多大取决于它上面还剩多少内存：512M 的机器放下 235.6 MiB 后余量约 20 MiB。固定的 96 MiB 会直接拒收原厂镜像，而单纯把常数调大又会让更大的文件写出内存边界。

### `ri` 卷空了会读出一个广播 MAC

`ethaddr_factory` 从 `ri` 卷偏移 `0x3e` 读 6 字节当出厂 MAC。**勾过「先重建 UBI」的机器，`ri` 是 `ubi_create_board_data` 重新建的空卷**，读到的是擦除态 —— `ff:ff:ff:ff:ff:ff`。

它会被一路用下去，因为 `net/eth-uclass.c` 判断环境里的 MAC 时只调 `is_zero_ethaddr()`，不调 `is_valid_ethaddr()`：

```c
if (!is_zero_ethaddr(env_enetaddr)) {
        memcpy(pdata->enetaddr, env_enetaddr, ARP_HLEN);   /* 全 FF 从这里进来 */
} else if (is_valid_ethaddr(pdata->enetaddr)) {
} else if (... !is_valid_ethaddr(...)) {
        net_random_ethaddr(...);      /* 全 FF 走不到，所以没有随机 MAC 警告 */
}
```

于是广播地址被当成**源地址**发出去。症状很有迷惑性：DHCP 那行照常成功（DHCP 本来就是广播），单播回包被对端网卡丢掉，**网页打不开而串口一切正常**。

`952` 从两头堵：

- **`ethaddr_factory` 改成按读到的值判断** —— 读进临时变量 `_mac`，拿到可用的值才赋给 `ethaddr`；读到擦除态就什么都不动。
- **C 侧在 `EVT_SETTINGS_R` 兜底** —— saved env 里已经存着全 FF 的机器，`ethaddr_factory` 早就自删除了、这辈子不会再跑，只能在这里丢掉它，让 U-Boot 自己的随机 MAC 分支接手（会打印 `using random MAC address`）。

> **为什么不能用「`ethaddr` 已有值就不读 `ri`」这种写法**（我先写错过一版）
>
> `_firstboot` 是从 bootmenu 里跑的，**远在 `initr_net()` 之后**。一块没有 MAC 的板子到那时早就被 `eth-uclass` 生成了随机地址，并且由 `eth_env_set_enetaddr_by_index()` **写进了 env**。于是这个判断必然成立，`ri` 里的真地址在 `reset_factory` 之后**永远读不回来**。
>
> 按值判断则两件事一起做到了：`ri` 有真值就盖掉生成的随机地址，`ri` 是擦除态就不动 —— 后者同时保护了手工 `setenv` 进去的 MAC。

出厂 MAC 一旦随 `ri` 卷擦掉就找不回来了，机身标签是唯一的真值来源。

### `954`：日常更新引导器不再清配置

**症状**：从网页 0.1.0 升到 0.1.1，只传了 `preloader.bin` 和 `bl31-uboot.fip`、**没传固件**，
结果 OpenWrt 的设置全没了。固件（`fit` 卷）自始至终没被碰过 —— 消失的是 overlay。

**原因**：网页上「U-Boot」那一格当时借用了板子自己的 `ubi_write_fip`：

```
ubi_write_fip=run ubi_remove_rootfs ; ubi check fip && ubi remove fip ; \
              ubi create fip 0x100000 static && ubi write $loadaddr fip $filesize
```

`ubi_remove_rootfs` 删的 `rootfs_data`，正是 UBIFS 挂在 `fit` 里那个只读 squashfs 上面的
可写层，装着首次启动之后的每一处配置改动。下次开机 `ubi_prepare_rootfs` 发现它不在，
建一个空的顶上 —— 从 OpenWrt 那边看，和恢复出厂一模一样。

**`ubi_write_fip` 本身没有错，也没有被改。** 它是板子的原始脚本（`defenvs` 里的，比网页救砖
这个功能还早），给 bootmenu 第 4 项用，而那一项刷完紧跟着 `run reset_factory` —— 那是一次
**刻意的完整重置**，丢掉 `rootfs_data` 是它的本意。网页把同一个脚本拿去做一次例行的引导器
更新，是两件语义不同的事。**bug 在这次借用，不在被借的脚本。**

而且那对 remove/create 在这里本来就不承重：`fip` 每次都建在固定的 `0x100000`，对一个已经
存在的 `fip` 就地 `ubi write` 装得进它自己现有的预留，不需要先释放什么。删掉再按同样大小
建回来，净收益是零 —— `vmt.c` 里 `ubi_remove_volume()` 把 `reserved_pebs` 还给 `avail_pebs`，
`ubi_create_volume()` 紧接着又原样要回同样多。

所以拆出一条独立的 `httpd_write_fip`（和 `httpd_write_bl2` 挨着 `mtd_write_bl2` 是同一个套路），
将来改动 TFTP 菜单那条重置流程、或是网页这条例行更新流程，都不会悄悄改掉另一条的行为：

```
httpd_write_fip=if ubi check fip ; then ubi write $loadaddr fip $filesize ; else run ubi_write_fip ; fi
```

只有 `fip` **还不存在**时（首次迁移，那时 `rootfs_data` 同样还不存在）才需要建卷，
也只有那时驱逐 `rootfs_data` 是无害的 —— 那一支直接 `run ubi_write_fip` 复用原脚本，
不重复一遍建卷逻辑。走到那里时它自己的 `ubi check fip && ubi remove fip` 恰好是空操作。

> **新的 fip 比旧的小，就地写会不会留下旧数据的尾巴？** 不会。`ubi write` 不是「覆盖前 N
> 个字节」，是 UBI 的 volume update 语义 —— `drivers/mtd/ubi/upd.c` 的 `ubi_start_update()`
> 在写第一个字节之前，先把卷的 `reserved_pebs` 挨个 `ubi_eba_unmap_leb()`，注释写得很直白：
> `/* Before updating - wipe out the volume */`。整卷清空，旧内容一个字节都不剩。
>
> `fip` 是静态卷，收尾的 `clear_update_marker()` 会按新长度重算 `used_bytes` / `used_ebs` /
> `last_eb_bytes`，读的时候只读这么多。
>
> 反方向也有闸：新 fip 要是大过卷的预留，`cmd/ubi.c` 在动手之前就 `size > volume size!
> Aborting!` 退出，不会写一半坏在那儿。加上 `set_update_marker()` 先落盘、写完才清 ——
> 中途掉电下次挂载会认出这个卷无效，不会拿半个 fip 去引导。
>
> 参考量级：`fip` 卷预留 `0x100000`（1 MiB），实际的 `bl31-uboot.fip` 约 318 KiB，用掉 31%。

**BL2 从头到尾不涉及。** `httpd_write_bl2` 是朴素的 `mtd erase bl2 && mtd write bl2`，
操作的是 `bl2` 这个 mtd 分区（`0x0`~`0x20000`），完全在 `ubi` 分区（`0x20000` 往后）之外 ——
而 `rootfs_data` 和其它所有 UBI 卷都住在后者里。升级时连着 FIP 一起刷 BL2，对配置没有风险。

---

## 几个关键决定

### 用 U-Boot 自己的 TCP，不移植 uIP

tcboot 里嵌了 uIP 0.9（响应头 `Server: uIP/0.9`），因为它的基础 U-Boot 还没有 TCP 栈。现代 U-Boot 有 `net/tcp.c`，`net/fastboot_tcp.c` 就是现成的 TCP 服务器模板。

| | 移植 uIP | 用自带 TCP |
| --- | --- | --- |
| 新增代码 | ~4000 行 | ~130 行（202 的规模） |
| 与 tftpboot / dhcp 共存 | 要处理两套栈抢网卡 | 天然共存 |
| 上游可维护性 | 长期背一份 fork | 跟着上游走 |

### 零拷贝

`rx()` 回调给的是**流偏移**，所以可以直接 `memcpy` 到 `$loadaddr + offset`，几十 MB 的镜像不需要第二份内存。各个 part 也是**就地刷写**，不搬移 —— 只在刷之前按 64 字节向前对齐一下，踩到的是它自己的 multipart 头（最短也有 ~90 字节），碰不到前一个 part 的数据。

### 刷写逻辑留在 env 里，但不依赖它

每一步优先跑 env 脚本，找不到就用编译进二进制的等价命令。这不是冗余 —— 见下面的坑。

### 面板灯是刷写阶段唯一的通道

写入是同步阻塞的，`net_loop()` 的 timeout handler 那时已经停了。闪灯靠 cyclic 框架驱动：SPI-NAND 层每写一页调一次 `schedule()`（`drivers/mtd/nand/spi/core.c`），所以 64 MB 的写入过程中灯照样闪。

`CONFIG_CYCLIC_MAX_CPU_TIME_US` 默认 5000 μs，写 5 个 GPIO 够不着。万一超了会打印 `cyclic function httpd-flash took too long` 并注销回调 —— **灯停在某个状态，但刷写完全不受影响，别当成死机去断电。**

### 确认框每次都弹，但只拦真错的

按钮按下去先弹一个框：列出这次要传的文件名与大小，下面是这一页对应的提示 —— 会清 `rootfs_data`、会擦出厂 MAC、写完不重启要手动断电、整片写入之后本页面就没了。红色「仍要写入」才真的发。

拦死（按钮不出现）的只有页面自己能判定的硬错误：没选文件、卷名非法或缺一半、偏移不是十六进制、没按擦除块对齐、超出容量；0.3.0 起还有勾了重建 UBI 却没选 U-Boot、闪存里没 `fip` 卷却要做会重启的写入而没带 U-Boot、UBI 挂不上却要写卷（见[上面](#030拦截横幅体检日志)，这几条 C 侧也查）。**文件名与常规命名不符只提醒不拦** —— 文件名是可以被改的，而 `.itb` 进了 BL2 格的后果（写到 flash `0x800`，BootROM 认不出，只能串口 xmodem）确实值得一句提醒。

一页一个任务本身就消灭了原来一半的报错：「退回原厂不能和刷固件同时」「写入指定卷不能和其它写入同时」这类互斥不再需要说，因为表单结构上就做不到。

---

## 踩过的坑

### 1. `simple_strtoul()` 不跳前导空白

```
httpd: refusing 0 byte upload
```

`Content-Length: 12345` 从冒号后解析，U-Boot 的 `simple_strtoul()` 遇到空格直接返回 0（`lib/strto.c` 只处理 `0x` 前缀），和 libc 的行为不一样。

**这个坑差点被测试掩盖过去** —— 桩代码用的是 libc 的 `strtoul`，它会跳空白，所以本地全过、真机必挂。后来把桩改成忠实复现 U-Boot 的行为，才在本地复现出同一条错误信息。**桩要模仿被测环境的怪癖，不是模仿正确行为。**

### 2. 救砖工具不能依赖 flash 上的 env

```
## Error: "httpd_write_bl2" not defined
```

机器上一次测试时 `_firstboot` 建过 `ubootenv` 卷并 `saveenv`，那份旧 env 会盖掉 fip 里编译进去的默认值。**救砖工具依赖 flash 上的 env，而 flash 上的 env 恰恰是最可能过时或损坏的那份** —— 需要救砖的时候，正是它靠不住的时候。

现在每步都有内置兜底。

好在 BL2 是第一步，它一失败整个序列就中止，UBI 没被格式化、`fit` 卷完好 —— 「引导器先于固件」这个顺序在这里兜住了。

### 3. 分类要放在 `on_rcv_nxt_update()`，不能放 `rx()`

`rx()` 收到的第一个 TCP 段可能短于 4 字节，`memcmp(buf, "POST", 4)` 就越界了。`on_rcv_nxt_update()` 保证 `[0..rx_bytes-1]` 已经连续到齐。

这个是**测试抓出来的**，用 `chunk=1`（每次只喂 1 字节）跑的时候暴露。

### 4. defenv 的 patch context 要从 fork 里取

从 `openwrt/openwrt` 抄的 context 里 `bootfile*` 是 `openwrt-` 前缀，ImmortalWrt 是 `immortalwrt-` —— `Hunk #1 FAILED`，白等一个半小时。

**改哪棵树就从哪棵树取 context。**

### 5. 编译期宏的中文不要用 `\x` 转义

页脚一度显示 `U-Boot ç½é¡µæç `。生成补丁的脚本里我用了 `'\xe7\xbd\x91'` 写「网」，Python 把它当成三个 Latin-1 字符，写文件时又编了一遍 UTF-8：

```
应该是:  e7 bd 91           网
实际是:  c3 a7 c2 bd c2 91  ç½
```

现在源码里直接写中文，并加了一条检查：不许出现 `c3 a7 c2` 这类双重编码序列。

### 6. 验证判据本身也会错

给 `999` 测试补丁写验证方法时，我说「看串口有没有打印 `*** TEST BUILD ***`」。它永远不会出现 —— `bootcmd` 只有经 bootmenu 第 0 项才会被执行，而那个补丁把 `bootmenu_delay` 设成了 `-1`，菜单根本不往下走。正确判据是「停在菜单上」。

**一个编译要一个半小时，判据写错的代价和代码写错一样大。**

---

## 验证方式

每次改动都跑三层，真机编译一次约 1.5 小时，所以前两层要在本地过：

1. **页面** —— `files/httpd/test/` 里的 jsdom 用例，416 个，`cd files/httpd/test && npm install && npm test`（用例自己会先跑 `preview.py` 渲染，不会拿到过期的 HTML）。改动落在 httpd 目录时 CI 跟着跑，见 `.github/workflows/uboot-check.yml`（同一个 workflow 还会真把两块板的 U-Boot 交叉编出来）。覆盖：`/info` 填表与失败降级、每一页的确认框内容与拦截条件、实际提交的 `FormData` 字段集、多文件上传进度按累计长度定位、200 / 400 / 断网三种结局、「不重启」留页并靠心跳回报、备份下载的 URL 与越界拦截、环境变量的过滤与恢复默认、体检分组、心跳的两次失败判定与三种覆盖层、长时间静默只变点不弹框、整片下载是一个文件、传完报出 crc32 且多份往下排不覆盖、作者链接。跑的是真实的页面源文件，不是复制品
2. **编译** —— 整个补丁序列打到纯净的 U-Boot 2026.07 上，在 Docker 里（本机已有的 `ghcr.io/openwrt/buildbot/buildworker` 镜像加 `gcc-aarch64-linux-gnu`）对 MD、MF 两个 defconfig 各编一遍 `net/httpd.o` 与完整 `u-boot.bin`。0.1.x 只做语法级检查，漏过一次把 `flash_part()` 圈进 `#if` 的编译错误，这一层就是为它加的

   没有 Docker 的机器上还有一层兜底：`net/httpd.c` 从 `202` 里抽成真正的 `.c` 文件来改（`+` 行进出，行数由脚本重算，round-trip 逐字节比对过），再跑一个不需要编译器的静态检查 —— 去掉注释与字符串后的括号配对、`printf` 族的格式符与实参个数、有没有定义了没用到的 static 函数。先在改动前的版本上跑一遍当对照组。**这不能替代第 2 层**，它查不出 U-Boot API 的签名对不对
3. **补丁** —— 53 个补丁 `patch -p1` 顺序应用无 offset / fuzz（`120` / `121` 是 CRLF，macOS 的 patch 要先 `tr -d '\r'`，CI 的 GNU patch 自己处理）

刷之前从 fip 里解出 U-Boot 二进制核对一遍：

```bash
python3 - "$FIP" <<'EOF'
import sys, lzma
d = open(sys.argv[1], 'rb').read()
off = 0x10
while off + 40 <= len(d):
    uuid = d[off:off+16]
    o = int.from_bytes(d[off+16:off+24], 'little')
    sz = int.from_bytes(d[off+24:off+32], 'little')
    if uuid == b'\0' * 16:
        break
    blob = d[o:o+sz]
    if blob[:1] == b'\x5d':                       # FIP 第二段是 LZMA 压的 U-Boot
        open('uboot.bin', 'wb').write(
            lzma.LZMADecompressor(lzma.FORMAT_ALONE).decompress(blob))
    off += 40
EOF
strings -a uboot.bin | grep -E 'U-Boot 20'        # 版本串带源码 commit
strings -a uboot.bin | grep -E '^(check_buttons|boot_ubi|httpd_)'
```

版本串里嵌着源码的 commit sha，可以确认刷的到底是哪一版。中文要按 UTF-8 字节搜（`grep -a`），`strings` 只认 ASCII。

---

## 还没做的

* **刷写进度做不到。** 不是没做，是结构上不行：`net_loop()` 在写入开始前就返回，连接已关，页面轮询没人应答。要做就得把刷写拆进网络循环里分块跑 —— 那是把一条简单可靠的救砖路径换成一个状态机，对救砖场景不划算。
* **写入前的机型与魔数校验。** 现在「刷回原厂」那页明写着不校验镜像内容与机型。sysupgrade 的 `.itb` 里 FIT config 带 `compatible`，写之前和 `/info` 的 `model` 比一遍，能挡住「MD 的固件刷进 MF」这类砖 —— 比只认魔数（`0xd00dfeed` / `0xaa640001`）有用得多，两条一起做成本几乎一样。体检里读 FIT 描述那段代码正好可以复用。
* **写完回读校验。** 写完 `fip` / `fit` 卷后读回来算 crc32 和写前比。它回答的是「这次真的写进去了吗」，比写入前的任何校验都硬。
* **失败给一个独立灯语。** 现在流水＝等上传、齐闪＝正在写、熄灭＝完成，**写成功和写失败的灯是一样的**。心跳要页面还连得上才看得见，灯不需要 —— 两者互补。
* **LAN 1（2.5G 口）。** 要在 U-Boot 设备树里打开 `gdm4`、在 switch 的 mdio 上挂 `0x0f` 的 EN8811H、开 `PHY_AIROHA`，再把 144 KiB 的 MD32 固件放到 U-Boot 读得到的地方（比如一个 UBI 卷）由 env 脚本 `en8811h_load_firmware` 载入。整棵 U-Boot 树里只有 EVB 板用过 `gdm4`，没人在真机上验证过；收益只是多一个口，暂不做。
* **推上游。** `206` 是实打实的 bug 修复，值得提给 immortalwrt；httpd 这套是否适合上游还没想好。

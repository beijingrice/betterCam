# betterCam iOS 图像管线

本文描述 `codex/ios-color-grain` 分支当前的实现，包括 Codex 的修复、颗粒改用稀疏卷积噪点、内置 LUT 改按 sRGB 解释，以及之后对第 7 节问题的修复。

## 总览

```
                    ┌──────────────── 取景 ────────────────┐
AVCaptureDevice ──► VideoDataOutput (BGRA 8-bit)
                    ├─► MetalWHProcessor  波形 / 直方图（套风格之前的画面）
                    └─► prepareSDR ─► 前置镜像 ─► CameraPreviewFrames
                                                     │
                                         MTKView 每次刷新：转向 ─► 缩放到屏幕
                                         ─► FilmEngine.process ─► Display P3 屏幕

                    ┌──────────────── 拍摄 ────────────────┐
takePhoto ─► PhotoCaptureRequest（画质、分辨率、风格快照、曝光）
          ─► makePhotoSettings ─► AVCapturePhotoOutput
             ├─ 处理后照片 (HEVC) ─► CIImage ───────────────┐
             └─ RAW
                ├─ 保存 DNG / ProRAW 原始文件               │
                └─ ZERO PROCESSING：CIRAWFilter 显影 ───────┤
                                                            ▼
                       prepareSDR ─► FilmEngine.process ─► P3 8-bit ─► JPEG ─► 照片图库
```

取景和成片用的是**同一个 `FilmEngine.process`**，区别只有输入图像、分辨率和颗粒种子。

---

## 1. 取景

代码：`SessionManager.captureOutput`、`Views/MetalCameraPreview.swift`

1. **相机输出。** session 预设为 `.photo`，`AVCaptureVideoDataOutput` 输出 8-bit BGRA，来不及处理的帧直接丢弃。
2. **曝光指示。** 每一帧先交给 `MetalWHProcessor`，按限定的帧率算出 128×64 的波形图或直方图。它测量的是**套风格之前**的画面。
   - **手动曝光测光（多区评价测光）。** 快门和 ISO 都手动时，`ExposureMeter` 每秒约 15 次读取这一帧：
     - 画面分成 12×9 个区，每区取 8×8 个点算平均线性亮度，换成相对中灰 0.18 的档数。
     - 每区有轻微的中央偏重（中心 1.0，角落约 0.6），不是中央重点的热点。
     - 以加权中位数作为场景的基准亮度；离基准超过 1.5 档的区（灯、天空、黑色前景）权重减半，并且最多只能偏离基准 ±2 档。
     - 读数是各区档数的加权平均，相当于对数平均，接近人眼对亮度的感受。
     - 以前用的 `exposureTargetOffset` 对比的是苹果自动曝光的目标，在暗场景和大光比场景里会偏暗约 2 档。
3. **准备底图。** 如果画面带 HDR headroom，先用 `CIToneMapHeadroom` 压到 SDR；8-bit 视频流一般没有 headroom，这一步通常什么都不做。前置镜头会做 `downMirrored` 镜像。
4. **交给预览。** 最新一帧、是否镜像和当前风格设置一起存进 `CameraPreviewFrames`（加锁），每次更新都会递增版本号。
5. **绘制。** `MTKView` 只在版本号、屏幕方向、镜头切换状态或尺寸变化时才重画：
   - 按界面方向转正，等比缩放到屏幕的像素尺寸（`highQualityDownsample`），居中放置。
   - 调用 `FilmEngine.process`。颗粒按屏幕分辨率计算，**只在调风格的手势进行时显示颗粒**，松手后保留 1 秒再用 0.4 秒淡出；平时取景只显示风格化的颜色。显示时用固定的图案，不随帧闪动。颗粒在取景器里只有 2–3 个像素大，所以每个像素取它覆盖范围内的颗粒平均（2×2 采样），效果等于 48MP 成片缩小到屏幕上看的样子，而不是一粒粒硬的沙点。
   - 切换镜头时加 30pt 高斯模糊，最后叠在黑底上。
   - 用 `CIRenderDestination` 渲染到 `bgra8Unorm` 的 Display P3 drawable；最多同时有 2 帧在 GPU 上排队。
6. **什么时候套风格。** 只有画质会保存 JPEG（`JPEG` 或 `DNG+J`）时才套风格和颗粒；`DNG` 和 `ProRAW` 模式下取景器显示原始视频画面。
7. **视频 HDR。** 只有同时满足三个条件才打开：自动曝光、ZERO PROCESSING 关闭、画质会保存 JPEG。
8. **手势。** 左右拖动调风格强度（`lutIntensity`），上下拖动调颗粒强度（`grainIntensity`）。选 STD 或 MANAGE、或者画质不保存 JPEG 时，手势不生效。点击对焦根据预览帧的尺寸和镜像状态换算坐标。

---

## 2. 拍摄

代码：`Camera.takePhoto`、`SessionManager.makePhotoSettings / capturePhoto`

### 2.1 Request

按下快门时，把当前画质、分辨率、是否前置、ZERO PROCESSING、风格设置（`FilmRenderSettings`：风格、强度、颗粒）和手动曝光参数打包成 `PhotoCaptureRequest`。之后再改设置，不影响已经按下的这张。

- 同时在处理的照片数：48MP 最多 1 张，其他最多 3 张。
- 手动曝光：先设好自定义快门和 ISO，等设备确认生效后再拍。
- 照片方向取自陀螺仪（`motionManager.deviceOrientation`）；前置镜头的照片会镜像。

### 2.2 画质模式

| 画质 | ZERO PROCESSING | 相机交付 | 保存到图库 | 套风格 |
|---|---|---|---|---|
| JPEG | 关 | 处理后照片（HEVC，质量 1.0） | 风格 JPEG | ✅ |
| JPEG | 开 | Bayer RAW | 由 RAW 显影的风格 JPEG | ✅ |
| DNG+J | 关 | Bayer RAW 和处理后照片（HEVC） | 一个 RAW+JPEG 图库项（JPEG 为主，DNG 为替代原片）；照片 App 拒收时自动分开存两份 | 只有 JPEG |
| DNG+J | 开 | Bayer RAW | DNG 和由 RAW 显影的风格 JPEG | 只有 JPEG |
| DNG | 任意 | Bayer RAW | DNG | ❌ |
| ProRAW | 关 | Apple ProRAW | ProRAW DNG | ❌ |

打开 ZERO PROCESSING 时，如果画质是 ProRAW，会自动切到 DNG+J，因为 ProRAW 本身已经包含 Apple 的计算摄影处理。

### 2.3 分辨率与处理优先级

- **48MP：** 只在画质为 JPEG 或 ProRAW、并且 ZERO PROCESSING 关闭时可用。选 48MP 会自动关掉 ZERO PROCESSING，画质不对时也会自动切回 JPEG。
- **RAW 类模式：** DNG、DNG+J、ZERO PROCESSING 和普通 ProRAW 都用传感器的原生 binning 尺寸。
- **普通 JPEG：** 优先用 24MP，设备不支持时用原生尺寸。
- **预先准备：** 画质、分辨率、ZERO PROCESSING 或手动曝光变化后（150ms 防抖），按下一张会用的设置调用 `setPreparedPhotoSettingsArray`，切换镜头后重新准备。以前只有 48MP 才准备，其他模式第一张要现场分配缓冲区，取景会卡一下，Bayer RAW 最明显。启动时还会在处理队列上用一张小图把成片的 Core Image 流程和 JPEG 编码器跑一遍。
- **处理优先级：** 手动曝光或 Bayer RAW 用 `.speed`（Apple 要求这样才会采用自定义曝光）；其他情况（自动曝光下的 JPEG，任何分辨率，以及 ProRAW）都用 `.quality`，可以用上多帧合成。连拍数量由在途照片上限控制。

---

## 3. 成片处理

代码：`SessionManager.processRawPhoto / processProcessedPhoto / renderFilteredJPEG`

所有成片都在一个**串行**队列里处理，避免多张 48MP 同时占用内存。

1. **得到底图。**
   - 处理后照片：`CIImage(data:)` 解码相机交付的 HEVC。HEVC 只是中间格式，所以要的是质量 1.0（接近无损），真正有损的只有最后一次 JPEG 编码。像素保持传感器方向，靠方向标签转正。
   - ZERO PROCESSING：`CIRAWFilter` 输出的像素已经转正，所以写 JPEG 时方向标签改成 1。
   - ZERO PROCESSING 亮度同步：按快门时记下取景画面的多区测光读数（取景器一直在后台每秒约 15 次测量，不管测光显示是否打开）。显影前先用约 384px 的草稿显影测同样的读数，调 `CIRAWFilter.exposure` 让两者一致（校正两次，范围 −2…+3 EV）。只同步整体亮度；降噪、锐化和局部色调映射仍然不加。
   - ZERO PROCESSING：`CIRAWFilter` 显影 Bayer RAW，并设置 `extendedDynamicRangeAmount = 0`，让 RAW 显影器自己把高光压进 SDR。
2. **压到 SDR。** 如果底图带 HDR headroom，先 tone map 到 SDR。
3. **套风格和颗粒。** 调用 `FilmEngine.process`。颗粒种子由 captureID 算出，所以每张照片的颗粒图案都不一样。
4. **输出。** 在扩展线性 sRGB 工作空间里计算，导出成 RGBA8 Display P3 的 `CGImage`。风格本身在 sRGB 里制作，但没套风格或强度不满的部分保留相机的广色域。
5. **写 JPEG。** 用 `CGImageDestination` 编码，质量 0.95。沿用相机的元数据，删掉 ICC 配置名（由 CGImage 嵌入 P3 配置文件），EXIF 色彩空间写成 0xFFFF（Uncalibrated，与 iPhone 相机的 P3 照片一致）。
6. **保存。** RAW+JPEG 按 Apple 示例的做法，DNG 先写成临时 `.dng` 文件再加为 `.alternatePhoto`；如果照片 App 拒收这一组，会把 JPEG 和 DNG 分开各存一份并打印错误，不会丢照片。一次拍摄的文件先存在这次拍摄的上下文里，等所有处理都结束后一起写入：有 JPEG 和 RAW 时存成一个资源（JPEG 为 `.photo`，DNG 为 `.alternatePhoto`），图库显示为 RAW+JPEG；只有一种时就存那一种。

---

## 4. FilmEngine：色彩与颗粒

代码：`Stylize/FilmEngine.swift`、`Stylize/FilmLUT.swift`、`Metal/FilmGrain.metal`

```
输入 ─► [风格] ─► [按强度和原图混合] ─► [颗粒] ─► 输出
```

### 4.1 风格设置

`FilmRenderSettings` 在以下情况为空，图像原样通过：选 STD、选 MANAGE、风格没有色彩效果，或者画质不保存 JPEG。强度会限制在 0–1 之间。

### 4.2 风格

- **CIPhotoEffect：** CHROME、INSTANT、FADE、PROCESS、TRANSFER、MONO、NOIR、TONAL。
- **3D LUT**（`FilmLUT.apply`）：
  1. 如果 LUT 按 sRGB 制作，先用 `CILinearToSRGBToneCurve` 把线性值编码成 sRGB。
  2. 如果文件写了 `DOMAIN_MIN/MAX` 或 `LUT_3D_INPUT_RANGE`，用颜色矩阵把输入映射到 0–1。
  3. 用 `CIColorCube` 查表。
  4. 如果按 sRGB 制作，再用 `CISRGBToneCurveToLinear` 解码回线性。

### 4.3 强度混合

强度为 1 时直接用风格结果；小于 1 时用 `CIBlendWithAlphaMask` 和一张纯透明度的遮罩，与原图按比例混合。

### 4.4 颗粒

只有颗粒强度大于 0、并且这个风格配置了颗粒参数时才加。

- **颗粒尺寸：** 图像短边 × 每款胶片的 `size`，单位是像素；所以取景器和成片在同样的观看尺寸下，颗粒看起来一样大。
- **强度：** 胶片的 `amplitude` × 滑杆值，线性变化。
- **图案位置：** 由种子算出一个偏移量（成片每张不同，取景器每帧不同）。

Metal kernel `betterCamGrain` 对每个像素的处理：

1. 转成 sRGB 编码值，计算亮度。
2. **按亮度加权：** `smoothstep(0, 0.26, 亮度) × (1 − smoothstep(0.45, 1, 亮度))`。中间调和偏暗部最强，纯黑和纯白减到 0。
3. **亮度噪点：** 稀疏卷积噪点。每个格子随机放一颗颗粒，位置和明暗都随机，每颗画成半径为一格的柔和圆点 `(1−r²)²`，统计上处处一样强，不会出现格子纹。
4. **彩色噪点：** 如果 `chroma > 0`，在 R、B 通道再叠两组独立的噪点，并减去它们的亮度成分，只留下色彩变化。
5. **保色相、防截断：** 三个通道按同一个比例放大或缩小，所以颗粒只改变明暗，不改变色相，高饱和颜色上也一样。摆动幅度是对称的，并且限制在任何通道都不会越过 0 或 1 的范围内，截断不会让平均值偏移。有通道已经超过 1 的像素不加颗粒。对中性灰来说，结果和以前逐通道相加完全一样。
6. 解码回线性。

颗粒参数：

| 风格 | size（相对短边） | amplitude | chroma |
|---|---|---|---|
| 彩色 CIPhotoEffect | 0.0008 | 0.10 | 0 |
| 黑白 CIPhotoEffect | 0.00095 | 0.13 | 0 |
| FUJICOLOR_400 | 0.00105 | 0.13 | 0.035 |
| FUJICOLOR_C200 | 0.00078 | 0.10 | 0.03 |
| KODAK_GOLD_200 | 0.00075 | 0.10 | 0.025 |
| KODAK_VISION3_250D_5207 | 0.00065 | 0.085 | 0.02 |
| 导入的 LUT | 0.00078 | 0.10 | 0 |

一颗颗粒约占两格，0.0008 大约是短边上 600 颗，接近 35mm 胶片。48MP 成片短边约 6048 px，Fujicolor 400 每格约 6 px；12MP 短边 3024 px，Vision3 每格约 2 px，会启用按像素平均。以前的颗粒是现在的两倍多大，看起来粗糙发脏。

---

## 5. 色彩空间

| 环节 | 色彩空间 |
|---|---|
| Core Image 工作空间（取景和成片） | 扩展线性 sRGB |
| 内置 LUT、按 sRGB 导入的 LUT | 查表时用 sRGB 编码值 |
| 按线性导入的 LUT、旧版导入的 LUT | 查表时用线性值 |
| 颗粒的计算 | sRGB 编码值 |
| 取景器 drawable | Display P3，8-bit |
| JPEG 成片 | Display P3，8-bit，嵌入 ICC，EXIF ColorSpace = 0xFFFF |

---

## 6. 风格库

- **顺序：** STD → 8 个 CIPhotoEffect → 4 个内置 LUT → 用户导入的 LUT → MANAGE（进入 LUT 管理）。
- **内置 LUT：** 随 App 打包的 `.cube` 文件，33³，按 sRGB 解释。
- **导入：** 支持 3D `.cube`，会读取 `DOMAIN_MIN/MAX` 或 `LUT_3D_INPUT_RANGE`，拒绝 1D LUT。导入时选择 sRGB 或线性，导入后也能改。数据存成 `Documents/<文件名>.lutdata`，索引存在 UserDefaults 的 `UserSavedLUTs` 里，包含名称、文件名和色彩空间。
- **管理：** 同名导入会提示；重命名不改文件名；删除会同时删掉文件；旧版留下的重复索引只加载一份。

---

## 7. 已知限制与待确认

**已修复（需要真机确认）：**
- **ZERO PROCESSING 成片被旋转两次。** `CIRAWFilter` 输出已转正的像素，现在写 JPEG 时方向标签改成 1。真机上横拍、竖拍各一张确认。
- **广色域被裁掉。** 取景器和 JPEG 改成 Display P3。
- **两次有损压缩。** 中间 HEVC 改为质量 1.0，JPEG 质量设为 0.95。没有改成无压缩像素格式，因为无法在模拟器上确认 48MP 是否接受无压缩格式，设置不被接受时 AVFoundation 会直接崩溃。
- **普通 JPEG 用 `.speed`。** 自动曝光下的 JPEG 现在都用 `.quality`。快门间隔可能变长，需要在真机上感受连拍。
- **DNG+J 存成两个图库项。** 现在合成一个 RAW+JPEG 资源。
- **取景器颗粒静止。** 改为每帧刷新。
- **取景器颗粒像沙子。** 改为按像素覆盖范围平均颗粒（颗粒小于约 7 像素时启用，成片的 48MP 颗粒不受影响）。
- **手动曝光测光偏暗约 2 EV。** 改为自己的多区评价测光，读的是取景画面本身。
- **取景时颗粒干扰构图。** 颗粒只在调整手势时显示，图案固定不闪。
- **颗粒太粗、显脏。** 颗粒尺寸缩小到约 45%，强度降低约 15%，彩色噪点减半。
- **DNG+J 什么都没写入。** 改为 DNG 用临时文件加入，失败时分开保存。
- **拍第一张会卡。** 所有模式都预先准备拍摄设置，并预热成片处理。ZERO PROCESSING 的 `CIRAWFilter` 无法预热（需要真实 RAW 数据），第一张可能仍比后面慢一点。
- **高饱和颜色上的颗粒色偏。** kernel 改为三通道同比例缩放。
- **颗粒 kernel 加载失败没有日志。** 现在记录 fault 日志，Debug 版本会断言；新增测试检查 kernel 能加载。

**有意保留的设计：**
- **ZERO PROCESSING 的取景器和成片仍有局部差异。** 整体亮度已经自动同步，但取景器是 ISP 的渲染，有局部色调映射（暗部被局部提亮）；成片没有这一层，所以大光比场景里暗部仍会比取景器暗一些、对比更高，锐度和噪点也不同。
- **波形图和直方图测量套风格之前的画面。** 它们当作场景测光工具用，反映传感器拿到的曝光，不受 LUT 影响。

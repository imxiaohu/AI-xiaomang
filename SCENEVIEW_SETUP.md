# SceneViewSwift iOS 配置指南

## 为什么需要这一步

`sceneview` Flutter 插件的 iOS 端依赖 `SceneViewSwift`（RealityKit 渲染器），
CocoaPods 不支持 SPM 依赖声明，因此需要**手动在 Xcode 中添加 SPM 包**。

## 快速配置（Xcode GUI）

1. **打开项目**
   ```bash
   cd ios
   open Runner.xcworkspace
   ```

2. **添加 SPM 包**
   - 左侧导航器选中项目根节点 `Runner`
   - 菜单 `File → Add Package Dependencies...`
   - 搜索框粘贴：
     ```
     https://github.com/sceneview/SceneViewSwift
     ```
   - 版本选择 **3.6.0**
   - Add to: **Runner**
   - 点击 **Add Package**

3. **验证**
   - 项目中应出现 `Package Dependencies` 分组
   - `SceneViewSwift` 应在列表中

## 或使用脚本提示

```bash
cd ios
chmod +x setup_sceneview_spm.sh
./setup_sceneview_spm.sh
```

## 构建验证

```bash
cd ..
flutter build ios --simulator --no-codesign
```

## 常见问题

### 编译报错 `SceneViewSwift not found`
确保 Xcode 正确拉取了 SPM 包：
- `Product → Clean Build Folder` (⇧⌘K)
- `Product → Build` (⌘B)

### 真机调试需要签名
Runner → Signing & Capabilities → Team 设置你的 Apple ID

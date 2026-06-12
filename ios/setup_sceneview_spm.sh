#!/bin/bash
# ============================================================
# SceneViewSwift SPM 配置脚本
# ============================================================
# 用途：将 SceneViewSwift Swift Package 添加到 iOS Xcode 项目
#
# 前置条件：
#   1. Xcode 项目已打开（通过 open ios/Runner.xcworkspace）
#   2. 已完成 flutter pub get（安装 sceneview 包）
#
# 使用方法：
#   cd AIVideo/ios
#   ./setup_sceneview_spm.sh
# ============================================================

set -e

XCODEPROJ="Runner.xcodeproj"
PACKAGE_URL="https://github.com/sceneview/SceneViewSwift"
PACKAGE_VERSION="3.6.0"
TARGET_NAME="Runner"

echo "[SceneViewSwift] 开始配置..."

# 检查 xcodeproj 是否存在
if [ ! -d "$XCODEPROJ" ]; then
    echo "[ERROR] 未找到 $XCODEPROJ，请确保在 ios 目录下运行"
    exit 1
fi

# 检查是否已配置（Package.resolved 中是否包含 SceneViewSwift）
if [ -f "$XCODEPROJ/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" ]; then
    if grep -q "SceneViewSwift" "$XCODEPROJ/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" 2>/dev/null; then
        echo "[OK] SceneViewSwift 已配置，跳过"
        exit 0
    fi
fi

echo "[INFO] 请在 Xcode 中手动添加 SceneViewSwift 包："
echo ""
echo "  1. 打开 ios/Runner.xcworkspace（不是 .xcodeproj）"
echo ""
echo "  2. 在左侧项目导航器中，选中 Runner 项目根节点"
echo ""
echo "  3. 菜单：File → Add Package Dependencies..."
echo ""
echo "  4. 在弹出的搜索框中输入："
echo "     $PACKAGE_URL"
echo ""
echo "  5. 选择 'SceneViewSwift'，版本选择 '$PACKAGE_VERSION'"
echo ""
echo "  6. Add to: 'Runner'"
echo ""
echo "  7. 点击 Add Package"
echo ""
echo "=========================================="
echo "或者使用命令行添加："
echo "xcodebuild -resolvePackageDependencies -project $XCODEPROJ -clonedSourcePackagesDirPath ./SourcePackages"
echo ""
echo "SceneViewSwift GitHub: https://github.com/sceneview/SceneViewSwift"

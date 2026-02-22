#!/bin/bash
set -euo pipefail

# =============================================================================
# chaos-status.sh — ネットワーク障害シミュレーションの状態確認
#
# 現在適用されている pf ルールと dnctl パイプの状態を表示する。
#
# 使い方:
#   sudo bash chaos-status.sh
# =============================================================================

CHAOS_STATE_FILE="/tmp/chaos-state.conf"

# root 権限チェック
if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] このスクリプトは sudo で実行してください: sudo bash $0" >&2
  exit 1
fi

echo "=========================================="
echo " Network Chaos — STATUS"
echo "=========================================="
echo ""

# 状態ファイルの確認
if [ -f "$CHAOS_STATE_FILE" ]; then
  echo "[状態ファイル] $CHAOS_STATE_FILE が存在します — 障害ルールが適用中の可能性があります"
  echo ""
else
  echo "[状態ファイル] $CHAOS_STATE_FILE が見つかりません — 障害ルールは未適用の可能性があります"
  echo ""
fi

# pfctl の状態
echo "--- pfctl の状態 ---"
pfctl -si 2>/dev/null | head -5 || echo "  pfctl の状態を取得できません"
echo ""

# 現在の pf ルール（dummynet ルールのみフィルタ）
echo "--- dummynet 関連の pf ルール ---"
dummynet_rules=$(pfctl -sr 2>/dev/null | grep "dummynet" || true)
if [ -n "$dummynet_rules" ]; then
  echo "$dummynet_rules"
else
  echo "  dummynet ルールはありません"
fi
echo ""

# dnctl パイプの状態
echo "--- dnctl パイプ一覧 ---"
pipe_list=$(dnctl list 2>/dev/null || true)
if [ -n "$pipe_list" ]; then
  echo "$pipe_list"
else
  echo "  アクティブなパイプはありません"
fi
echo ""

echo "=========================================="
echo ""

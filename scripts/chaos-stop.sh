#!/bin/bash
set -euo pipefail

# =============================================================================
# chaos-stop.sh — ネットワーク障害シミュレーション停止
#
# chaos-start.sh で適用したルールをすべて解除し、元の状態に戻す。
#
# 使い方:
#   sudo bash chaos-stop.sh
#
# 動作:
#   1. chaos-start.sh が記録した状態ファイルからパイプ番号を読み取る
#   2. pf ルールをバックアップから復元する
#   3. dnctl パイプを削除する
#   4. 一時ファイルをクリーンアップする
# =============================================================================

PF_BACKUP_FILE="/tmp/chaos-pf-backup.conf"
CHAOS_STATE_FILE="/tmp/chaos-state.conf"

info() {
  echo "[INFO] $1"
}

warn() {
  echo "[WARN] $1"
}

# root 権限チェック
if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] このスクリプトは sudo で実行してください: sudo bash $0" >&2
  exit 1
fi

echo "=========================================="
echo " Network Chaos — STOP"
echo "=========================================="
echo ""

# 状態ファイルからパイプ番号を読み取る
# source ではなく grep で必要な値だけ安全に抽出する（SC1091 対策）
PIPE_NUMBERS=""
if [ -f "$CHAOS_STATE_FILE" ]; then
  PIPE_NUMBERS=$(grep '^PIPE_NUMBERS=' "$CHAOS_STATE_FILE" | head -1 | sed 's/^PIPE_NUMBERS="//' | sed 's/"$//')
  info "状態ファイルを読み込みました"
else
  warn "状態ファイルが見つかりません: $CHAOS_STATE_FILE"
  warn "dnctl list から手動でパイプを検出します"
  PIPE_NUMBERS=$(dnctl list 2>/dev/null | grep -oE '^[0-9]+' | tr '\n' ' ' || true)
fi

# pf ルールを復元
info "pf ルールを復元しています..."
if [ -f "$PF_BACKUP_FILE" ]; then
  pfctl -f "$PF_BACKUP_FILE" 2>/dev/null
  info "バックアップからルールを復元しました"
else
  # バックアップがなければシステムデフォルトに戻す
  if [ -f /etc/pf.conf ]; then
    pfctl -f /etc/pf.conf 2>/dev/null
    info "システムデフォルト (/etc/pf.conf) に復元しました"
  else
    warn "復元元のルールファイルが見つかりません"
  fi
fi

# dnctl パイプを削除
if [ -n "$PIPE_NUMBERS" ]; then
  info "dnctl パイプを削除しています..."
  # shellcheck disable=SC2086 — PIPE_NUMBERS はスペース区切りのパイプ番号リスト
  for pipe in $PIPE_NUMBERS; do
    if dnctl pipe "$pipe" list >/dev/null 2>&1; then
      dnctl pipe "$pipe" delete
      info "  パイプ $pipe を削除しました"
    fi
  done
else
  info "削除するパイプはありません"
fi

# 一時ファイルをクリーンアップ
info "一時ファイルをクリーンアップしています..."
for f in /tmp/chaos-pf-rules.conf "$PF_BACKUP_FILE" "$CHAOS_STATE_FILE"; do
  if [ -f "$f" ]; then
    rm "$f"
    info "  $f を削除しました"
  fi
done

echo ""
echo "=========================================="
echo " Network Chaos が解除されました"
echo "=========================================="
echo ""
echo "すべてのルールとパイプが削除され、"
echo "ネットワークは通常動作に戻っています。"
echo ""

#!/bin/bash
set -euo pipefail

# =============================================================================
# chaos-start.sh — ネットワーク障害シミュレーション開始
#
# macOS の pfctl/dnctl を使って、指定した IP:ポートへの通信に
# ランダムなパケットドロップを注入する。
#
# 使い方:
#   sudo bash chaos-start.sh <config.yaml>
#
# 設定ファイル (YAML) の形式:
#   scenarios:
#     - name: "..."
#       target:
#         ip: "192.168.1.100"
#         port: 8080
#         protocol: tcp        # tcp | udp | both (デフォルト: tcp)
#         direction: out       # in | out | both (デフォルト: out)
#       chaos:
#         packet_loss: 30      # パケットロス率 (%) 0〜100
#         duration: 0          # 秒。0 = 手動停止
#
# 注意:
#   - macOS 専用 (pfctl/dnctl)
#   - sudo 権限が必要
#   - 本番環境では使わないこと
#   - 終了時は必ず chaos-stop.sh を実行すること
# =============================================================================

CONFIG_FILE="${1:-}"
PIPE_BASE=100
PIPE_STEP=100
PF_RULES_FILE="/tmp/chaos-pf-rules.conf"
PF_BACKUP_FILE="/tmp/chaos-pf-backup.conf"
CHAOS_STATE_FILE="/tmp/chaos-state.conf"

# --- ヘルパー関数 ---

usage() {
  echo "使い方: sudo bash $0 <config.yaml>"
  echo ""
  echo "  config.yaml  障害シナリオの設定ファイル"
  exit 1
}

error() {
  echo "[ERROR] $1" >&2
  exit 1
}

info() {
  echo "[INFO] $1"
}

# --- YAML 簡易パーサー ---
# この設定ファイルの構造は固定的なので、grep/sed/awk で十分パースできる。
# scenarios 配列の各要素を「- name:」で区切ってブロックごとに処理する。

parse_scenarios() {
  local config="$1"

  # 設定ファイルからコメント行と空行を除去
  local cleaned
  cleaned=$(sed 's/#.*$//' "$config" | sed '/^[[:space:]]*$/d')

  # シナリオの数をカウント（「- name:」の出現回数）
  SCENARIO_COUNT=$(echo "$cleaned" | grep -c '^\s*-\s*name:' || true)

  if [ "$SCENARIO_COUNT" -eq 0 ]; then
    error "設定ファイルにシナリオが見つかりません"
  fi

  # 各シナリオのフィールドを抽出
  # awk で「- name:」をデリミタにしてブロック分割
  local block_index=0

  # 一時的にシナリオブロックを分割して処理
  local current_block=""

  while IFS= read -r line; do
    if echo "$line" | grep -q '^\s*-\s*name:'; then
      # 前のブロックがあれば処理
      if [ -n "$current_block" ]; then
        _extract_scenario "$block_index" "$current_block"
        block_index=$((block_index + 1))
      fi
      current_block="$line"
    elif [ -n "$current_block" ]; then
      current_block="$current_block
$line"
    fi
  done <<< "$cleaned"

  # 最後のブロックを処理
  if [ -n "$current_block" ]; then
    _extract_scenario "$block_index" "$current_block"
  fi
}

_extract_field() {
  local block="$1"
  local field="$2"
  local default="${3:-}"
  local keep_spaces="${4:-false}"

  local value
  value=$(echo "$block" | grep "${field}:" | head -1 | sed "s/.*${field}:[[:space:]]*//" | sed 's/^["'"'"']//' | sed 's/["'"'"']$//')

  # 前後の空白を除去（フィールド内のスペースは保持）
  value=$(echo "$value" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

  # keep_spaces=false の場合は全スペースも除去（IP, port などの値用）
  if [ "$keep_spaces" = "false" ]; then
    value=$(echo "$value" | tr -d '[:space:]')
  fi

  if [ -z "$value" ]; then
    echo "$default"
  else
    echo "$value"
  fi
}

_add_pf_rule() {
  local dir="$1"
  local proto="$2"
  local target_ip="$3"
  local target_port="$4"
  local pipe="$5"

  if [ "$dir" = "out" ]; then
    echo "dummynet out proto $proto from any to $target_ip port $target_port pipe $pipe" >> "$PF_RULES_FILE"
  elif [ "$dir" = "in" ]; then
    echo "dummynet in proto $proto from $target_ip port $target_port to any pipe $pipe" >> "$PF_RULES_FILE"
  fi
}

_extract_scenario() {
  local index="$1"
  local block="$2"

  SCENARIO_NAME[$index]=$(_extract_field "$block" "name" "scenario-$index" true)
  SCENARIO_IP[$index]=$(_extract_field "$block" "ip" "")
  SCENARIO_PORT[$index]=$(_extract_field "$block" "port" "")
  SCENARIO_PROTOCOL[$index]=$(_extract_field "$block" "protocol" "tcp")
  SCENARIO_DIRECTION[$index]=$(_extract_field "$block" "direction" "out")
  SCENARIO_LOSS[$index]=$(_extract_field "$block" "packet_loss" "0")
  SCENARIO_DURATION[$index]=$(_extract_field "$block" "duration" "0")

  # バリデーション
  if [ -z "${SCENARIO_IP[$index]}" ]; then
    error "シナリオ ${SCENARIO_NAME[$index]}: ip が指定されていません"
  fi
  if [ -z "${SCENARIO_PORT[$index]}" ]; then
    error "シナリオ ${SCENARIO_NAME[$index]}: port が指定されていません"
  fi
}

# --- メイン処理 ---

if [ -z "$CONFIG_FILE" ]; then
  usage
fi

if [ ! -f "$CONFIG_FILE" ]; then
  error "設定ファイルが見つかりません: $CONFIG_FILE"
fi

# root 権限チェック
if [ "$(id -u)" -ne 0 ]; then
  error "このスクリプトは sudo で実行してください: sudo bash $0 $CONFIG_FILE"
fi

# 配列の初期化
declare -a SCENARIO_NAME=()
declare -a SCENARIO_IP=()
declare -a SCENARIO_PORT=()
declare -a SCENARIO_PROTOCOL=()
declare -a SCENARIO_DIRECTION=()
declare -a SCENARIO_LOSS=()
declare -a SCENARIO_DURATION=()
SCENARIO_COUNT=0

echo "=========================================="
echo " Network Chaos — START"
echo "=========================================="
echo ""

# 設定ファイルをパース
info "設定ファイルを読み込んでいます: $CONFIG_FILE"
parse_scenarios "$CONFIG_FILE"
info "${SCENARIO_COUNT} 個のシナリオを検出"
echo ""

# 既存の pf ルールをバックアップ
info "既存の pf ルールをバックアップしています..."
pfctl -sr > "$PF_BACKUP_FILE" 2>/dev/null || true

# pf ルールファイルを初期化（既存ルールを先頭に入れる）
cp "$PF_BACKUP_FILE" "$PF_RULES_FILE"

# 状態ファイルを初期化（stop 用にパイプ番号を記録）
> "$CHAOS_STATE_FILE"
echo "# chaos-start.sh が生成した状態ファイル" >> "$CHAOS_STATE_FILE"
echo "# chaos-stop.sh がこのファイルを読んでクリーンアップする" >> "$CHAOS_STATE_FILE"
echo "PIPE_NUMBERS=\"\"" >> "$CHAOS_STATE_FILE"

pipe_numbers=""

# 各シナリオを適用
for i in $(seq 0 $((SCENARIO_COUNT - 1))); do
  pipe_num=$((PIPE_BASE + i * PIPE_STEP))
  name="${SCENARIO_NAME[$i]}"
  ip="${SCENARIO_IP[$i]}"
  port="${SCENARIO_PORT[$i]}"
  protocol="${SCENARIO_PROTOCOL[$i]}"
  direction="${SCENARIO_DIRECTION[$i]}"
  loss="${SCENARIO_LOSS[$i]}"
  duration="${SCENARIO_DURATION[$i]}"

  # パケットロス率を 0.0〜1.0 に変換
  plr=$(awk -v l="$loss" 'BEGIN {printf "%.2f", l / 100}')

  echo "--- シナリオ $((i + 1)): $name ---"
  echo "  対象:       $ip:$port ($protocol, $direction)"
  echo "  パケットロス: ${loss}% (plr=$plr)"
  echo "  持続時間:    $([ "$duration" = "0" ] && echo "手動停止" || echo "${duration}秒")"
  echo "  パイプ番号:  $pipe_num"

  # dnctl パイプを作成
  dnctl pipe "$pipe_num" config plr "$plr"

  # protocol の展開
  protos=()
  if [ "$protocol" = "both" ]; then
    protos=("tcp" "udp")
  else
    protos=("$protocol")
  fi

  # direction の展開
  dirs=()
  if [ "$direction" = "both" ]; then
    dirs=("in" "out")
  else
    dirs=("$direction")
  fi

  # pf ルールを追加
  for proto in "${protos[@]}"; do
    for dir in "${dirs[@]}"; do
      _add_pf_rule "$dir" "$proto" "$ip" "$port" "$pipe_num"
    done
  done

  pipe_numbers="$pipe_numbers $pipe_num"
  echo ""
done

# 状態ファイルにパイプ番号を記録
sed -i '' "s|PIPE_NUMBERS=\"\"|PIPE_NUMBERS=\"$pipe_numbers\"|" "$CHAOS_STATE_FILE"

# pf ルールを適用
info "pf ルールを適用しています..."
pfctl -f "$PF_RULES_FILE" 2>/dev/null

# pfctl を有効化
pfctl -e 2>/dev/null || true

# duration > 0 のシナリオがあれば自動停止をスケジュール
min_duration=0
for i in $(seq 0 $((SCENARIO_COUNT - 1))); do
  d="${SCENARIO_DURATION[$i]}"
  if [ "$d" -gt 0 ]; then
    if [ "$min_duration" -eq 0 ] || [ "$d" -lt "$min_duration" ]; then
      min_duration="$d"
    fi
  fi
done

echo "=========================================="
echo " Network Chaos が適用されました"
echo "=========================================="
echo ""
echo "適用中のシナリオ:"
for i in $(seq 0 $((SCENARIO_COUNT - 1))); do
  pipe_num=$((PIPE_BASE + i * PIPE_STEP))
  echo "  [pipe $pipe_num] ${SCENARIO_NAME[$i]} — ${SCENARIO_IP[$i]}:${SCENARIO_PORT[$i]} ${SCENARIO_LOSS[$i]}% loss"
done
echo ""

if [ "$min_duration" -gt 0 ]; then
  echo "自動停止: ${min_duration}秒後にすべてのルールが解除されます"
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  (
    sleep "$min_duration"
    echo ""
    echo "[AUTO-STOP] ${min_duration}秒が経過しました。ルールを解除します..."
    bash "${SCRIPT_DIR}/chaos-stop.sh"
  ) &
  echo "  (バックグラウンド PID: $!)"
  echo ""
fi

echo "手動で停止するには:"
echo "  sudo bash $(cd "$(dirname "$0")" && pwd)/chaos-stop.sh"
echo ""
echo "状態を確認するには:"
echo "  sudo bash $(cd "$(dirname "$0")" && pwd)/chaos-status.sh"
echo ""

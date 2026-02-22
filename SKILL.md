---
name: network-chaos
description: |
  macOS向けネットワーク障害シミュレーションスキル。pfctl と dnctl を使って、指定した IP:ポートへの通信にランダムなパケットドロップを直接注入・解除する。
  YAML設定ファイルまたは自然言語の指示から障害シナリオを読み取り、同梱のシェルスクリプトを使ってユーザーの macOS 上でパケットロスを発生させる。
  このスキルは、ユーザーが「ネットワーク障害をシミュレーションしたい」「特定のIPへの通信をランダムにブロックしたい」「カオスエンジニアリングのテストをしたい」「パケットロスを再現したい」「pfctl でトラフィックを制御したい」「ネットワーク不安定にして」と言った場合に使うこと。マイクロサービスの耐障害テスト、API通信の障害テスト、ネットワーク不安定のシミュレーションなど、障害注入全般に対応する。
---

# Network Chaos — macOS ネットワーク障害シミュレーター

macOS の `pfctl`（Packet Filter）と `dnctl`（Dummynet）を使い、特定の IP:ポートへの通信にランダムなパケットドロップを注入する。同梱のシェルスクリプトで障害の注入・解除・状態確認を行う。

## スキルの構成

```
network-chaos/
├── SKILL.md              # このファイル
├── scripts/
│   ├── chaos-start.sh    # 障害を注入する（YAML設定を読んで pfctl/dnctl を実行）
│   ├── chaos-stop.sh     # 障害を解除して元に戻す
│   └── chaos-status.sh   # 現在の障害ルールの状態を確認する
└── assets/
    └── sample-config.yaml  # サンプル設定ファイル
```

## 前提条件

- macOS であること（pfctl / dnctl は macOS 標準搭載）
- `sudo` 権限が使えること
- ユーザーの macOS のターミナルに直接アクセスできる環境であること（Claude Code など）

## 設定ファイルの形式

障害シナリオは YAML で定義する:

```yaml
scenarios:
  - name: "API server intermittent failure"
    target:
      ip: "192.168.1.100"
      port: 8080
      protocol: tcp        # tcp | udp | both（デフォルト: tcp）
      direction: out       # in | out | both（デフォルト: out）
    chaos:
      packet_loss: 30      # パケットロス率（%）0〜100
      duration: 0          # 秒。0 = 手動で stop するまで継続
```

| フィールド | 必須 | デフォルト | 説明 |
|---|---|---|---|
| `name` | Yes | — | シナリオの名前（ログ用） |
| `target.ip` | Yes | — | 対象の IP アドレス |
| `target.port` | Yes | — | 対象のポート番号 |
| `target.protocol` | No | `tcp` | tcp, udp, both のいずれか |
| `target.direction` | No | `out` | in（受信）, out（送信）, both |
| `chaos.packet_loss` | Yes | — | パケットロス率 (%) |
| `chaos.duration` | No | `0` | 適用時間（秒）。0 = 手動停止 |

サンプル設定は `assets/sample-config.yaml` を参照。

## ワークフロー

### 1. 設定の準備

ユーザーが YAML 設定ファイルを渡した場合はそのまま使う。

ユーザーが自然言語で指示した場合（例: 「192.168.1.100:8080 を30%ブロックして」）は:
1. 指示内容から YAML 設定ファイルを生成する
2. 内容をユーザーに見せて確認を取る
3. 確認が取れたら一時ファイルとして保存する

### 2. 障害の注入

設定ファイルが用意できたら、以下を実行する。実行前に「この設定で障害を注入します。sudo 権限が必要です。実行しますか？」と確認すること。

```bash
sudo bash <skill-path>/scripts/chaos-start.sh <config.yaml>
```

スクリプトが行うこと:
- 既存の pf ルールをバックアップ
- 各シナリオに対して dnctl パイプを作成（パケットロス率を設定）
- pf ルールで対象トラフィックをパイプに転送
- duration > 0 の場合、バックグラウンドで自動停止をスケジュール

### 3. 障害の解除

ユーザーが「止めて」「元に戻して」「障害を解除して」と言った場合:

```bash
sudo bash <skill-path>/scripts/chaos-stop.sh
```

スクリプトが行うこと:
- pf ルールをバックアップから復元
- dnctl パイプを削除
- 一時ファイルをクリーンアップ

### 4. 状態確認

ユーザーが「今の状態は？」「ルールを確認したい」と言った場合:

```bash
sudo bash <skill-path>/scripts/chaos-status.sh
```

## 安全上の注意

- **実行前に必ずユーザーの確認を取る**: pfctl のルール変更はネットワーク接続に直接影響する。sudo コマンドを実行する前に、何をするか説明して明示的な許可を得ること。
- **本番環境では使わない**: ローカル開発・テスト環境でのみ使用する。ユーザーにもその旨を伝える。
- **解除忘れ防止**: 障害を注入した後、セッション終了時や話題が変わる前に「ネットワーク障害ルールがまだ有効ですが、解除しますか？」と声をかける。

## pfctl / dnctl の仕組み（参考）

macOS でパケットロスをシミュレーションするには2つのツールを組み合わせる:

- **`dnctl`**: Dummynet のパイプを作り、パケットロス率（plr）を設定する
- **`pfctl`**: Packet Filter のルールで、対象トラフィックを Dummynet パイプに転送する

pfctl が「どのトラフィックを」、dnctl が「どう劣化させるか」を担当する。スクリプトの中身を理解するとき、この2段構成を知っていると見通しが良くなる。

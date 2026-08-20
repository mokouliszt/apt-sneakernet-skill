[English](README.md) | 日本語

# apt-sneakernet-skill

閉域網(オフライン/エアギャップ)のDebian/Ubuntu機へ、物理メディア(USB等)で持ち込みインストールするための`.deb`バンドルを作成する[Claude](https://claude.com)のSkill(web・モバイル版対応)。チャットでClaudeに「このソフトをこのUbuntu/Debianリリース向けにバンドルして」と頼むだけで、依存関係とサードパーティAPTリポジトリを含めた状態でアーカイブを作成し、閉域網にUSBで持ち込める形で渡してくれる。CIや外部インフラは一切不要。

すべてClaude自身のサンドボックス(web/モバイル版Claudeで使える「コード実行とファイル作成」環境)内で完結する。ユーザーのマシンには何もインストールされない。

## 仕組み

内部では、対象のリリース・アーキテクチャと完全に一致する`debootstrap` chrootをClaudeが構築し、`apt-get install --download-only`でPostgreSQL公式PGDGリポジトリのようなサードパーティリポジトリを含めて依存関係を解決、結果(`.deb`ファイル群 + マニフェスト + インストールスクリプト)を単一のアーカイブにまとめる。

## 動機

閉域網/エアギャップ環境のマシンは通常、別のインターネット接続されたマシン上で事前にパッケージを取得しておく必要があるが、そのステージング用マシンは対象と異なるOSリリースで動いていることが多い。そのステージングマシン上で単純に`apt-get install --download-only`を実行すると、対象リリースと一致しない依存バージョンやバイナリを取得してしまう可能性がある。

このSkillは、ダウンロード前に`debootstrap`で対象のapt環境をローカルに正確に再現するため、取得されるものと対象マシンが実際にインストールできるものとの間にバージョンのずれが生じない。

## 使用例

Claudeに次のように頼む: 「PostgreSQL 16を、公式PGDGリポジトリ込みでUbuntu 24.04(noble)向けにオフラインインストール用にバンドルして」

内部では`scripts/build-offline-bundle.sh`が実行される:

```bash
sudo bash scripts/build-offline-bundle.sh \
  --release noble \
  --extra-repo "deb https://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
  --extra-repo-key https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  --package postgresql-16 --package postgresql-client-16 \
  --out ./postgresql-noble-bundle.tar.gz
```

オプションの全リファレンス: `scripts/build-offline-bundle.sh --help`

### 検証済みの組み合わせ例

同じ手法はどのリリース×サードパーティリポジトリの組み合わせでも動作する:

| リリース | ソフトウェア/リポジトリ | 検証状況 |
|---|---|---|
| noble (24.04) | PostgreSQL公式(PGDG) | フルダウンロード検証済み(上記の実例) |
| resolute (26.04、最新LTS) | HashiCorp公式(Terraform) | フルダウンロード検証済み |
| jammy (22.04) | Node.js公式(NodeSource) | リポジトリ解決まで検証済み |
| noble (24.04) | Docker公式 | リポジトリ解決まで検証済み |
| bookworm (Debian 12) 等 | `--mirror`/`--components`を適宜変更 | 未検証 |

生成される`bundle.tar.gz`の中身:

```
bundle/
├── MANIFEST.txt          # パッケージ名・バージョン・sha256
├── install-offline.sh    # オフライン機で実行(概ね`sudo dpkg -i ./*.deb`)
└── *.deb                 # 収集された全パッケージ
```

オフライン機ではアーカイブを展開して`./install-offline.sh`を実行するだけでよい。

## 要件

- サンドボックス(「コード実行とファイル作成」環境)が有効なClaude(web/モバイル版) — root権限とパッケージ取得元へのoutbound HTTPS到達性がデフォルトで利用可能
- `debootstrap`(なければaptから自動導入)

## 対応範囲

- ✅ Debian/Ubuntu(APT)、任意のリリース、任意のサードパーティAPTリポジトリ
- ⚠️ クロスアーキ(`--arch arm64`等)は理論上動作するはずだが未検証(`qemu-user-static`/`binfmt-support`が必要)
- ❌ RPM系ディストリ(Fedora/RHEL/openSUSE)は非対応

## Skillの導入方法

このリポジトリをClaudeのSkillとして追加する(リポジトリルートの`SKILL.md`)。会話内で利用可能になったら、バンドルしてほしい内容を伝えるだけでよい。

実装上ハマりやすい点(CA証明書の引き継ぎ等)は[`references/implementation-notes.md`](references/implementation-notes.md)にまとめてある。

## ライセンス

MIT — [LICENSE](LICENSE)を参照。

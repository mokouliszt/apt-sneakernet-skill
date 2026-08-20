[English](README.md) | 日本語

# apt-sneakernet-skill

[Claude](https://claude.com)のSkill(web/モバイル版)。閉域網(エアギャップ)の
Debian/Ubuntu機向けに、オフラインインストール用の`.deb`バンドルを作成する。
チャットで「〇〇をUbuntu 24.04向けにオフラインでまとめて」のように依頼するだけで、
依存関係・サードパーティAPTリポジトリ込みのアーカイブが返ってくる。USB等で閉域網へ
持ち込めばそのままインストールできる。CIや追加の外部インフラは不要。

実行はすべてClaude自身のサンドボックス(web/モバイル版Claudeの「コード実行と
ファイル作成」機能の環境)内で完結し、手元のマシンには何もインストールしない。

## 仕組み

裏側では、対象のリリース/アーキと完全に一致する`debootstrap` chrootをClaudeが構築し、
`apt-get install --download-only`で依存関係(PostgreSQL公式PGDGリポジトリのような
サードパーティAPTリポジトリ含む)を解決、結果(`.deb`一式 + マニフェスト +
インストールスクリプト)を1つのアーカイブにまとめる。

## なぜこれが要るのか

閉域網の実機は、多くの場合「対象と同じOSリリースではない、別のネット接続機」で
パッケージを事前取得してから持ち込む必要がある。しかし単純に
`apt-get install --download-only` するだけでは、作業機のOSリリースが対象と異なる場合
依存関係のバージョンがズレたり、対象では使えないバイナリを掴んでしまうことがある。

このSkillは `debootstrap` で対象と完全に同一のapt環境を再現してからダウンロードするため、
リリースのズレによる問題を避けられる。

## 使用例

Claudeに「PostgreSQL 16をUbuntu 24.04(noble)向けにオフラインでまとめて、公式PGDG
リポジトリも込みで」のように依頼する。

裏側でClaudeが実行する `scripts/build-offline-bundle.sh`:

```bash
sudo bash scripts/build-offline-bundle.sh \
  --release noble \
  --extra-repo "deb https://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
  --extra-repo-key https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  --package postgresql-16 --package postgresql-client-16 \
  --out ./postgresql-noble-bundle.tar.gz
```

全オプションは `scripts/build-offline-bundle.sh --help` を参照。

### その他の組み合わせ例

同じ手順で任意のリリース×サードパーティリポジトリに対応できる:

| リリース | ソフトウェア/リポジトリ | 検証状況 |
|---|---|---|
| noble (24.04) | PostgreSQL公式(PGDG) | フルダウンロードまで確認済み(上記の使用例) |
| resolute (26.04・最新LTS) | HashiCorp公式(Terraform) | フルダウンロードまで確認済み |
| jammy (22.04) | Node.js公式(NodeSource) | リポジトリ解決まで確認済み |
| noble (24.04) | Docker公式 | リポジトリ解決まで確認済み |
| bookworm (Debian 12) 等 | `--mirror`/`--components` を差し替えれば同様に対応可 | 未検証 |

生成される `bundle.tar.gz` の中身:

```
bundle/
├── MANIFEST.txt          # パッケージ名・バージョン・sha256
├── install-offline.sh    # オフライン機側で実行 (sudo dpkg -i ./*.deb 相当)
└── *.deb                 # 収集された全パッケージ
```

オフライン機側では、展開後に `./install-offline.sh` を実行するだけでよい。

## 要件

- Claude(web/モバイル版)の「コード実行とファイル作成」機能が有効なこと
  (このサンドボックスにはroot権限とoutbound HTTPS到達性がデフォルトで備わっている)
- `debootstrap`(未導入なら自動でaptから導入)

## 対応範囲

- ✅ Debian/Ubuntu系(APT)、任意のリリース・任意のサードパーティAPTリポジトリ
- ⚠️ クロスアーキ(`--arch arm64` 等)は理論上動作するはずですが未検証です
  (`qemu-user-static` / `binfmt-support` の追加導入が必要になります)
- ❌ RPM系(Fedora/RHEL/openSUSE)は非対応です

## Skillの導入

このリポジトリをClaudeにSkillとして追加する(リポジトリ直下の`SKILL.md`)。
会話内で使えるようになったら、まとめてほしいものをチャットで伝えるだけでよい。

実装上ハマりやすい点(CA証明書の引き継ぎ等)は
[`references/implementation-notes.md`](references/implementation-notes.md) を参照。

## License

MIT — see [LICENSE](LICENSE).

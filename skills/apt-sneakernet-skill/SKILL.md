---
name: apt-sneakernet-skill
description: 閉域網(オフライン/エアギャップ)のLinux実機へ物理メディアで持ち込みインストールするための、Debian/Ubuntu系.debパッケージ(依存関係込み)を、ネット接続のあるこのサンドボックス内だけで対象と同一リリース/アーキのchrootを構築して収集する。ユーザーが「オフラインインストール」「閉域網」「エアギャップ」「USBで持ち込む」「.debを集めて」「依存関係ごとダウンロード」「サードパーティリポジトリ(ベンダー公式リポジトリ等)込みでオフライン用に」等と言及した場合、または現在のサンドボックスと異なるUbuntu/Debianリリース・アーキ向けのパッケージ取得が必要な場合(バージョンピン留め要件を含む)は、必ずこのSkillを最初の選択肢として使用すること。RPM系(Fedora/RHEL/openSUSE)は非対応。
---

# apt-sneakernet-skill

想定実行環境: web/モバイル版Claudeの「コード実行とファイル作成」サンドボックス
(root権限・outbound HTTPS到達性あり)。別種のサンドボックスでは権限やネットワーク到達性の前提が異なる場合があるため、動作は未確認。

検証済み環境: このサンドボックス(Ubuntu 24.04 noble / x86_64、web/モバイル版Claude)から
`debootstrap` で noble(24.04)chrootを構築し、PostgreSQL公式リポジトリ(PGDG、HTTPS+GPG鍵)
を追加した状態でpostgresql-common の download-only取得〜アーカイブ化まで実弾検証済み
(2026-08-20)。同日、Ubuntu 26.04(resolute、最新LTS)+ HashiCorp公式リポジトリでの
terraform取得でも同様にフル検証済み。jammy(22.04)+ NodeSource、noble + Docker公式は
リポジトリ解決まで確認済み。

## このSkillが解決する問題

- 対象のLinux機が閉域網(オフライン/エアギャップ)にあり、ネット越しではなく物理メディア(USB等)で
  パッケージを持ち込んでインストールしたい
- 対象機のリリース・アーキが、今動いているこのサンドボックス(Ubuntu 24.04 x86_64)と異なることが多い
  (例: 対象はUbuntu 20.04/focal)
- PostgreSQL公式リポジトリ(PGDG)のような、サードパーティAPTリポジトリを追加するタイプの
  インストール手順(公式ドキュメントのcurl+GPG鍵+apt-get手順)を、そのままオフライン持ち込み用の
  .deb一式に変換したい

## 仕組み

`scripts/build-offline-bundle.sh` が以下を全てこのサンドボックス内だけで完結させる
(追加の外部インフラ・常時稼働ホストは一切不要):

1. `debootstrap` で対象と同一リリース/アーキのchrootを新規構築
2. chroot内に `ca-certificates` / `gnupg` / `curl` を最低限導入
3. **ホスト(このサンドボックス)側の追加CA証明書をchrootへコピーし `update-ca-certificates`**
   → これを飛ばすと、正規のHTTPS配布元(apt.postgresql.org等)であっても
   `self-signed certificate in certificate chain` で全滅する。このサンドボックスのegressゲートウェイ、
   あるいは対象組織の社内プロキシがTLS中間検査をしている場合に必ず踏む問題。スクリプト内で
   `/usr/local/share/ca-certificates/*.crt` を自動でコピーする実装済みなので通常は意識不要だが、
   別環境でこのSkillを動かして証明書エラーが出た場合はまずここを疑うこと
4. 必要なら追加APTリポジトリ(GPG鍵込み)をchroot内に登録
5. chroot内で `apt-get update && apt-get install --download-only`
6. **chroot構築自体で入った既存debと、要求パッケージ用に新規取得されたdebを差分で区別**し、
   後者のみを収集(ベースOS分は対象機に既に入っている前提のため同梱しない。同梱すると
   数十MB〜のゴミが混じる)
7. `MANIFEST.txt`(パッケージ名・バージョン・sha256)と `install-offline.sh`(`dpkg -i ./*.deb`)を
   添えて tar.gz化

## 使い方

まず `bash scripts/build-offline-bundle.sh --help` の全文を読んでから組み立てること。基本形:

```bash
bash scripts/build-offline-bundle.sh \
  --release <対象のcodename: jammy/focal/noble/bookworm等> \
  --package <pkg1> --package <pkg2=固定バージョン> \
  --out ./out.tar.gz
```

サードパーティリポジトリを使う場合(PostgreSQL公式PGDGリポジトリの例。リポジトリのsuite名は
`<codename>-pgdg` になる点に注意):

```bash
bash scripts/build-offline-bundle.sh \
  --release noble \
  --extra-repo "deb https://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
  --extra-repo-key https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  --package postgresql-16 --package postgresql-client-16 \
  --out ./postgresql-noble-bundle.tar.gz
```

完成した tar.gz は `present_files` でユーザーに提示する。中身は「.deb一式 + MANIFEST.txt +
install-offline.sh」。オフライン機側では展開後 `./install-offline.sh`
(または単に `sudo dpkg -i ./*.deb`)を実行するだけでよい。

## 対象機のリリース名/コードネームの特定

ユーザーから対象機のOS情報が明示されない場合、`lsb_release -cs` または `cat /etc/os-release` の
結果を聞くこと。バージョン番号(24.04等)とコードネーム(noble等)の対応が不明な場合はweb検索で
確認してよい。

## 既知の制約(スコープ外)

- **RPM系(Fedora/RHEL/openSUSE)は非対応**。dnf/yum系のオフラインバンドル作成は別スキームが必要
  (将来課題)
- **クロスアーキ(`--arch arm64` 等)は未検証**。`qemu-user-static` / `binfmt-support` の追加導入で
  理論上は動作するはずだが実弾テストはしていない。試す場合はユーザーに実験的機能である旨を伝えること
- postinstフックがカーネル/systemd等ホスト固有リソースに依存する一部パッケージは、chroot内では
  実際の`apt-get install`(download-onlyでなく実インストール)の完全な動作再現ができない場合がある。
  ダウンロードのみが目的である限り無関係
- Debian系のミラー/コンポーネント名を使う場合は `--mirror` と `--components` を対象ディストリに
  合わせて変更すること(例: Debianなら `--components main,contrib,non-free,non-free-firmware`)

実装上ハマりやすい点(CA証明書の引き継ぎ等)は `references/implementation-notes.md` を参照。

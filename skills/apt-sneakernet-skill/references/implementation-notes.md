# 実装上ハマりやすい点(再発防止用)

- **CA証明書**: 新規debootstrapのchrootは、ホストが信頼している「追加の」CA証明書
  (TLS中間プロキシ等)を引き継がない。これを怠ると正規のHTTPS配布元でも
  `self-signed certificate in certificate chain` で全滅する。ホストの
  `/usr/local/share/ca-certificates/*.crt` をchrootにコピーして
  `update-ca-certificates` を再実行する必要がある
- **minbaseにca-certificates/gnupgは含まれない**: `update-ca-certificates`
  コマンド自体が存在しないので、まずHTTPミラー経由(HTTPS信頼設定が整う前でも
  通信できる)で `ca-certificates gnupg curl` を導入してから証明書周りの処理に進む
  必要がある
- **収集対象の絞り込み**: `apt-get install --download-only` を素朴に実行して
  `var/cache/apt/archives/*.deb` を丸ごと集めると、debootstrap/CA導入時に
  キャッシュされたベースOS分のdeb(100件超)まで混入する。要求パッケージ実行の
  前後でディレクトリの差分を取り、新規分のみをバンドルに含めること

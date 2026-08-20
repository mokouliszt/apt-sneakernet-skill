#!/usr/bin/env bash
#
# build-offline-bundle.sh — apt-sneakernet-skill
#
# ネット接続のある環境(このスクリプトの実行環境そのもの)の中に、debootstrapで
# 「対象と全く同じリリース/アーキ」のchrootを作り、その中でapt-get install
# --download-only を実行して .deb 一式を集める。
#
# 用途: 閉域網(オフライン/エアギャップ)の実機に、ネットワーク越しではなく
# 物理メディア(USB等)で持ち込んでインストールするためのパッケージ束を作る。
#
# 対応: Debian/Ubuntu系のみ(APT)。RPM系は非対応。
# 要件: root権限、debootstrap(なければ自動導入)、outbound https到達性。
#
# License: MIT

set -euo pipefail

# ---------------------------------------------------------------------------
# デフォルト値
# ---------------------------------------------------------------------------
ARCH="amd64"
MIRROR="http://archive.ubuntu.com/ubuntu"
COMPONENTS="main,universe,restricted,multiverse"
VARIANT="minbase"
RELEASE=""
WORKDIR=""
OUTFILE=""
KEEP_CHROOT=0

declare -a PACKAGES=()
declare -a EXTRA_REPOS=()
declare -a EXTRA_REPO_KEYS=()

# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
使い方:
  build-offline-bundle.sh --release <codename> [options] [--package NAME ...] [-- pkg1 pkg2 ...]

必須:
  --release CODENAME         debootstrap対象のリリース名
                              (例: jammy, focal, noble, bookworm, bullseye, trixie)
  パッケージ指定は --package を1回以上、または末尾の位置引数(--以降)で指定

主なオプション:
  --arch ARCH                 対象アーキ (default: amd64)
                               amd64以外(arm64等)を指定する場合は事前に
                               `apt-get install -y qemu-user-static binfmt-support`
                               の導入を推奨(未検証・実験的機能)
  --mirror URL                 debootstrap用ミラー (default: Ubuntu archive)
                               Debian系なら http://deb.debian.org/debian 等に変更
  --components LIST            debootstrapで有効化するコンポーネント
                               (default: main,universe,restricted,multiverse。
                                Debianなら main,contrib,non-free,non-free-firmware 等に変更)
  --package NAME[=VERSION]    取得したいパッケージ (複数指定可、バージョン固定も可)
  --extra-repo "DEB_LINE"      追加リポジトリ行をsources.list.d形式そのままで指定
                               (複数指定可。直後の --extra-repo-key と1:1で対応)
  --extra-repo-key URL_OR_PATH_OR_none
                               直前の --extra-repo に対応するGPG鍵のURL/ローカルパス。
                               鍵不要なリポジトリの場合は文字列 "none" を指定
  --workdir DIR                 chroot作業先 (default: mktemp -d)
  --out FILE                    出力アーカイブパス
                               (default: ./offline-bundle-<release>-<arch>-<timestamp>.tar.gz)
  --keep-chroot                 後始末でchrootを削除しない(デバッグ用)
  -h, --help                    このヘルプを表示

注意(重要): 実行環境がTLS中間プロキシ配下にある場合(社内プロキシ、Claude
サンドボックスのegressゲートウェイ等)、ホスト側の追加CA証明書を
/usr/local/share/ca-certificates/ から自動でchrootへコピーする。
このディレクトリが空でも動作するが、証明書エラーが出る場合はホスト側の
信頼ストアを手動で確認すること。

例1: PostgreSQL公式(PGDG)リポジトリからnoble(24.04)向けに取得
     (リポジトリのsuite名は "<codename>-pgdg" になる点に注意)
  build-offline-bundle.sh --release noble \
    --extra-repo "deb https://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
    --extra-repo-key https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    --package postgresql-16 --package postgresql-client-16 \
    --out ./postgresql-noble-bundle.tar.gz

例2: 単純にvimをnoble(24.04)向けに取得(位置引数スタイル)
  build-offline-bundle.sh --release noble -- vim
EOF
}

log() { echo "[build-offline-bundle] $*" >&2; }
die() { echo "[build-offline-bundle] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 引数パース
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --mirror) MIRROR="$2"; shift 2 ;;
    --components) COMPONENTS="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --package) PACKAGES+=("$2"); shift 2 ;;
    --extra-repo) EXTRA_REPOS+=("$2"); shift 2 ;;
    --extra-repo-key) EXTRA_REPO_KEYS+=("$2"); shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --out) OUTFILE="$2"; shift 2 ;;
    --keep-chroot) KEEP_CHROOT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [[ $# -gt 0 ]]; do PACKAGES+=("$1"); shift; done ;;
    *) die "不明な引数: $1 (--help参照)" ;;
  esac
done

[[ -n "$RELEASE" ]] || { usage; die "--release は必須"; }
[[ ${#PACKAGES[@]} -gt 0 ]] || die "パッケージが1つも指定されていない(--package または -- pkg1 pkg2)"
[[ ${#EXTRA_REPOS[@]} -eq ${#EXTRA_REPO_KEYS[@]} ]] || die "--extra-repo と --extra-repo-key の数が一致しない(1:1で指定すること。鍵不要なら 'none')"

if [[ "$(id -u)" -ne 0 ]]; then
  die "root権限が必要(debootstrap/chrootのため)。sudoで再実行するか、root環境で実行してください"
fi

TS="$(date +%Y%m%d-%H%M%S)"
[[ -n "$WORKDIR" ]] || WORKDIR="$(mktemp -d /tmp/apt-sneakernet.XXXXXX)"
[[ -n "$OUTFILE" ]] || OUTFILE="./offline-bundle-${RELEASE}-${ARCH}-${TS}.tar.gz"
CHROOT="${WORKDIR}/chroot"

mkdir -p "$CHROOT"

# ---------------------------------------------------------------------------
# 1) ホスト側の前提ツール確認
# ---------------------------------------------------------------------------
log "ホスト側の前提ツール(debootstrap等)を確認..."
if ! command -v debootstrap >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y --no-install-recommends debootstrap ca-certificates gnupg curl >/dev/null
fi

# ---------------------------------------------------------------------------
# 2) debootstrapでターゲットchroot構築
# ---------------------------------------------------------------------------
log "debootstrap: release=${RELEASE} arch=${ARCH} components=${COMPONENTS}"
log "  (対象アーキがホストと異なる場合、qemu-user-staticが未導入だと失敗することがある)"
debootstrap --variant="${VARIANT}" --arch="${ARCH}" --components="${COMPONENTS}" \
  "${RELEASE}" "${CHROOT}" "${MIRROR}"

# ---------------------------------------------------------------------------
# 3) DNS/CA証明書の引き継ぎ(★ここが最重要の落とし穴)
#    新規debootstrapのchrootは、ホストが信頼している「追加の」CA証明書
#    (社内プロキシ・TLS中間装置・Claudeサンドボックスのegressゲートウェイ等)
#    を一切引き継がない。これを怠ると、まさに正規のHTTPS配布元
#    (apt.postgresql.org等)であっても
#    "self-signed certificate in certificate chain" で全滅する。
# ---------------------------------------------------------------------------
log "DNS設定を引き継ぎ..."
cp /etc/resolv.conf "${CHROOT}/etc/resolv.conf"

# minbaseにはca-certificates/gnupgが含まれないため、まずHTTPミラー経由
# (この時点ではまだHTTPS通信の信頼設定ができていないためHTTPのみで良い)
# で最低限のツールを入れる。これがないとupdate-ca-certificates自体が存在しない。
log "chroot内に ca-certificates/gnupg/curl を導入..."
chroot "${CHROOT}" apt-get update
chroot "${CHROOT}" apt-get install -y --no-install-recommends ca-certificates gnupg curl

log "ホストの追加CA証明書をchrootへ引き継ぎ..."
mkdir -p "${CHROOT}/usr/local/share/ca-certificates"
if compgen -G "/usr/local/share/ca-certificates/*.crt" > /dev/null; then
  cp /usr/local/share/ca-certificates/*.crt "${CHROOT}/usr/local/share/ca-certificates/"
  chroot "${CHROOT}" update-ca-certificates >/dev/null
  log "  ホスト追加CA証明書を反映した"
else
  log "  ホストに追加CA証明書は見当たらない(標準CAのみで続行)"
fi

# ---------------------------------------------------------------------------
# 4) 追加リポジトリ(サードパーティ)の登録
# ---------------------------------------------------------------------------
mkdir -p "${CHROOT}/etc/apt/trusted.gpg.d" "${CHROOT}/etc/apt/sources.list.d"

for i in "${!EXTRA_REPOS[@]}"; do
  REPO_LINE="${EXTRA_REPOS[$i]}"
  KEY_SRC="${EXTRA_REPO_KEYS[$i]}"
  log "追加リポジトリ #${i}: ${REPO_LINE}"
  echo "${REPO_LINE}" > "${CHROOT}/etc/apt/sources.list.d/apt-sneakernet-extra-${i}.list"

  if [[ "${KEY_SRC}" != "none" ]]; then
    KEY_DEST="${CHROOT}/etc/apt/trusted.gpg.d/apt-sneakernet-extra-${i}.gpg"
    if [[ "${KEY_SRC}" =~ ^https?:// ]]; then
      curl -fsSL "${KEY_SRC}" | chroot "${CHROOT}" gpg --dearmor -o "/etc/apt/trusted.gpg.d/apt-sneakernet-extra-${i}.gpg"
    else
      [[ -f "${KEY_SRC}" ]] || die "鍵ファイルが見つからない: ${KEY_SRC}"
      cat "${KEY_SRC}" | chroot "${CHROOT}" gpg --dearmor -o "/etc/apt/trusted.gpg.d/apt-sneakernet-extra-${i}.gpg"
    fi
  fi
done

# ---------------------------------------------------------------------------
# 5) apt-get update → download-only
# ---------------------------------------------------------------------------
log "chroot内でapt-get update..."
chroot "${CHROOT}" apt-get update

# chroot構築・CA/gnupg導入の過程で既にarchivesにキャッシュされたベースOS用debと、
# これから対象パッケージ用にダウンロードされるdebを区別するため、実行前後で差分を取る。
# (ベースOS側は対象機に既に入っている前提のため配布物には含めない)
shopt -s nullglob
BEFORE_DEBS=("${CHROOT}"/var/cache/apt/archives/*.deb)
shopt -u nullglob

log "chroot内でapt-get install --download-only: ${PACKAGES[*]}"
chroot "${CHROOT}" apt-get install --download-only -y "${PACKAGES[@]}"

# ---------------------------------------------------------------------------
# 6) 収集(差分分のみ)・マニフェスト生成・アーカイブ化
# ---------------------------------------------------------------------------
BUNDLE_DIR="${WORKDIR}/bundle"
mkdir -p "${BUNDLE_DIR}"

declare -A SEEN_BEFORE=()
for f in "${BEFORE_DEBS[@]}"; do SEEN_BEFORE["$(basename "$f")"]=1; done

shopt -s nullglob
ALL_DEBS_AFTER=("${CHROOT}"/var/cache/apt/archives/*.deb)
shopt -u nullglob

declare -a DEBS=()
for f in "${ALL_DEBS_AFTER[@]}"; do
  bn="$(basename "$f")"
  if [[ -z "${SEEN_BEFORE[$bn]+x}" ]]; then
    DEBS+=("$f")
  fi
done
[[ ${#DEBS[@]} -gt 0 ]] || die "収集されたdebが0件。要求パッケージが既にベースOS内に含まれているか、パッケージ名/リポジトリ設定を確認してください"

cp "${DEBS[@]}" "${BUNDLE_DIR}/"

{
  echo "# apt-sneakernet-skill offline bundle manifest"
  echo "# release=${RELEASE} arch=${ARCH} generated=$(date -Iseconds)"
  echo "# requested packages: ${PACKAGES[*]}"
  echo ""
  for deb in "${BUNDLE_DIR}"/*.deb; do
    NAME_VER="$(dpkg-deb -f "$deb" Package Version | paste -sd' ')"
    SUM="$(sha256sum "$deb" | awk '{print $1}')"
    printf "%-50s %s  %s\n" "$(basename "$deb")" "$SUM" "$NAME_VER"
  done
} > "${BUNDLE_DIR}/MANIFEST.txt"

cat > "${BUNDLE_DIR}/install-offline.sh" <<'INSTALLEOF'
#!/bin/sh
# オフライン機側での実行用。同ディレクトリの*.debを一括インストールする。
set -e
cd "$(dirname "$0")"
sudo dpkg -i ./*.deb
echo "完了。依存不足エラーが出た場合はMANIFEST.txtで取得範囲を確認してください。"
INSTALLEOF
chmod +x "${BUNDLE_DIR}/install-offline.sh"

mkdir -p "$(dirname "$OUTFILE")" 2>/dev/null || true
tar -czf "$OUTFILE" -C "$(dirname "$BUNDLE_DIR")" "$(basename "$BUNDLE_DIR")"

log "完了: ${OUTFILE} ($(du -h "$OUTFILE" | cut -f1), deb ${#DEBS[@]}件)"

# ---------------------------------------------------------------------------
# 7) 後片付け
# ---------------------------------------------------------------------------
if [[ "$KEEP_CHROOT" -eq 0 ]]; then
  rm -rf "${WORKDIR}"
else
  log "chrootを保持: ${WORKDIR}"
fi

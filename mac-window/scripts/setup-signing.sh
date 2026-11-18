#!/bin/sh
# Apple ID（無料）の開発用証明書で署名する設定ファイル Config/Local.xcconfig を作る。
# これでビルドし直してもアクセシビリティの許可が外れなくなる。
# 事前に Xcode の Settings → Apple Accounts で Apple ID を追加し、
# 「Manage Certificates…」→「+」→「Apple Development」で証明書を作っておく。
# 使い方: sh mac-window/scripts/setup-signing.sh
set -e
cd "$(dirname "$0")/.."

# 証明書の「組織単位（OU）」がチームID（英数字10文字）
TEAM=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null \
  | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -n 1)

if [ -z "$TEAM" ]; then
  echo "❌ Apple Development の証明書が見つかりませんでした。"
  echo "   Xcode → Settings → Apple Accounts → Apple ID を選ぶ → Manage Certificates… → + → Apple Development"
  echo "   を行ってから、もう一度実行してください。"
  exit 1
fi

cat > Config/Local.xcconfig <<CONF
// setup-signing.sh が作成（Git には入らない）
MADO_SIGN_STYLE = Manual
MADO_SIGN_IDENTITY = Apple Development
MADO_TEAM = $TEAM
CONF
echo "✅ チームID $TEAM で署名する設定を作りました（Config/Local.xcconfig）。"

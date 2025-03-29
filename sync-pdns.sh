#!/bin/bash

# --- 設定項目 ---
# PowerDNS APIエンドポイント (ゾーン名の末尾のドットに注意)
PDNS_API_URL_FWD="http://YOUR_POWERDNS_ADDR:8081/api/v1/servers/localhost/zones/YOUR_ZONE_HERE."
# PowerDNS API のベースURL (サーバー/インスタンス部分まで。例: localhost)
# 末尾にスラッシュは含めないでください。
PDNS_API_BASE_URL="http://YOUR_POWERDNS_ADDR_HERE:8081/api/v1/servers/localhost"
PDNS_API_KEY="YOUR_VERY_SECRET_API_KEY_HERE" # PowerDNSのAPIキー
DOMAIN="YOUR_DOMAIN_HERE"                 # VMのドメイン名
DEFAULT_TTL=60                      # DNSレコードのTTL (秒)
LOG_FILE="/var/log/proxmox-powerdns-hook.log"
IP_RECORD_DIR="/var/tmp/proxmox_vm_ips" # IPアドレス記録用ディレクトリ
# QEMU Guest AgentからのIP取得リトライ回数と待機時間
IP_RETRY_COUNT=10
IP_RETRY_WAIT=30
# --- 設定項目ここまで ---

# --- 初期処理 ---
# IP記録ディレクトリ作成 (存在しなければ)
mkdir -p "$IP_RECORD_DIR"
if [ ! -d "$IP_RECORD_DIR" ] || [ ! -w "$IP_RECORD_DIR" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - エラー: IP記録ディレクトリ $IP_RECORD_DIR が作成できないか、書き込み権限がありません。" >&2
    exit 1 # ディレクトリに問題があればスクリプトを中断
fi

# --- 関数定義 ---
log() {
    # ログファイルへの出力と標準エラー出力への出力を両方行う
    echo "$(date '+%Y-%m-%d %H:%M:%S') - VMID $VMID ($PHASE): $1" | tee -a "$LOG_FILE" >&2
}

# PowerDNS API呼び出し関数
# $1: HTTP Method (PATCH) - PowerDNS API v1では PATCH で RRSet を操作する
# $2: API URL
# $3: JSON Payload
# $4: レコードタイプ (A, PTR)
# $5: レコード名 (FQDN or PTR名)
call_pdns_api() {
    local method="PATCH" # PowerDNS API v1は主にPATCHを使用
    local url=$1
    local payload=$2
    local type=$3
    local name=$4
    local http_status

    log "API呼び出し開始: URL=$url, Type=$type, Name=$name"
    # echo "Payload: $payload" >> "$LOG_FILE" # デバッグ用

    # curl実行。-f オプションでHTTPエラー時に失敗ステータスを返すようにする
    # --silent でプログレスメータを抑制し、--show-error でエラーメッセージは表示
    response=$(curl --silent --show-error -f -w "%{http_code}" -X PATCH \
      -H "X-API-Key: $PDNS_API_KEY" \
      -H "Content-Type: application/json" \
      "$url" \
      --data "$payload" 2>&1) # 標準エラーもキャプチャ

    http_status="${response: -3}" # 最後の3文字がHTTPステータスコード

    # PowerDNS APIのPATCHは成功時 204 No Content を返すことが多い
    # 404 Not Found は、削除対象のレコードが存在しない場合なので成功扱いとするケースもある
    if [[ "$http_status" -ge 200 && "$http_status" -lt 300 ]]; then
        log "API呼び出し成功 (HTTP Status: $http_status)"
        return 0
    elif [ "$http_status" == "404" ] && [[ "$payload" == *'"changetype": "DELETE"'* ]]; then
         log "警告: API呼び出し時に対象レコードが見つかりませんでした (HTTP Status: 404)。削除済みとみなします。"
         return 0 # 削除の場合は404も成功とみなす
    else
        log "エラー: API呼び出し失敗 (HTTP Status: $http_status)"
        log "エラー詳細: ${response%???}" # ステータスコード部分を除いたレスポンスボディ
        return 1
    fi
}

# IPアドレスからPTRレコード名と逆引きゾーンAPI URLを動的に生成する関数
# $1: IPアドレス
# $2: (出力用) PTRレコード名格納変数名
# $3: (出力用) 逆引きゾーンAPI URL格納変数名
generate_ptr_info() {
    local ip=$1
    local __ptr_name_var=$2
    local __rev_zone_url_var=$3
    local octet1 octet2 octet3 octet4
    local reverse_ip_parts rev_zone_name

    # IPv4形式チェックとオクテット抽出
    if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        octet1=${BASH_REMATCH[1]}
        octet2=${BASH_REMATCH[2]}
        octet3=${BASH_REMATCH[3]}
        octet4=${BASH_REMATCH[4]}
        # 各オクテットが0-255の範囲内かのチェックも加えるとより堅牢
    else
        log "エラー: 不正なIPv4アドレス形式です: $ip"
        return 1
    fi

    # PTRレコード名を生成 (例: 100.53.72.10.in-addr.arpa.)
    reverse_ip_parts="${octet4}.${octet3}.${octet2}.${octet1}"
    eval $__ptr_name_var="${reverse_ip_parts}.in-addr.arpa."

    # /24 ネットワークを想定した逆引きゾーン名を計算 (例: 53.72.10.in-addr.arpa.)
    # クラスB (例: 72.10.in-addr.arpa.) やクラスAが必要な場合はここのロジックを変更
    rev_zone_name="${octet3}.${octet2}.${octet1}.in-addr.arpa."

    # ベースURLとゾーン名を結合してAPI URLを生成 (末尾のドットもつける)
    #eval $__rev_zone_url_var="${PDNS_API_BASE_URL}/zones/${rev_zone_name}."
    eval $__rev_zone_url_var="${PDNS_API_BASE_URL}/zones/${rev_zone_name}"

    log "IP $ip に対応するPTR名: $(eval echo \$$__ptr_name_var)"
    log "IP $ip に対応する逆引きゾーンAPI URL: $(eval echo \$$__rev_zone_url_var)"

    # 生成したAPI URLに対応するゾーンが実際にPowerDNSに存在するかチェックする処理を追加することも可能 (オプション)
    # 例: curl -s -o /dev/null -f -I -H "X-API-Key: $PDNS_API_KEY" "$(eval echo \$$__rev_zone_url_var)"
    # if [ $? -ne 0 ]; then
    #     log "警告: 生成された逆引きゾーンAPI URLにアクセスできませんでした: $(eval echo \$$__rev_zone_url_var)"
    #     # ここでエラーにするか、処理を続けるか選択
    #     # return 1
    # fi

    return 0
}

# --- メインロジック ---
# 引数の順序を修正: $1 = VMID, $2 = PHASE
VMID=$1
PHASE=$2

# ログ関数定義を引数割り当ての後に移動
log() {
    # ログファイルへの出力と標準エラー出力への出力を両方行う
    echo "$(date '+%Y-%m-%d %H:%M:%S') - VMID $VMID ($PHASE): $1" | tee -a "$LOG_FILE" >&2
}

# フックスクリプト実行時にVMIDが数字であるか、PHASEが空でないかチェック
if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
    # エラーメッセージ修正
    echo "$(date '+%Y-%m-%d %H:%M:%S') - エラー: 不正なVMID ($VMID) またはVMIDが第一引数として渡されませんでした。" | tee -a "$LOG_FILE" >&2
    exit 1
fi
if [ -z "$PHASE" ]; then
     echo "$(date '+%Y-%m-%d %H:%M:%S') - エラー: フェーズ名が第二引数として渡されませんでした (VMID: $VMID)。" | tee -a "$LOG_FILE" >&2
     exit 1
fi

# ここで最初のログ出力
log "スクリプト実行開始"

# VM名取得 (post-destroy以外で試行)
VM_NAME=""
FQDN=""

# VM設定が存在するか確認してから取得を試みる
if qm status $VMID --verbose > /dev/null 2>&1; then
    VM_NAME=$(qm config $VMID | grep name: | awk '{print $2}')
    if [ -n "$VM_NAME" ]; then
        FQDN="${VM_NAME}.${DOMAIN}." # 末尾ドット付与
        log "VM名: $VM_NAME, FQDN: $FQDN を取得しました。"
    else
        log "警告: VM $VMID の名前が config から取得できませんでした。"
    fi
else
     # post-start 以外のフェーズで config が読めなくても警告に留める
     if [ "$PHASE" != "post-start" ]; then
          log "警告: VM $VMID の設定が存在しないか、アクセスできません。FQDNベースの処理がスキップされる可能性があります。"
     else
          # post-start で VM 名が取れないのは致命的エラーとするなど、必要に応じてハンドリング
          log "エラー: VM $VMID の設定が存在しないか、アクセスできません。"
          exit 1
     fi
fi

# --- VM起動後の処理 (レコード作成/更新) ---
if [ "$PHASE" == "post-start" ]; then
    log "VM起動後処理を開始"
    if [ -z "$FQDN" ]; then
        log "エラー: FQDNが不明なため、レコード作成処理を中止します。"
        exit 1
    fi

    # IPアドレス取得 (QEMU Guest Agent経由)
    VM_IP=""
    RETRY=0
    while [ $RETRY -lt $IP_RETRY_COUNT ]; do
        log "IPアドレス取得試行 ($((RETRY+1))/$IP_RETRY_COUNT)..."
        # network-get-interfaces は Guest Agent が起動していないと失敗する
        IP_INFO=$(qm guest cmd $VMID network-get-interfaces 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$IP_INFO" ]; then
            # 複数のIPから適切なものを選択 (例: 最初に見つかった非ループバック/リンクローカルIPv4)
            VM_IP=$(echo "$IP_INFO" | jq -r '.[]? | ."ip-addresses"? | .[]? | select(."ip-address-type" == "ipv4" and ."ip-address" != "127.0.0.1" and (."ip-address" | startswith("169.254.") | not)) | ."ip-address"? | select(.)' | head -n 1)
            if [ -n "$VM_IP" ]; then
                log "IPアドレス取得成功: $VM_IP"
                break
            fi
        fi
        RETRY=$((RETRY+1))
        if [ $RETRY -lt $IP_RETRY_COUNT ]; then
            log "Guest Agent応答なし または IPアドレス未検出。 $IP_RETRY_WAIT 秒待機してリトライします..."
            sleep $IP_RETRY_WAIT
        fi
    done

    if [ -z "$VM_IP" ]; then
        log "エラー: $IP_RETRY_COUNT 回試行しましたが、VM $VMID ($VM_NAME) のIPアドレスを取得できませんでした。Guest Agentが動作しているか確認してください。"
        exit 1
    fi

    # 取得したIPアドレスをファイルに記録
    echo "$VM_IP" > "${IP_RECORD_DIR}/${VMID}.ip"
    if [ $? -eq 0 ]; then
        log "IPアドレス $VM_IP を ${IP_RECORD_DIR}/${VMID}.ip に記録しました。"
    else
        # ファイル書き込み失敗は警告に留め、処理は続行する
        log "警告: IPアドレスのファイルへの記録に失敗しました。削除時にPTRレコードが削除されない可能性があります。"
        # ここで exit 1 するとDNS登録自体もされなくなるため注意
    fi

    # --- Aレコード作成/更新 ---
    log "Aレコード ($FQDN -> $VM_IP) を作成/更新します。"
    JSON_PAYLOAD_A=$(jq -n --arg name "$FQDN" --arg type "A" --argjson ttl "$DEFAULT_TTL" --arg content "$VM_IP" \
    '{rrsets: [{name: $name, type: $type, ttl: $ttl, changetype: "REPLACE", records: [{content: $content, disabled: false}]}]}')
    call_pdns_api "$PDNS_API_URL_FWD" "$JSON_PAYLOAD_A" "A" "$FQDN"
    A_RECORD_RESULT=$?

    # --- PTRレコード作成/更新 ---
    PTR_NAME=""
    REV_ZONE_URL=""
    generate_ptr_info "$VM_IP" PTR_NAME REV_ZONE_URL
    if [ $? -eq 0 ] && [ -n "$PTR_NAME" ] && [ -n "$REV_ZONE_URL" ]; then
        log "PTRレコード ($PTR_NAME -> $FQDN) を作成/更新します。"
        JSON_PAYLOAD_PTR=$(jq -n --arg name "$PTR_NAME" --arg type "PTR" --argjson ttl "$DEFAULT_TTL" --arg content "$FQDN" \
        '{rrsets: [{name: $name, type: $type, ttl: $ttl, changetype: "REPLACE", records: [{content: $content, disabled: false}]}]}')
        call_pdns_api "$REV_ZONE_URL" "$JSON_PAYLOAD_PTR" "PTR" "$PTR_NAME"
        PTR_RECORD_RESULT=$?
    else
        log "警告: PTRレコード情報の生成に失敗したため、PTRレコードの作成/更新をスキップします。"
        PTR_RECORD_RESULT=1 # 失敗扱い
    fi

    log "VM起動後処理を終了"
    # AまたはPTRのどちらかが失敗したらエラー終了とする場合
    if [ $A_RECORD_RESULT -ne 0 ] || [ $PTR_RECORD_RESULT -ne 0 ]; then
        exit 1 # エラーで終了
    fi

# --- VM停止前 または 削除前の処理 (レコード削除) ---
elif [ "$PHASE" == "pre-stop" ]; then
    log "VM停止前処理を開始 (レコード削除)"

    # FQDNが取得できていない場合はAレコード削除をスキップ
    if [ -z "$FQDN" ]; then
        log "警告: FQDNが不明なため、Aレコード削除をスキップします。"
    else
        # --- Aレコード削除 ---
        log "Aレコード ($FQDN) を削除します。"
        JSON_PAYLOAD_DELETE_A=$(jq -n --arg name "$FQDN" --arg type "A" \
        '{rrsets: [{name: $name, type: $type, changetype: "DELETE"}]}')
        call_pdns_api "$PDNS_API_URL_FWD" "$JSON_PAYLOAD_DELETE_A" "A" "$FQDN"
    fi

    # --- PTRレコード削除 ---
    CURRENT_IP=""
    IP_RECORD_FILE="${IP_RECORD_DIR}/${VMID}.ip"

    # 1. ★記録ファイルから読み込みを試みる
    if [ -f "$IP_RECORD_FILE" ]; then
        CURRENT_IP=$(cat "$IP_RECORD_FILE")
        # ファイルが空でないかもチェック
        if [ -n "$CURRENT_IP" ]; then
            log "記録ファイル $IP_RECORD_FILE からIPアドレス $CURRENT_IP を取得しました。"
        else
             log "警告: IP記録ファイル $IP_RECORD_FILE は存在しますが空です。"
             CURRENT_IP="" # 空の場合は後続の処理のために変数を空にする
        fi
    else
         log "IP記録ファイル $IP_RECORD_FILE が見つかりません。他の方法でIP特定を試みます。"
    fi

    # 2. (ファイルから取得できなかった場合のフォールバック) 静的IP設定
     if [ -z "$CURRENT_IP" ]; then
         log "静的IP設定からのIP取得を試みます..."
         # ip=192.168.1.100/24 形式を想定
         STATIC_IP_INFO=$(qm config $VMID | grep -E '^ip=' | head -n 1)
         if [[ "$STATIC_IP_INFO" =~ ip=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/[0-9]+ ]]; then
              CURRENT_IP="${BASH_REMATCH[1]}"
              log "静的IP設定からIPアドレス $CURRENT_IP を取得しました。"
         else
              log "静的IP設定は見つかりませんでした。"
         fi
     fi

    # IPアドレスが特定できたらPTR削除を試みる
    if [ -n "$CURRENT_IP" ]; then
        PTR_NAME=""
        REV_ZONE_URL=""
        generate_ptr_info "$CURRENT_IP" PTR_NAME REV_ZONE_URL
        if [ $? -eq 0 ] && [ -n "$PTR_NAME" ] && [ -n "$REV_ZONE_URL" ]; then
            log "PTRレコード ($PTR_NAME) を削除します。"
            JSON_PAYLOAD_DELETE_PTR=$(jq -n --arg name "$PTR_NAME" --arg type "PTR" \
            '{rrsets: [{name: $name, type: $type, changetype: "DELETE"}]}')
            call_pdns_api "$REV_ZONE_URL" "$JSON_PAYLOAD_DELETE_PTR" "PTR" "$PTR_NAME"
        else
             log "警告: IPアドレス $CURRENT_IP からPTR情報を生成できず、PTRレコード削除をスキップします。"
        fi
    else
        log "警告: VMのIPアドレスを特定できなかったため、PTRレコード削除をスキップします。"
    fi

    log "VM停止前処理を終了"

# --- VM停止後の処理 (IP記録ファイル削除) ---
elif [ "$PHASE" == "post-stop" ]; then
    log "VM停止後処理を開始 (IP記録ファイル削除)"
    IP_RECORD_FILE="${IP_RECORD_DIR}/${VMID}.ip"
    if [ -f "$IP_RECORD_FILE" ]; then
        rm -f "$IP_RECORD_FILE"
        if [ $? -eq 0 ]; then
            log "IP記録ファイル $IP_RECORD_FILE を削除しました。"
        else
            log "警告: IP記録ファイル $IP_RECORD_FILE の削除に失敗しました。"
        fi
    else
         log "IP記録ファイル $IP_RECORD_FILE は見つかりませんでした（すでに削除済みか記録なし）。"
    fi
    log "VM停止後処理を終了"

else
    log "未対応のフェーズ ($PHASE) のため、処理をスキップします。"
fi

log "スクリプト実行終了"
exit 0
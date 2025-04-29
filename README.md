# Terraform AWS CloudFront with EC2 Origin for GitLab

## 概要
このモジュールは、GitLabをAWS CloudFrontの背後にEC2インスタンスをオリジンとして配置するためのTerraformコードを提供します。これにより、GitLabをグローバルに配信するCDN構成を実現します。

## ⚠️ 現在のステータス: 開発進行中

このリポジトリには、AWS CloudFrontとEC2オリジンを使用してGitLabをデプロイするためのTerraformコードが含まれていますが、現時点では **開発中** です。

### 既知の問題
- **現在GitLabでの新規ユーザー作成ができません** - CSRF（クロスサイトリクエストフォージェリ）認証に失敗するため
- この問題は、CloudFrontのキャッシュ動作やヘッダー設定がGitLabの組み込みセキュリティメカニズムと干渉することが原因と考えられます

### 計画されている解決策
- CSRFトークンとフォーム送信を適切に処理するために、CloudFrontのキャッシュ設定やヘッダー転送設定を見直し、調整する

このリポジトリを使用または貢献する前に、この既知の制限事項を考慮してください。

## GitLab設定要件

AWS CloudFrontの背後にEC2オリジンでGitLabをホストするには、`/etc/gitlab/gitlab.rb`ファイルを以下の設定で編集する必要があります：

```ruby
external_url "{CloudFront URL}"
nginx['listen_port'] = 80
nginx['listen_https'] = false
letsencrypt['enable'] = false

nginx['proxy_set_headers'] = {
  "Host" => "{CloudFront Domain}",
  "X-Real-IP" => "$remote_addr",
  "X-Forwarded-For" => "$proxy_add_x_forwarded_for",
  "X-Forwarded-Proto" => "https",
  "X-Forwarded-Ssl" => "on",
  "Upgrade" => "$http_upgrade",
  "Connection" => "$connection_upgrade",
  "X-CSRF-Token" => "$http_x_csrf_token"
}
```

`{CloudFront URL}`と`{CloudFront Domain}`を実際のCloudFront配信URLとドメインに置き換えてください。

### 設定の適用

ファイルを編集した後、以下のコマンドを実行して設定変更を適用します：

```bash
gitlab-ctl reconfigure
gitlab-ctl restart
```

## 使い方

このモジュールを使用するには、以下の手順に従ってください：

1. このリポジトリをクローンする
2. 必要に応じて変数を設定する
3. `terraform init`、`terraform plan`、`terraform apply`を実行する

## 貢献方法

このプロジェクトへの貢献を歓迎します。特に、CSRFの認証に関する問題を解決するプルリクエストをお待ちしています。

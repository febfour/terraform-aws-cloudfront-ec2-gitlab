# Terraform AWS CloudFront with EC2 Origin for GitLab

## ⚠️ Current Status: Work in Progress

This repository contains Terraform code capable of deploying GitLab behind AWS CloudFront with EC2 origin; however, it is currently **incomplete**.

### Known Issue
- **Creating new users in GitLab is not possible at this time** due to failing CSRF (Cross-Site Request Forgery) authentication.
- This issue likely stems from caching behaviors or header settings in CloudFront that interfere with GitLab’s built-in security mechanisms.

### Planned Resolution
- Review and adjust CloudFront's cache settings or header-forwarding configuration to properly handle CSRF tokens and form submissions.

Please consider this known limitation before using or contributing to the repository.

## Required GitLab Configuration

To host GitLab behind AWS CloudFront with an EC2 origin, you must configure GitLab by editing the file `/etc/gitlab/gitlab.rb` with the following settings:

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

Replace `{CloudFront URL}` and `{CloudFront Domain}` with your actual CloudFront distribution URL and domain.

### Applying Configuration

After editing the file, apply the configuration changes by running:

```bash
gitlab-ctl reconfigure
gitlab-ctl restart
```

## Known Issues

There is a known issue related to CSRF authentication when using GitLab behind CloudFront. Contributions via pull requests to resolve this issue are welcome.


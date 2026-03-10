# AWS Lightsail Bitnami Deployment Guide

Deploy a **Node.js**, **React**, or **Next.js** site from GitHub to a Bitnami
instance on AWS Lightsail — with HTTPS, an Apache reverse proxy, and
auto-restart on reboot — using just a handful of commands from the AWS
browser-based SSH console.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Quick Start (3 commands)](#3-quick-start-3-commands)
4. [Step-by-Step Guide](#4-step-by-step-guide)
   - [4.1 Launch a Lightsail Instance](#41-launch-a-lightsail-instance)
   - [4.2 Open Firewall Ports](#42-open-firewall-ports)
   - [4.3 Point Your Domain to Lightsail](#43-point-your-domain-to-lightsail)
   - [4.4 Connect via the AWS SSH Console](#44-connect-via-the-aws-ssh-console)
   - [4.5 Clone This Repository](#45-clone-this-repository)
   - [4.6 Run the Setup Wizard](#46-run-the-setup-wizard)
   - [4.7 Verify Your Deployment](#47-verify-your-deployment)
5. [Script Reference](#5-script-reference)
6. [What the Setup Wizard Does](#6-what-the-setup-wizard-does)
   - [GitHub Deployment (public & private)](#github-deployment-public--private)
   - [Node.js / Express Apps](#nodejs--express-apps)
   - [React Static Sites](#react-static-sites)
   - [Next.js Apps](#nextjs-apps)
   - [SSL with Let's Encrypt](#ssl-with-lets-encrypt)
   - [Apache Reverse Proxy](#apache-reverse-proxy)
   - [Auto-restart on Reboot (PM2)](#auto-restart-on-reboot-pm2)
   - [SSL Backup to S3](#ssl-backup-to-s3)
7. [Updating Your Site](#7-updating-your-site)
8. [Troubleshooting](#8-troubleshooting)
9. [FAQ](#9-faq)

---

## 1. Overview

This repository provides an **interactive setup wizard** and a set of helper
scripts that automate the common tasks of hosting a JavaScript web application
on a Bitnami-powered AWS Lightsail instance:

| Task | Script |
|------|--------|
| Clone repo, install deps, build, start with PM2 | `scripts/deploy.sh` |
| SSL certificate (Let's Encrypt) + Apache reverse proxy | `scripts/ssl-proxy-setup.sh` |
| PM2 auto-start on server reboot | `scripts/pm2-autorun.sh` |
| Back up SSL certificate to S3 | `scripts/ssl-backup-s3.sh` |
| Pull latest code and redeploy | `scripts/update.sh` |
| **All of the above in one interactive wizard** | `scripts/setup.sh` ✅ |

**Designed for users who:**
- Have a tested Node.js / React / Next.js app in a GitHub repository
- Want HTTPS on a custom domain
- Are connecting to their server via the AWS Lightsail browser SSH console
- Want the whole process automated with minimal manual steps

---

## 2. Prerequisites

### AWS Lightsail Instance

- A running **Bitnami Node.js** Lightsail instance (recommended) **or**
  a Bitnami LAMP instance with Node.js installed.
- The instance must have at least **1 GB RAM** (2 GB recommended for Next.js
  builds).

### Domain Name

- A domain name you control, with the ability to update its DNS records.
- The domain's **A record** must point to your Lightsail static IP _before_
  running the SSL setup step (DNS changes can take up to 30 minutes to
  propagate).

### GitHub Repository

- Your JavaScript project is in a GitHub repository (public or private).
- The app has been tested locally.
- For **private** repositories: a GitHub **Personal Access Token** (classic)
  with `repo` scope. Generate one at
  <https://github.com/settings/tokens>.

### Firewall Ports

The following ports must be open in the Lightsail firewall (configured in the
next step):

| Port | Protocol | Purpose |
|------|----------|---------|
| 22   | TCP | SSH |
| 80   | TCP | HTTP (Let's Encrypt challenge + redirect to HTTPS) |
| 443  | TCP | HTTPS |

---

## 3. Quick Start (3 commands)

After connecting to your Lightsail instance via SSH, run:

```bash
# 1. Clone this guide repository
git clone https://github.com/papaknee/AWS-Lightsail-Simple-Birman-GitHub-Host.git

# 2. Make the scripts executable
chmod +x AWS-Lightsail-Simple-Birman-GitHub-Host/scripts/*.sh

# 3. Launch the interactive setup wizard
~/AWS-Lightsail-Simple-Birman-GitHub-Host/scripts/setup.sh
```

The wizard will ask you a series of questions and handle everything else
automatically.

---

## 4. Step-by-Step Guide

### 4.1 Launch a Lightsail Instance

1. Sign in to the [AWS Lightsail console](https://lightsail.aws.amazon.com/).
2. Click **Create instance**.
3. Choose a region close to your users.
4. Under **Select a blueprint**, choose **Apps and CMS** → **Node.js**
   (powered by Bitnami).
   - If you need a database, choose LAMP instead and install Node.js manually.
5. Choose an instance plan. For Next.js or Express apps, **2 GB RAM** ($10/mo)
   or higher is recommended. React static sites run fine on the $5/mo plan.
6. Give the instance a name and click **Create instance**.
7. Wait about 60 seconds for the instance to reach the **Running** state.
8. **Assign a Static IP**: In the Lightsail console, go to
   **Networking** → **Create static IP** and attach it to your new instance.
   This ensures your domain stays pointed at the same IP even if the instance
   is restarted.

### 4.2 Open Firewall Ports

1. Click on your instance name in the Lightsail console.
2. Go to the **Networking** tab.
3. Under **IPv4 Firewall**, click **Add rule** and add:
   - **HTTP** (port 80) — source: Any
   - **HTTPS** (port 443) — source: Any
4. Click **Save**.

> **Note:** If you are only testing with IP access and no domain, you can
> optionally add a custom TCP rule for your app port (e.g., port 3000).

### 4.3 Point Your Domain to Lightsail

1. Log in to your domain registrar or DNS provider.
2. Find the DNS settings for your domain.
3. Add (or update) the following records:

   | Type | Host | Value | TTL |
   |------|------|-------|-----|
   | A    | `@` (or blank) | `<Your Lightsail Static IP>` | 300 |
   | A    | `www`          | `<Your Lightsail Static IP>` | 300 |

4. Save the changes and wait 5–30 minutes for DNS to propagate.
5. Verify with: `nslookup yourdomain.com` or `dig yourdomain.com`

> **Important:** DNS must resolve to your server's IP _before_ running the SSL
> setup, because Let's Encrypt verifies domain ownership over HTTP.

### 4.4 Connect via the AWS SSH Console

1. Go to the [Lightsail console](https://lightsail.aws.amazon.com/).
2. Click the **three dots (⋮)** menu next to your instance.
3. Choose **Connect using SSH**.
4. A browser-based SSH terminal opens. You are logged in as the `bitnami` user.

Alternatively, you can connect from your local terminal:
```bash
ssh -i ~/.ssh/LightsailDefaultKey.pem bitnami@<Your-Static-IP>
```

### 4.5 Clone This Repository

In the SSH terminal, run:

```bash
git clone https://github.com/papaknee/AWS-Lightsail-Simple-Birman-GitHub-Host.git
chmod +x AWS-Lightsail-Simple-Birman-GitHub-Host/scripts/*.sh
```

### 4.6 Run the Setup Wizard

```bash
~/AWS-Lightsail-Simple-Birman-GitHub-Host/scripts/setup.sh
```

The wizard will prompt you for:

| Prompt | Example | Notes |
|--------|---------|-------|
| App name | `my-portfolio` | Used as directory name and PM2 process name. Letters, numbers, hyphens only. |
| GitHub repository URL | `https://github.com/alice/portfolio.git` | Use the HTTPS clone URL. |
| Private repo? | `y` or `n` | If yes, you'll be asked for your GitHub token. |
| App type | `1` (Node.js), `2` (React), `3` (Next.js) | Determines how the app is built and served. |
| Port | `3000` | The port your Node.js / Next.js app listens on. Not needed for React static sites. |
| Start command | `npm start` | How PM2 starts your app. Leave blank to use `npm start`. |
| Domain name | `example.com` | Leave blank to skip SSL setup (IP-only access). |
| S3 bucket | `my-ssl-backups` | Optional. Leave blank to skip the S3 backup step. |

After answering the prompts, confirm your settings and the wizard runs
automatically.

#### During SSL setup

The wizard calls `bncert-tool` — Bitnami's built-in Let's Encrypt certificate
tool. It is interactive and will ask you:

1. **Domain list** — enter `example.com www.example.com` (space-separated)
2. **Email address** — for certificate renewal notifications
3. **Enable HTTP→HTTPS redirect?** — choose **Y**
4. **Enable non-www→www redirect?** — choose based on your preference
5. **Agree to Terms of Service?** — choose **Y**
6. **Agree to update Apache config?** — choose **Y**

Once `bncert-tool` finishes, the setup wizard automatically adds the reverse
proxy configuration to Apache (for Node.js and Next.js apps).

### 4.7 Verify Your Deployment

After the wizard completes:

```bash
# Check that your PM2 process is running
pm2 list

# View live application logs
pm2 logs my-portfolio

# Check Apache status
sudo /opt/bitnami/ctlscript.sh status apache

# View Apache error log
sudo tail -30 /opt/bitnami/apache/logs/error_log
```

Open your browser and visit `https://yourdomain.com`. You should see your site
with a valid SSL certificate (green padlock).

---

## 5. Script Reference

All scripts live in the `scripts/` directory and accept a `--config` flag to
load settings from `~/.birman/.env` (created automatically by `setup.sh`).

### `scripts/setup.sh` — Interactive Setup Wizard

The main entry point. Runs all other scripts in the correct order.

```bash
./scripts/setup.sh
```

### `scripts/deploy.sh` — Deploy from GitHub

Clones or updates the repository, installs dependencies, builds the app, and
starts/restarts it with PM2.

```bash
./scripts/deploy.sh --config ~/.birman/.env
```

What it does per app type:

| App type | Build step | Serve method |
|----------|------------|-------------|
| `nodejs` | `npm run build` (if a build script exists) | PM2 starts the Node server |
| `react`  | `npm run build` | Static files copied to Apache htdocs |
| `nextjs` | `npm run build` | PM2 starts `npm start` (Next.js server) |

### `scripts/ssl-proxy-setup.sh` — SSL + Apache Reverse Proxy

Guides you through running `bncert-tool` (Let's Encrypt), then configures
Apache to proxy HTTPS traffic to your Node.js application.

```bash
./scripts/ssl-proxy-setup.sh --config ~/.birman/.env
```

The generated Apache vhost configuration (`/opt/bitnami/apache/conf/vhosts/<app>-proxy.conf`):
- Redirects HTTP → HTTPS (301)
- Terminates SSL at Apache
- Forwards all requests to `http://localhost:<PORT>`
- Supports WebSockets (for Next.js HMR, Socket.io, etc.)
- Adds security headers (HSTS, X-Frame-Options, etc.)

### `scripts/pm2-autorun.sh` — Auto-start on Reboot

Configures PM2 to automatically start your application when the server boots.

```bash
./scripts/pm2-autorun.sh --config ~/.birman/.env
```

### `scripts/ssl-backup-s3.sh` — Back Up SSL Certificates to S3

Installs the AWS CLI (if not present), prompts for AWS credentials, and uploads
your SSL certificates to the specified S3 bucket.

```bash
./scripts/ssl-backup-s3.sh --config ~/.birman/.env
```

The backup is a `.tar.gz` archive stored at:
```
s3://<bucket>/ssl-backups/<domain>/<domain>-ssl-backup-<timestamp>.tar.gz
```

You can optionally schedule automatic weekly backups via cron.

**Required IAM permissions for the upload:**
```json
{
  "Effect": "Allow",
  "Action": ["s3:PutObject", "s3:GetObject"],
  "Resource": "arn:aws:s3:::<your-bucket>/ssl-backups/*"
}
```

### `scripts/update.sh` — Pull Latest Code and Redeploy

Re-runs `deploy.sh` to pull the newest commit from GitHub and restart the app.

```bash
./scripts/update.sh
```

---

## 6. What the Setup Wizard Does

### GitHub Deployment (public & private)

**Public repos** are cloned with the standard HTTPS URL:
```
https://github.com/username/repo.git
```

**Private repos** use a Personal Access Token embedded in the clone URL:
```
https://<TOKEN>@github.com/username/repo.git
```

The token is stored in `~/.birman/.env` (permissions `600`, readable only by
the `bitnami` user). It is never printed to the terminal.

After the initial clone, subsequent `update.sh` runs do a `git fetch` + `git
reset --hard origin/HEAD` to ensure the deployed code exactly matches the
GitHub repository's default branch.

### Node.js / Express Apps

- The app is expected to start with `npm start` (or a custom command you
  specify).
- It should listen on the port you provide (default: `3000`).
- The app **must not** attempt to bind to port 80 or 443 — Apache handles
  those ports and proxies traffic to your app port.

Example `package.json` start script:
```json
"scripts": {
  "start": "node server.js"
}
```

Example minimal Express server:
```js
const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

app.get('/', (req, res) => res.send('Hello from Lightsail!'));
app.listen(PORT, () => console.log(`Listening on port ${PORT}`));
```

### React Static Sites

React apps built with **Create React App** or **Vite** produce static HTML/CSS/JS
files. The setup wizard:

1. Runs `npm run build`
2. Copies the output (`build/` or `dist/`) to the Apache document root at
   `/opt/bitnami/apache/htdocs/`
3. Restarts Apache

No Node.js server process is needed after deployment. Apache serves the files
directly.

> **Client-side routing:** If your React app uses React Router, you'll need an
> Apache `.htaccess` file in the `public/` folder of your project to redirect
> all routes to `index.html`:
> ```apache
> Options -MultiViews
> RewriteEngine On
> RewriteCond %{REQUEST_FILENAME} !-f
> RewriteRule ^ index.html [QSA,L]
> ```

### Next.js Apps

Next.js apps are run as a Node.js server (for SSR, ISR, and API routes).
The setup wizard:

1. Runs `npm run build` (Next.js build)
2. Starts the app with PM2 using `npm start` (which runs `next start`)
3. Configures Apache to proxy requests to the Next.js server

Make sure your `package.json` includes:
```json
"scripts": {
  "build": "next build",
  "start": "next start -p 3000"
}
```

> **Next.js static export:** If your Next.js app uses `next export` (fully
> static output), change the app type to `react` in the wizard — the build
> output will be served by Apache directly.

### SSL with Let's Encrypt

[`bncert-tool`](https://docs.bitnami.com/aws/how-to/generate-install-lets-encrypt-ssl/) is
Bitnami's recommended way to obtain and install Let's Encrypt certificates. It:

- Requests a certificate from Let's Encrypt
- Installs it into Apache's configuration
- Sets up automatic certificate renewal (certificates expire every 90 days
  and are renewed automatically)

You can check renewal status with:
```bash
sudo /opt/bitnami/bncert-tool
# Choose option: "Check certificate status"
```

### Apache Reverse Proxy

The SSL proxy setup creates an Apache vhost configuration file at:
```
/opt/bitnami/apache/conf/vhosts/<app-name>-proxy.conf
```

Key features of the generated config:

- **HTTP → HTTPS redirect** (301 permanent redirect)
- **SSL termination** at Apache using the Let's Encrypt certificate
- **Reverse proxy** from Apache to `http://localhost:<PORT>`
- **WebSocket support** via Apache's `RewriteRule` with `[P]` flag
- **Security headers:**
  - `Strict-Transport-Security` (HSTS) — enforces HTTPS for 2 years
  - `X-Frame-Options: SAMEORIGIN` — prevents clickjacking
  - `X-Content-Type-Options: nosniff` — prevents MIME type sniffing
  - `X-XSS-Protection` — enables browser XSS filtering

### Auto-restart on Reboot (PM2)

[PM2](https://pm2.keymetrics.io/) is a Node.js process manager that keeps your
app running and restarts it if it crashes.

After `pm2-autorun.sh` runs:
- PM2 is registered as a **systemd service**
- On every reboot, systemd starts PM2, which starts your application

Useful PM2 commands:
```bash
pm2 list                    # Show all running processes
pm2 logs my-app             # Stream logs (Ctrl+C to stop)
pm2 logs my-app --lines 100 # Show last 100 lines of logs
pm2 restart my-app          # Restart the process
pm2 stop my-app             # Stop the process
pm2 delete my-app           # Remove from PM2 list
pm2 monit                   # Interactive process monitor
```

### SSL Backup to S3

The `ssl-backup-s3.sh` script creates a timestamped `.tar.gz` archive of your
SSL certificate files and uploads it to Amazon S3 using server-side encryption
(SSE-KMS).

To **restore** a backup:
1. Download the archive from S3: `aws s3 cp s3://<bucket>/ssl-backups/... ./`
2. Extract: `tar -xzf <archive>.tar.gz`
3. Copy the files back to the original certificate location
4. Restart Apache: `sudo /opt/bitnami/ctlscript.sh restart apache`

---

## 7. Updating Your Site

Whenever you push new code to your GitHub repository, SSH into the server and run:

```bash
~/AWS-Lightsail-Simple-Birman-GitHub-Host/scripts/update.sh
```

This:
1. Runs `git fetch` + `git reset --hard origin/HEAD`
2. Runs `npm ci` to install any new dependencies
3. Rebuilds the app if applicable
4. Restarts the PM2 process (or re-syncs static files for React)

> **Zero-downtime deployments:** The default setup does a direct restart. If
> you need zero-downtime deployments, consider using `pm2 reload my-app`
> instead of `pm2 restart` in the update script (works for cluster mode).

---

## 8. Troubleshooting

### "DNS mismatch" warning during SSL setup

Your domain's A record doesn't point to this server yet.
- Check your DNS settings at your registrar.
- Verify with: `dig +short yourdomain.com`
- DNS changes can take up to 30 minutes. Wait and retry.

### bncert-tool fails with "Domain validation failed"

- Confirm port 80 is open in the Lightsail firewall (Networking tab).
- Confirm your domain resolves to the server IP: `dig +short yourdomain.com`
- Let's Encrypt rate-limits failed attempts. If you've tried many times,
  wait an hour before retrying.

### App crashes after deployment

View the PM2 logs to see the error:
```bash
pm2 logs my-app --lines 200
```

Common causes:
- Missing environment variables. Create a `.env` file in your app directory
  (`~/apps/my-app/.env`) and restart: `pm2 restart my-app`
- Wrong port. Make sure your app listens on the port you specified (default `3000`).
- Missing dependencies. Run `cd ~/apps/my-app && npm install`

### Apache returns 502 Bad Gateway

Your Node.js / Next.js app is not running or not listening on the expected port.
```bash
pm2 list                     # Is the process running?
pm2 logs my-app              # Any error messages?
curl http://localhost:3000   # Does the app respond locally?
```

### HTTPS shows a certificate error

- The SSL certificate may not yet be installed. Re-run:
  ```bash
  ~/AWS-Lightsail-Simple-Birman-GitHub-Host/scripts/ssl-proxy-setup.sh
  ```
- If you recently pointed your domain at this server, the old cert (if any)
  may still be cached by your browser. Try an incognito window.

### React app shows a blank page after deployment

- Open browser DevTools → Console. Usually this is a missing `homepage` field
  in `package.json` or a routing issue.
- Add to `package.json`:
  ```json
  "homepage": "/"
  ```
  Then re-run `update.sh`.

### Permission denied errors in scripts

Make the scripts executable:
```bash
chmod +x ~/AWS-Lightsail-Simple-Birman-GitHub-Host/scripts/*.sh
```

---

## 9. FAQ

**Q: Can I use a private GitHub repository?**

Yes. When the setup wizard asks "Is this a private repository?", enter `y`
and provide a GitHub Personal Access Token with `repo` scope. The token is
stored securely in `~/.birman/.env` (readable only by you).

**Q: Can I deploy multiple apps on the same server?**

Yes. Run `setup.sh` again with a different app name and a different port
(e.g., `3001`). Each app gets its own PM2 process and Apache vhost config.
However, each domain's SSL certificate must be obtained separately via
`bncert-tool`.

**Q: How do I set environment variables for my app?**

Create a `.env` file in your app directory:
```bash
nano ~/apps/my-app/.env
```
Add your variables:
```
DATABASE_URL=mongodb+srv://...
API_KEY=abc123
NODE_ENV=production
```
Then restart: `pm2 restart my-app`

For Next.js, prefix public variables with `NEXT_PUBLIC_`.

**Q: How does Let's Encrypt auto-renewal work?**

`bncert-tool` sets up a cron job that attempts renewal every day. Certificates
are renewed when they have less than 30 days until expiry (they are valid for
90 days). You don't need to do anything.

Check renewal status:
```bash
sudo /opt/bitnami/bncert-tool
```

**Q: What happens to my SSL cert if the server is replaced?**

Use `ssl-backup-s3.sh` to back up the certificate to S3 before replacing the
server. After setting up the new server and running `bncert-tool`, you can
also simply obtain a new certificate — Let's Encrypt is free and the process
takes seconds.

**Q: My app uses a database. How do I connect to it?**

If you're using an AWS RDS or Lightsail database, add the connection string as
an environment variable (see the environment variables FAQ above). Make sure
the database is in the same AWS region and that the Lightsail instance's IP is
allowed in the database's firewall/security group.

**Q: Can I use a custom Node.js version?**

Bitnami instances come with a specific Node.js version pre-installed. To
install a different version, use [nvm](https://github.com/nvm-sh/nvm):
```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.bashrc
nvm install 20
nvm use 20
nvm alias default 20
```
After switching versions, restart PM2: `pm2 restart all`

**Q: How do I view the Apache configuration created by the setup wizard?**

```bash
sudo cat /opt/bitnami/apache/conf/vhosts/my-app-proxy.conf
```

---

## License

[MIT](LICENSE)
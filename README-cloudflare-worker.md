# Cloudflare Worker Scripts

JavaScript Cloudflare Workers for **email routing** — processing incoming email on domains configured with Cloudflare Email Routing. Each worker handles both HTTP browser requests (status page) and SMTP email delivery.

---

## 📋 Workers

### [`worker-bounce-unknown-and-administrative.js`](worker-bounce-unknown-and-administrative.js)
**Strategy:** Known-aliases-only — **reject everything else**.

| Aspect | Detail |
|--------|--------|
| **Security/Admin aliases** | `abuse`, `admin`, `administrator`, `hostmaster`, `noc`, `postmaster`, `security`, `webmaster` |
| **Route for known aliases** | Forwards to a security inbox (`security@example.com`) |
| **Route for unknown addresses** | Rejects with a trilingual (EN/PT/ES) bounce message directing the sender to a contact inbox |
| **HTTP handler** | Returns a styled HTML status page: "Global Email Router — System Operational" |

**Use case:** When you want a domain to **only accept email for standard administrative addresses** and actively reject all other recipients.

---

### [`worker-catch-all-and-administrative.js`](worker-catch-all-and-administrative.js)
**Strategy:** Administrative routing + **catch-all for everything else**.

| Aspect | Detail |
|--------|--------|
| **Security/Admin aliases** | `abuse`, `admin`, `administrator`, `hostmaster`, `noc`, `postmaster`, `security`, `webmaster` |
| **Route for known aliases** | Forwards to a security inbox (`security@example.com`) |
| **Route for unknown addresses** | Catch-all: forwards to a general inbox (`email+catch-all@example.com`) |
| **HTTP handler** | Returns a styled HTML status page: "Global Email Catch-All Router — System Operational" |

**Use case:** When you want a domain to **accept all email** but still separate security/administrative messages from general correspondence.

---

## 🔧 Deployment

1. **Via Cloudflare Dashboard:**
   - Go to **Workers & Pages** → Create Worker.
   - Paste the script content.
   - Deploy and bind to your domain's Email Routing configuration.

2. **Via Wrangler CLI:**
   ```bash
   npx wrangler deploy
   ```

3. **Configure Email Routing:**
   - In Cloudflare Dashboard, go to your domain → **Email** → **Email Routing**.
   - Set the worker as the destination for your domain's email routes.

---

## ⚙️ Customization

Before deploying, update the inbox addresses in the script:

| Variable | In file | Purpose |
|----------|---------|---------|
| `securityInbox` | Both workers | Destination for administrative/security emails |
| `contactInbox` | `worker-bounce-unknown-and-administrative.js` | Address shown in bounce messages for sender recourse |
| `generalInbox` | `worker-catch-all-and-administrative.js` | Destination for all non-admin catch-all emails |

The set of security aliases is defined in the `securityAliases` Set and can be modified as needed.

---

<!-- footer -->
---

## 🧑‍💻 Consulting and technical support

- For personal support and queries, please submit a new issue to have it addressed.
- For commercial related questions, please [**contact me**][ivancarlos] for consulting costs.

| 🩷 Project support |
| :---: |
| If you found this project helpful, consider [**buying me a coffee**][buymeacoffee] |
| Thanks for your support, it is much appreciated! |

[ivancarlos]: https://ivancarlos.me
[buymeacoffee]: https://www.buymeacoffee.com/ivancarlos

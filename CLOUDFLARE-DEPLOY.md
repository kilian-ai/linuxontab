# Deploy LinuxOnTab to Cloudflare Pages

This fork has a dedicated \`cloudflare-deploy\` branch. The original \`main\` branch is left unchanged.

## What the deployment does

- Builds the current static site into \`dist/\`.
- Runs a Pages Function on every request, including HTML, JavaScript, WebAssembly and static assets.
- Requires a signed, HTTP-only session cookie before serving the site.
- Keeps the 50 MB Alpine ISO and package archives out of the Pages bundle. The Function streams those files from this public repository's \`main\` branch after authentication.
- Keeps the existing LinuxOnTab frontend and its current upstream networking endpoints.

The legacy \`2.0/\` page and bulk package archives are not copied into the Pages build. Package files remain available through the authenticated \`/packages/\` route.

**Important:** the GitHub repository is public. This password gate protects the deployed website, but it does not make public GitHub source files private. Anyone can still browse or download files from the public repository directly.

## 1. Create the Pages project

1. Open Cloudflare Dashboard → **Workers & Pages** → **Create** → **Pages** → **Connect to Git**.
2. Select \`akkk09/linuxontab\`.
3. Set the production branch to \`cloudflare-deploy\`.
4. Set the build command to:

   \`\`\`sh
   bash cloudflare-build.sh
   \`\`\`

5. Set the build output directory to \`dist\`.
6. Leave the root directory blank (repository root), then save and deploy.

## 2. Add the authentication secrets

Open the Pages project → **Settings** → **Variables and Secrets**. Add these as **encrypted secrets** for the Production environment:

| Name | Value |
|---|---|
| `AUTH_USERNAME` | The username you want to use |
| `AUTH_PASSWORD_HASH` | A salted PBKDF2-SHA256 hash (instructions below) |
| `SESSION_SECRET` | A random secret of at least 32 characters |

Generate a session secret on Linux:

```sh
openssl rand -base64 48
```

Generate a password hash on Linux with Python 3. This prompts for the password without echoing it, then prints a salted PBKDF2-SHA256 hash:

```sh
python3 - <<'PY'
import getpass, hashlib, secrets
password = getpass.getpass("Password to protect LinuxOnTab: ")
salt = secrets.token_bytes(16)
iterations = 310_000
derived = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
print(f"pbkdf2-sha256${iterations}${salt.hex()}${derived.hex()}")
PY
```

Copy the full output into the `AUTH_PASSWORD_HASH` secret. Keep `AUTH_USERNAME` as your chosen username, stored as an encrypted Cloudflare Secret. Do not put the plaintext password or hash in GitHub, source files, or chat. After adding or changing secrets, trigger a new deployment. The hash uses a random salt and 310,000 PBKDF2-SHA256 iterations.

If you use Preview deployments, add the same secrets to the Preview environment only if you want previews to require the same login.

## 3. Add login rate limiting

In Cloudflare Security → WAF → Rate limiting rules, add a rule for:
- URI path equals \`/__auth/login\`
- HTTP method equals \`POST\`
- A low request threshold, such as 5 requests per minute per IP, then block for a short period.

This reduces password-guessing attempts. The Pages Function also checks the request origin and checks the username in constant time and verifies the password with salted PBKDF2-SHA256.

## 4. Optional custom domain

In the Pages project → **Custom domains**, add a domain you control and follow Cloudflare's DNS prompts. Do not use the upstream project's \`linuxontab.com\` domain unless you own it.

## 5. Networking note

The browser VM itself runs on each visitor's device. This Pages deployment does not create a cloud Linux server. The current frontend still points to the upstream LinuxOnTab networking/relay services. Deploying your own relay and port-tunnel backends is a separate step.

## Local build check

On Arch Linux:

\`\`\`sh
bash cloudflare-build.sh
\`\`\`

The result is written to \`dist/\`. The build fails if any copied file exceeds Cloudflare Pages' 25 MiB per-file limit.

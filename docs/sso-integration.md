# Hermes SSO with standalone Authelia

`kube.hermes_setup` supports native `external-oidc` login for Dashboard and WebUI.
It does **not** install or manage Authelia. Use
[kube.authelia_setup](https://github.com/Tuxbull-Open-Source/kube.authelia_setup)
for the provider in its own namespace; Hermes stays in its own namespace.
The browser redirects from Hermes to Authelia and returns to the application's
callback. Do not add forward-auth middleware to implement this native OIDC flow.

## 1. Prepare the provider

Follow the provider's [quickstart](https://github.com/Tuxbull-Open-Source/kube.authelia_setup#configure--install--maintain--doctor)
and [OIDC guide](https://github.com/Tuxbull-Open-Source/kube.authelia_setup/blob/main/docs/oidc.md).
That repository owns configure/install/maintain/doctor, LDAP and SMTP trust,
provider Secrets and SQLite storage. It does not provision LDAP, SMTP, DNS,
public TLS certificates, an ingress controller or Velero. Supply working HTTPS
for all three public hosts before cutover. The provider Ingress routes traffic;
it does not provision HTTPS. LDAP/SMTP CA trust is separate from public TLS.

In its configurator, use `https://sso.app.example.com` as the portal URL and
`app.example.com` as its cookie domain. Keep `protected_domain` empty for
OIDC-only operation. Supply these two JSON files at the OIDC registry prompts
(or merge their values into `oidc_clients` and `oidc_policies` in your existing
private provider config; preserve unrelated clients/policies):

**Clients:**

```json
[
  {
    "client_id": "hermes-dashboard",
    "client_name": "Hermes Dashboard",
    "redirect_uris": ["https://dashboard.app.example.com/auth/callback"],
    "authorization_policy": "hermes_users",
    "require_pkce": true
  },
  {
    "client_id": "hermes-webui",
    "client_name": "Hermes WebUI",
    "redirect_uris": ["https://webui.app.example.com/api/auth/oidc/callback"],
    "authorization_policy": "hermes_users",
    "require_pkce": true
  }
]
```

**Policies:**

```json
{"hermes_users": {"group": "sysadmins", "policy": "two_factor"}}
```

Replace `sysadmins` with the LDAP group allowed to operate Hermes. All admitted
Dashboard users act as the machine owner, not isolated tenants. `two_factor`
requires Authelia MFA enrollment; it does not automatically reuse a FreeIPA OTP
token. `one_factor` is an explicit MFA opt-down, not a claim of LDAP MFA.
Both current upstream consumers support public authorization-code + PKCE S256;
keep `require_pkce: true`. No client secret is needed. Older/custom images must
be checked before cutover; disabling PKCE is a security downgrade, not a default.

## 2. Configure Hermes (and resolve the WebUI claim gate)

Run `./configure.sh --no-install` in **kube.hermes_setup**, select
`external-oidc`, and enable the desired UI components. Review the resulting
`current_config/hermes.env` before running the installer. For an existing install,
edit its active env file instead; preserve namespace, storage, images and other
settings. These are installer env settings, not edits to runtime `config.yaml`:

```dotenv
HERMES_AUTH_MODE=external-oidc
HERMES_DASHBOARD_ENABLED=true
HERMES_WEBUI_ENABLED=true
DASHBOARD_HOST=dashboard.app.example.com
WEBUI_HOST=webui.app.example.com
HERMES_OIDC_ISSUER=https://sso.app.example.com
HERMES_DASHBOARD_OIDC_CLIENT_ID=hermes-dashboard
HERMES_DASHBOARD_PUBLIC_URL=https://dashboard.app.example.com
HERMES_DASHBOARD_OIDC_SCOPES="openid profile email groups"
HERMES_WEBUI_OIDC_CLIENT_ID=hermes-webui
HERMES_WEBUI_OIDC_REDIRECT_URI=https://webui.app.example.com/api/auth/oidc/callback
HERMES_WEBUI_OIDC_SCOPES="openid profile email groups"
HERMES_WEBUI_OIDC_ALLOW_CLAIM=sub
HERMES_WEBUI_OIDC_ALLOW_VALUES=CHANGE_ME_VERIFIED_WEBUI_SUB
```

**Do not install this placeholder unchanged.** Current WebUI checks its allow-list
against the validated **ID token**, not userinfo. Authelia normally puts `groups`
and `email` in userinfo; asking for those scopes does not put them in the ID token.
The standalone provider's current schema has no `claims_policy` input. Thus the
wizard's `groups` allow-list is **not a working drop-in combination** with that
provider's default tokens.

A supported narrow alternative is `sub`: replace the placeholder with the exact
subject of each approved user for the **hermes-webui client**, comma-separated.
Obtain these through a trusted administrator's validated OIDC authorization-code
flow for that client (issuer, audience, signature and nonce verified); do not use
LDAP usernames, guess UUIDs, copy a different client's subject, or share tokens.
The provider's group policy still gates authorization, and WebUI further restricts
the admitted subjects. If you cannot obtain verified subjects, leave WebUI
cutover **blocked** (or keep it disabled while validating Dashboard).
Group-based WebUI admission requires a separately reviewed provider claims-policy
feature or WebUI userinfo support; do not invent installer options or patch live
ConfigMaps as a durable workaround.

Remove stale per-UI issuer overrides from the active env file, or set them to the
same issuer. HTTPS origins/callbacks must match the registered URLs exactly.
Ensure the chosen images implement native OIDC and that persistent runtime
configuration does not retain alternative password providers. Never put LDAP
passwords, provider signing keys, OTP seeds or tokens in `hermes.env`.

## 3. Cut over and verify

After provider readiness and the claim gate above are satisfied, run from the
Hermes repository on your authorized operator machine:

```bash
ENV_FILE=./current_config/hermes.env ./install.sh
ENV_FILE=./current_config/hermes.env ./doctor.sh
```

Use the actual active env path for a non-wizard installation. The installer
renders OIDC env values, omits local password env references, and removes the old
shared password Secret only after successful OIDC workload rollouts. It preserves
the internal Agent API key and Browserless token; SSO does not replace them.
`disabled` and `external-proxy` are not implemented authentication modes.

Before declaring success, use a real browser to test both exact callbacks, valid
and invalid credentials, non-member denial, subject allow-list denial, MFA,
WebUI chat/WebSockets, logout and expiry. Confirm there is no unintended local
password or direct-Service bypass, then rerun the installer and repeat login.
Doctor checks configuration drift; it does not prove browser login or MFA.
See the [QA contract](qa.md). No production or live-browser acceptance is implied
by these source-checked instructions.

## Lifetimes and operational boundaries

- `HERMES_AUTH_SESSION_MAX_TTL_SECONDS` (default `43200`) maps to
  `HERMES_WEBUI_SESSION_TTL`; existing sessions retain their original expiry.
- `HERMES_AUTH_SESSION_IDLE_TTL_SECONDS` (default `7200`) does **not** enforce
  application idle expiry or configure the external provider. Set the provider's
  `session_idle` / `session_max` separately (defaults `2h` / `12h`, remember-me off).
- Dashboard ID-token lifetime is provider-controlled, not a guaranteed 12-hour
  application session. The standalone provider currently exposes no ID-token
  lifespan setting. Do not infer token lifetime from its SSO cookie lifetime.
- Authelia logout does not revoke independent, already-issued application
  sessions. Validate each application's logout/expiry behavior with your images.
- Hermes [operations](operations.md) and [security](security.md) remain authoritative
  for this stack. Provider maintenance, CA trust and recovery belong to the
  [standalone runbook](https://github.com/Tuxbull-Open-Source/kube.authelia_setup/blob/main/docs/operations.md).
  A Hermes backup does not back up the provider's namespace, PVC or signing keys.

## Consumer references

- [Dashboard OIDC configuration and ownership warning](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard/#self-hosted-oidc-provider).
- [WebUI ID-token allow-list and PKCE implementation](https://github.com/nesquena/hermes-webui/blob/eccc701b9acc73559d76a1baafc6142fd69d9dd6/api/auth_oidc.py).
- [Authelia claims placement and compatibility](https://www.authelia.com/integration/openid-connect/openid-connect-1.0-claims/).

This replaces the former FreeIPA-specific deployment/QA manuals; provider setup
procedures now live in `kube.authelia_setup`, not in this application installer.

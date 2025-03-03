# OAuth Authentication Configuration Guide

## Overview

OAuth 2.0 is an industry-standard protocol for authorization that enables third-party applications to obtain limited access to a user account. This guide explains how to configure OAuth authentication in Netpicker, with a focus on Azure AD integration.

**Important**: To enable OAuth authentication, you must set the `AUTH_BACKEND` environment variable to `netyce_alchemy` in your `docker-compose.override.yml` file.

## Configuration Parameters

The OAuth configuration is defined in the `docker-compose.override.yml` file as an environment variable. Here's an explanation of each parameter:

| Parameter                       | Description                                                                      |
| ------------------------------- | -------------------------------------------------------------------------------- |
| `oauth_client_class`            | The Python class that implements the OAuth client functionality                  |
| `name`                          | A unique identifier for the OAuth provider (e.g., "azuread", "google", "github") |
| `client_id`                     | The client ID obtained from the OAuth provider                                   |
| `client_secret`                 | The client secret obtained from the OAuth provider                               |
| `openid_configuration_endpoint` | The URL to the OpenID Connect configuration document                             |
| `base_scopes`                   | The OAuth scopes to request during authentication                                |

## Example Configuration

```yaml
# Set AUTH_BACKEND to netyce_alchemy to enable OAuth authentication
AUTH_BACKEND: netyce_alchemy

OAUTH: '{
  "oauth_client_class": "app.auth.oauth_clients.azuread:AzureAD",
  "name": "azuread",
  "client_id": "your-client-id",
  "client_secret": "your-client-secret",
  "openid_configuration_endpoint": "https://login.microsoftonline.com/your-tenant-id/v2.0/.well-known/openid-configuration",
  "base_scopes": ["email", "profile", "openid", "api://your-client-id/Netpicker.ALL"]
}'
```

## Azure AD Configuration Steps

1. **Register an Application in Azure AD**:

   - Sign in to the [Azure Portal](https://portal.azure.com)
   - Navigate to "Azure Active Directory" > "App registrations"
   - Click "New registration"
   - Enter a name for your application (e.g., "Netpicker")
   - Select the appropriate account type (typically "Accounts in this organizational directory only")
   - Set the redirect URI to `https://your-netpicker-domain.com/api/v1/auth/oauth/callback`
   - Click "Register"

2. **Configure Authentication**:

   - In your registered app, go to "Authentication"
   - Ensure the redirect URI is correctly set
   - Under "Implicit grant and hybrid flows", check "ID tokens"
   - Click "Save"

3. **Create a Client Secret**:

   - Go to "Certificates & secrets"
   - Click "New client secret"
   - Enter a description and select an expiration period
   - Click "Add"
   - **Important**: Copy the secret value immediately as it won't be shown again

4. **Configure API Permissions**:

   - Go to "API permissions"
   - Click "Add a permission"
   - Select "Microsoft Graph" > "Delegated permissions"
   - Add the following permissions:
     - `email`
     - `openid`
     - `profile`
     - `User.Read`
   - Click "Add permissions"
   - If necessary, click "Grant admin consent"

5. **Expose an API (Optional)**:

   - Go to "Expose an API"
   - Set the Application ID URI (e.g., `api://your-client-id`)
   - Click "Add a scope"
   - Define a scope named "Netpicker.ALL"
   - Fill in the required fields and click "Add scope"

6. **Update Netpicker Configuration**:

   - Update the `docker-compose.override.yml` file with your Azure AD details:
     - Replace `your-client-id` with the Application (client) ID from Azure
     - Replace `your-client-secret` with the client secret you created
     - Replace `your-tenant-id` in the configuration endpoint URL with your Azure AD tenant ID
     - Update the scopes as needed

7. **Restart Netpicker Services**:
   - Apply the configuration changes by restarting the Netpicker services

## Other OAuth Providers

### Google

For Google OAuth:

```yaml
OAUTH: '{
  "oauth_client_class": "app.auth.oauth_clients.google:Google",
  "name": "google",
  "client_id": "your-google-client-id",
  "client_secret": "your-google-client-secret",
  "openid_configuration_endpoint": "https://accounts.google.com/.well-known/openid-configuration",
  "base_scopes": ["email", "profile", "openid"]
}'
```

Configuration steps:

1. Go to the [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select an existing one
3. Navigate to "APIs & Services" > "Credentials"
4. Click "Create Credentials" > "OAuth client ID"
5. Configure the OAuth consent screen
6. Create an OAuth client ID for a Web application
7. Add your redirect URI: `https://your-netpicker-domain.com/api/v1/auth/oauth/callback`
8. Copy the client ID and client secret to your Netpicker configuration

### GitHub

For GitHub OAuth:

```yaml
OAUTH: '{
  "oauth_client_class": "app.auth.oauth_clients.github:GitHub",
  "name": "github",
  "client_id": "your-github-client-id",
  "client_secret": "your-github-client-secret",
  "authorization_endpoint": "https://github.com/login/oauth/authorize",
  "token_endpoint": "https://github.com/login/oauth/access_token",
  "userinfo_endpoint": "https://api.github.com/user",
  "base_scopes": ["user:email", "read:user"]
}'
```

Configuration steps:

1. Go to your GitHub account settings
2. Navigate to "Developer settings" > "OAuth Apps"
3. Click "New OAuth App"
4. Fill in the application details
5. Set the authorization callback URL to `https://your-netpicker-domain.com/api/v1/auth/oauth/callback`
6. Register the application
7. Copy the client ID and generate a client secret
8. Update your Netpicker configuration

## Troubleshooting

If you encounter issues with OAuth authentication:

1. **Check Redirect URIs**:

   - Ensure the redirect URI in your OAuth provider matches the one expected by Netpicker
   - The default callback path is `/api/v1/auth/oauth/callback`

2. **Verify Scopes**:

   - Make sure you've requested all necessary scopes
   - At minimum, you typically need `email`, `profile`, and `openid`

3. **Check Credentials**:

   - Verify that the client ID and client secret are correct
   - Ensure the client secret hasn't expired

4. **Inspect Network Traffic**:

   - Use browser developer tools to inspect the OAuth flow
   - Look for error responses from the OAuth provider

5. **Check Logs**:

   - Review the Netpicker API logs for OAuth-related errors
   - Enable debug logging if available

6. **Test with a Simple Client**:
   - Use a tool like [OAuth 2.0 Playground](https://oauth.com/playground) to test your OAuth configuration

## Security Considerations

- Store client secrets securely and never commit them to version control
- Use HTTPS for all OAuth endpoints
- Regularly rotate client secrets
- Request only the minimum scopes necessary
- Implement proper session management and token validation

# SAML Authentication Configuration Guide

## Overview

SAML (Security Assertion Markup Language) is an open standard for exchanging authentication and authorization data between parties, particularly between an identity provider (IdP) and a service provider (SP). This guide explains how to configure SAML authentication in Netpicker.

**Important**: To enable SAML authentication, you must set the `AUTH_BACKEND` environment variable to `saml` in your `docker-compose.override.yml` file.

## Configuration Parameters

The SAML configuration is defined in the `docker-compose.override.yml` file as an environment variable. Here's an explanation of each parameter:

### Service Provider (SP) Settings

| Parameter                             | Description                                                                  |
| ------------------------------------- | ---------------------------------------------------------------------------- |
| `strict`                              | Whether to strictly follow the SAML standard (recommended to keep as `true`) |
| `debug`                               | Enable debug mode for troubleshooting (set to `false` in production)         |
| `sp.entityId`                         | The unique identifier for your Netpicker service provider                    |
| `sp.assertionConsumerService.url`     | The URL where the IdP will send SAML responses                               |
| `sp.assertionConsumerService.binding` | The SAML binding to use for the assertion consumer service                   |
| `sp.singleLogoutService.url`          | The URL for handling logout requests                                         |
| `sp.singleLogoutService.binding`      | The SAML binding to use for the logout service                               |
| `sp.NameIDFormat`                     | The format of the NameID to request from the IdP                             |
| `sp.x509cert`                         | The x509 certificate for the service provider (if using signed requests)     |
| `sp.privateKey`                       | The private key for the service provider (if using signed requests)          |

### Identity Provider (IdP) Settings

| Parameter                         | Description                                                   |
| --------------------------------- | ------------------------------------------------------------- |
| `idp.entityId`                    | The unique identifier for your identity provider              |
| `idp.singleSignOnService.url`     | The URL where to send authentication requests                 |
| `idp.singleSignOnService.binding` | The SAML binding to use for the SSO service                   |
| `idp.singleLogoutService.url`     | The URL for sending logout requests to the IdP                |
| `idp.singleLogoutService.binding` | The SAML binding to use for the logout service                |
| `idp.x509cert`                    | The x509 certificate from your IdP (used to verify responses) |

### Security Settings

| Parameter                         | Description                                                    |
| --------------------------------- | -------------------------------------------------------------- |
| `security.signatureAlgorithm`     | The algorithm used for signatures                              |
| `security.digestAlgorithm`        | The algorithm used for digests                                 |
| `security.requestedAuthnContext`  | Whether to request a specific authentication context           |
| `security.wantAttributeStatement` | Whether to require an attribute statement in the SAML response |

### Other Settings

| Parameter | Description                                                  |
| --------- | ------------------------------------------------------------ |
| `tenant`  | The default tenant to assign to users authenticated via SAML |

## Example Configuration

```yaml
# Set AUTH_BACKEND to saml to enable SAML authentication
AUTH_BACKEND: saml

SAML: '{
  "strict": true,
  "debug": false,
  "sp": {
      "entityId": "https://netpicker.example.com/metadata",
      "assertionConsumerService": {
        "url": "https://netpicker.example.com/api/v1/auth/saml/callback",
        "binding": "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
      },
      "singleLogoutService": {
        "url": "https://netpicker.example.com/api/v1/auth/saml/logout",
        "binding": "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect"
      },
      "NameIDFormat": "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress",
      "x509cert": "",
      "privateKey": ""
  },
  "idp": {
    "entityId": "https://idp.example.com/saml/metadata",
    "singleSignOnService": {
        "url": "https://idp.example.com/saml/sso",
        "binding": "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect"
    },
    "singleLogoutService": {
        "url": "https://idp.example.com/saml/slo",
        "binding": "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect"
    },
    "x509cert": "YOUR_IDP_X509_CERTIFICATE"
  },
  "security": {
    "signatureAlgorithm": "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256",
    "digestAlgorithm": "http://www.w3.org/2001/04/xmlenc#sha256",
    "requestedAuthnContext": false,
    "wantAttributeStatement": false
  },
  "tenant": "DefaultTenant"
}'
```

## Configuration Steps

1. **Register Netpicker as a Service Provider with your IdP**:

   - You'll need to provide your IdP with:
     - Entity ID (e.g., `https://netpicker.example.com/metadata`)
     - Assertion Consumer Service URL (e.g., `https://netpicker.example.com/api/v1/auth/saml/callback`)
     - NameID format (typically email address)
     - Attribute mappings (if required)

2. **Obtain IdP Information**:

   - Entity ID
   - Single Sign-On Service URL
   - Single Logout Service URL (if supported)
   - X.509 Certificate

3. **Configure Service Provider Settings**:

   - Update the `sp` section with your Netpicker instance details
   - Replace the example URLs with your actual Netpicker URLs
   - If using signed requests, add your certificate and private key

4. **Configure Identity Provider Settings**:

   - Update the `idp` section with the information obtained from your IdP
   - Replace the example certificate with the actual certificate from your IdP

5. **Configure Security Settings**:

   - Adjust security settings based on your requirements and IdP capabilities
   - The default settings are suitable for most deployments

6. **Update docker-compose.override.yml**:

   - Replace the example SAML configuration with your actual configuration
   - Ensure the JSON is properly formatted

7. **Test the Configuration**:
   - Restart the Netpicker services
   - Navigate to the login page and select SAML authentication
   - You should be redirected to your IdP for authentication

## Common Identity Providers

### OneLogin

The example in the docker-compose.override.yml is configured for OneLogin. You'll need to:

- Create a SAML app in OneLogin
- Configure the app with your Netpicker SP details
- Copy the IdP details from OneLogin to your Netpicker configuration

### Okta

For Okta:

- Create a SAML app in Okta
- Configure the app with your Netpicker SP details
- Use the "Identity Provider metadata" from Okta to configure your Netpicker IdP settings

### Azure AD

For Azure AD:

- Register a new application in Azure AD
- Configure SAML authentication for the app
- Use the Federation Metadata XML to configure your Netpicker IdP settings

## Troubleshooting

If you encounter issues with SAML authentication:

1. Enable debug mode by setting `"debug": true`
2. Check the Netpicker logs for SAML-related errors
3. Verify the IdP certificate is correct and properly formatted
4. Ensure the URLs in your configuration match those registered with your IdP
5. Check that your IdP is sending the expected attributes and NameID format

# Netpicker Authentication Configuration Guide

## Overview

Netpicker supports multiple authentication providers to integrate with your existing identity management systems. This guide will help you choose and configure the appropriate authentication method for your environment.

## Available Authentication Providers

Netpicker supports the following authentication providers:

1. **LDAP** - Lightweight Directory Access Protocol
2. **SAML** - Security Assertion Markup Language (`AUTH_BACKEND=saml`)
3. **OAuth/OpenID Connect** - Including Azure AD, Google, and GitHub

## Choosing the Right Authentication Provider

### LDAP Authentication

**Best for:**

- Organizations with an existing LDAP directory (e.g., Active Directory, OpenLDAP)
- Environments where direct integration with the directory service is preferred
- On-premises deployments with limited cloud integration

**Advantages:**

- Direct integration with your directory service
- Fine-grained control over user and group mappings
- No additional identity provider required

**Disadvantages:**

- Requires network connectivity to the LDAP server
- May require opening firewall ports for LDAP traffic
- Less suitable for cloud-native deployments

[Detailed LDAP Configuration Guide](./LDAP_README.md)

### SAML Authentication

**Best for:**

- Organizations using enterprise identity providers (IdPs) like Okta, OneLogin, or ADFS
- Environments requiring single sign-on (SSO) across multiple applications
- Security-focused deployments that need centralized authentication

**Advantages:**

- Industry-standard protocol for enterprise SSO
- No need to store or manage user credentials
- Centralized authentication and authorization
- Support for multi-factor authentication (MFA)

**Disadvantages:**

- More complex initial setup
- Requires configuration on both Netpicker and the IdP
- Dependency on the IdP's availability

[Detailed SAML Configuration Guide](./SAML_README.md)

### OAuth/OpenID Connect Authentication

**Best for:**

- Organizations using cloud identity providers (Azure AD, Google Workspace, etc.)
- Modern, cloud-native deployments
- Environments where users are already authenticated to cloud services

**Advantages:**

- Modern, token-based authentication
- Well-suited for cloud deployments
- Support for social logins and external identities
- Typically includes support for MFA

**Disadvantages:**

- Requires internet connectivity
- Token management considerations
- May require regular client secret rotation

[Detailed OAuth Configuration Guide](./OAUTH_README.md)

## Configuration Process

1. **Determine your authentication requirements:**

   - Do you need single sign-on (SSO)?
   - Do you need to integrate with an existing identity provider?
   - What level of security is required?

2. **Choose the appropriate authentication provider** based on your requirements and existing infrastructure.

3. **Configure the selected provider** using the detailed guide for that provider.

4. **Update the `docker-compose.override.yml` file** with your configuration:

   - Set the `AUTH_BACKEND` environment variable to `saml` in case of SAML
   - Add the configuration for your selected provider

5. **Restart the Netpicker services** to apply the changes.

6. **Test the authentication** to ensure it's working as expected.

**Note**: Netpicker only supports one authentication provider at a time.

## Troubleshooting

If you encounter issues with authentication:

1. Check the Netpicker logs for authentication-related errors
2. Verify your configuration against the examples in the provider-specific guides
3. Ensure your identity provider is correctly configured and accessible
4. Test with a simple user account before rolling out to all users

For provider-specific troubleshooting, refer to the detailed guides for each authentication method.

## Security Considerations

- Always use secure connections (LDAPS, HTTPS) for authentication traffic
- Regularly rotate secrets and certificates
- Implement the principle of least privilege for service accounts
- Consider enabling multi-factor authentication where supported
- Regularly audit authentication logs and user access

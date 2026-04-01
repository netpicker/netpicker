# Add the volume mount to the x-api-no-deps volumes section
#   volumes:
#     - ./fastapi_users_patch.py:/usr/local/lib/python3.11/site-packages/app/auth/backends/netyce_alchemy/fastapi_users_patch.py:ro

import json
import logging
import time
from typing import Optional

import fastapi_users
import jwt
import lisf
from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from fastapi.responses import JSONResponse
from fastapi_users import models
from fastapi_users.authentication import AuthenticationBackend, Strategy
from fastapi_users.exceptions import UserAlreadyExists
from fastapi_users.jwt import SecretType, decode_jwt
from fastapi_users.manager import BaseUserManager, UserManagerDependency
from fastapi_users.router.common import ErrorCode, ErrorModel
from fastapi_users.router.oauth import OAuth2AuthorizeResponse, \
    STATE_TOKEN_AUDIENCE, generate_state_token
from httpx_oauth.integrations.fastapi import OAuth2AuthorizeCallback, \
    OAuth2AuthorizeCallbackError
from httpx_oauth.oauth2 import BaseOAuth2, GetAccessTokenError, OAuth2Token
from starlette.responses import RedirectResponse

from app.utils.framework import get_public_url
from ... import BearerResponseTTL, get_nonce_redirect_url, get_token_for_user

log = logging.getLogger(__name__)


class OauthCallback(OAuth2AuthorizeCallback):
    async def __call__(
        self,
        request: Request,
        code: Optional[str] = None,
        code_verifier: Optional[str] = None,
        state: Optional[str] = None,
        error: Optional[str] = None,
    ) -> tuple[OAuth2Token, Optional[str]]:
        if code is None or error is not None:
            raise OAuth2AuthorizeCallbackError(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=error if error is not None else None,
            )

        if self.route_name:
            redirect_url = str(request.url_for(self.route_name))
        elif self.redirect_url:
            redirect_url = self.redirect_url
        else:
            redirect_url = '...'

        redirect_url = get_public_url(request, redirect_url)

        try:
            access_token = await self.client.get_access_token(
                code, redirect_url, code_verifier
            )
        except GetAccessTokenError as e:
            raise OAuth2AuthorizeCallbackError(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=e.message,
                response=e.response,
            ) from e

        return access_token, state


def get_oauth_router(
    oauth_client: BaseOAuth2,
    backend: AuthenticationBackend,
    get_user_manager: UserManagerDependency[models.UP, models.ID],
    state_secret: SecretType,
    redirect_url: Optional[str] = None,
    associate_by_email: bool = False,
    is_verified_by_default: bool = False,
    **kwargs,
) -> APIRouter:
    """Generate a router with the OAuth routes."""
    router = APIRouter()
    callback_route_name = f"oauth:{oauth_client.name}.{backend.name}.callback"

    if redirect_url is not None:
        oauth2_authorize_callback = OauthCallback(
            oauth_client,
            redirect_url=redirect_url,
        )
    else:
        oauth2_authorize_callback = OauthCallback(
            oauth_client,
            route_name=callback_route_name,
        )

    @router.get(
        "/authorize",
        name=f"oauth:{oauth_client.name}.{backend.name}.authorize",
        response_model=OAuth2AuthorizeResponse,
    )
    async def authorize(
            request: Request,
            scopes: list[str] = Query(None),
            return_to: Optional[str] = Query(None, alias="redirect_url"),
    ) -> OAuth2AuthorizeResponse:
        if redirect_url is not None:
            authorize_redirect_url = redirect_url
        else:
            authorize_redirect_url = str(request.url_for(callback_route_name))

        state_data: dict[str, str] = {'return_to': return_to}
        state = generate_state_token(state_data, state_secret)
        authorization_url = await oauth_client.get_authorization_url(
            get_public_url(request, authorize_redirect_url),
            state,
            [*oauth_client.base_scopes, *(scopes or [])]
        )

        return OAuth2AuthorizeResponse(authorization_url=authorization_url)

    @router.get(
        "/callback",
        name=callback_route_name,
        description="The response varies based on the authentication backend used.",
        responses={
            status.HTTP_400_BAD_REQUEST: {
                "model": ErrorModel,
                "content": {
                    "application/json": {
                        "examples": {
                            "INVALID_STATE_TOKEN": {
                                "summary": "Invalid state token.",
                                "value": None,
                            },
                            ErrorCode.LOGIN_BAD_CREDENTIALS: {
                                "summary": "User is inactive.",
                                "value": {"detail": ErrorCode.LOGIN_BAD_CREDENTIALS},
                            },
                        }
                    }
                },
            },
        },
    )
    async def callback(
        request: Request,
        access_token_state: tuple[OAuth2Token, str] = Depends(
            oauth2_authorize_callback
        ),
        user_manager: BaseUserManager[models.UP, models.ID] = Depends(get_user_manager),
        strategy: Strategy[models.UP, models.ID] = Depends(backend.get_strategy),
    ):
        token, state = access_token_state
        id_token = token['id_token']
        access_token = token['access_token']
        oauth_id, oauth_email = await oauth_client.get_id_email(access_token)

        if oauth_email is None:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=ErrorCode.OAUTH_NOT_AVAILABLE_EMAIL,
            )

        try:
            st = decode_jwt(state, state_secret, [STATE_TOKEN_AUDIENCE])
        except jwt.DecodeError:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST)

        try:
            user = await user_manager.oauth_callback(
                oauth_client.name,
                token["access_token"],
                oauth_id,
                oauth_email,
                token.get("expires_at"),
                token.get("refresh_token"),
                request,
                associate_by_email=associate_by_email,
                is_verified_by_default=is_verified_by_default,
            )
        except UserAlreadyExists:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=ErrorCode.OAUTH_USER_ALREADY_EXISTS,
            )

        if not user.is_active:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=ErrorCode.LOGIN_BAD_CREDENTIALS,
            )

        get_scopes = getattr(oauth_client, 'get_scopes', None)
        set_scopes = getattr(user_manager, 'set_user_scopes', None)
        if callable(get_scopes) and callable(set_scopes):
            scopes = get_scopes(id_token, access_token)
            await set_scopes(user, scopes)
        # Authenticate
        response = await backend.login(strategy, user)
        await user_manager.on_after_login(user, request, response)
        redirect_url = st.get('return_to', '')
        ttl = int(token.get("expires_at")) - int(time.time())
        bearer = BearerResponseTTL(access_token=get_token_for_user(user, [lisf.config.JWT_AUDIENCE]), ttl=ttl)
        url = await get_nonce_redirect_url(bearer, redirect_url)
        return RedirectResponse(url=url)

    @router.get('/token')
    async def get_token(nonce: str = Query()):
        access_token = await lisf.async_redis.get(nonce)
        if access_token is None:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST)
        decoded_access_token = json.loads(access_token.decode())
        return JSONResponse(decoded_access_token)

    return router


fastapi_users.fastapi_users.get_oauth_router = get_oauth_router

defmodule ExMCP.Authorization.PendingAuthorization do
  @moduledoc """
  Opaque application-owned OAuth authorization-code transaction.

  `ExMCP.Authorization.FullOAuthFlow.begin/1` returns this value after MCP
  protected-resource discovery, authorization-server discovery, client
  registration, and PKCE setup. An application may then send
  `authorization_url` to its own browser surface and pass the callback
  parameters to `ExMCP.Authorization.FullOAuthFlow.complete/2`.

  The transaction contains client credentials, PKCE material, and OAuth state.
  Keep it server-side and never serialize it into a browser cookie, URL, log, or
  durable event. Its `Inspect` implementation deliberately hides those fields.
  """

  @derive {Inspect,
           except: [
             :authorization_url,
             :transaction,
             :client_info,
             :authorization_server,
             :config
           ]}
  @enforce_keys [
    :authorization_url,
    :transaction,
    :client_info,
    :authorization_server,
    :token_endpoint,
    :token_auth_method,
    :redirect_uri,
    :config
  ]
  defstruct [
    :authorization_url,
    :transaction,
    :client_info,
    :authorization_server,
    :token_endpoint,
    :token_auth_method,
    :redirect_uri,
    :config
  ]

  @type t :: %__MODULE__{
          authorization_url: String.t(),
          transaction: map(),
          client_info: map(),
          authorization_server: map(),
          token_endpoint: String.t(),
          token_auth_method: atom(),
          redirect_uri: String.t(),
          config: map()
        }
end

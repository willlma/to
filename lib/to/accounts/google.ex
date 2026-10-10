defmodule To.Accounts.Google do
  alias To.Accounts

  @scope "openid email profile https://www.googleapis.com/auth/tasks"

  def configured? do
    config = config()

    Enum.all?(
      [:client_id, :client_secret, :redirect_uri, :nicole_email, :will_email],
      &present?(config[&1])
    )
  end

  def authorization_url(state, verifier) do
    params = %{
      client_id: config()[:client_id],
      redirect_uri: config()[:redirect_uri],
      response_type: "code",
      scope: @scope,
      access_type: "offline",
      prompt: "consent select_account",
      state: state,
      code_challenge: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false),
      code_challenge_method: "S256"
    }

    "https://accounts.google.com/o/oauth2/v2/auth?" <> URI.encode_query(params)
  end

  def exchange(code, verifier) do
    with {:ok, tokens} <-
           token_request(%{
             code: code,
             code_verifier: verifier,
             grant_type: "authorization_code",
             redirect_uri: config()[:redirect_uri]
           }),
         access_token when is_binary(access_token) <- tokens["access_token"],
         {:ok, %{status: 200, body: profile}} <-
           Req.get(profile_url(),
             auth: {:bearer, access_token},
             retry: false,
             decode_body: true,
             receive_timeout: 15_000
           ) do
      {:ok, profile, tokens}
    else
      _ -> {:error, :google_unavailable}
    end
  end

  def refresh_access_token(user) do
    with {:ok, token} <- Accounts.refresh_token(user),
         {:ok, tokens} <- token_request(%{refresh_token: token, grant_type: "refresh_token"}),
         access_token when is_binary(access_token) <- tokens["access_token"] do
      {:ok, access_token}
    else
      _ -> {:error, :google_reconnect_required}
    end
  end

  defp token_request(fields) do
    params =
      Map.merge(fields, %{
        client_id: config()[:client_id],
        client_secret: config()[:client_secret]
      })

    case Req.post(token_url(),
           form: params,
           retry: false,
           decode_body: true,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: tokens}} when is_map(tokens) -> {:ok, tokens}
      _ -> {:error, :google_unavailable}
    end
  end

  defp config, do: Application.get_env(:to, :google_oauth, [])
  defp present?(value), do: is_binary(value) && byte_size(value) > 0

  if Mix.env() == :test do
    defp token_url,
      do: Application.get_env(:to, :google_token_url, "https://oauth2.googleapis.com/token")

    defp profile_url,
      do:
        Application.get_env(
          :to,
          :google_profile_url,
          "https://openidconnect.googleapis.com/v1/userinfo"
        )
  else
    defp token_url, do: "https://oauth2.googleapis.com/token"
    defp profile_url, do: "https://openidconnect.googleapis.com/v1/userinfo"
  end
end

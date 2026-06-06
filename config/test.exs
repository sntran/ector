import Config

common = [
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  migration_source: "ector_schema_migrations"
]

sanitize_database_url = fn database_url ->
  with [scheme, rest] <- String.split(database_url, "://", parts: 2),
       true <- scheme in ["postgres", "postgresql"] do
    encode_userinfo_component = fn component -> URI.encode(component, &URI.char_unreserved?/1) end

    encode_userinfo = fn userinfo ->
      case String.split(userinfo, ":", parts: 2) do
        [username, password] ->
          encode_userinfo_component.(username) <> ":" <> encode_userinfo_component.(password)

        [username] ->
          encode_userinfo_component.(username)
      end
    end

    case String.split(rest, "@") do
      [authority_and_path] ->
        "#{scheme}://#{authority_and_path}"

      parts ->
        "#{scheme}://#{encode_userinfo.(parts |> Enum.drop(-1) |> Enum.join("@"))}@#{List.last(parts)}"
    end
  else
    _ ->
      raise ArgumentError,
            "expected a PostgreSQL DATABASE_URL like postgresql://user:pass@host:5432/dbname"
  end
end

socket_options_for = fn hostname ->
  case {:inet.getaddrs(String.to_charlist(hostname), :inet),
        :inet.getaddrs(String.to_charlist(hostname), :inet6)} do
    {{:error, :nxdomain}, {:ok, [_ | _]}} -> [socket_options: [:inet6]]
    _ -> []
  end
end

case System.get_env("DATABASE_URL") do
  database_url when is_binary(database_url) and database_url != "" ->
    sanitized_database_url = sanitize_database_url.(database_url)

    host =
      case URI.new(sanitized_database_url) do
        {:ok, %URI{host: hostname}} when is_binary(hostname) and hostname != "" ->
          hostname

        {:ok, _uri} ->
          raise ArgumentError,
                "expected a PostgreSQL DATABASE_URL like postgresql://user:pass@host:5432/dbname"

        {:error, part} ->
          raise ArgumentError, "invalid PostgreSQL DATABASE_URL component: #{inspect(part)}"
      end

    config :ector,
           Ector.TestRepo.Postgres,
           Keyword.merge(
             common,
             [url: sanitized_database_url, pool_size: 4] ++ socket_options_for.(host)
           )

  _ ->
    config :ector,
           Ector.TestRepo.SQLite,
           Keyword.merge(common,
             database: Path.join(System.tmp_dir!(), "ector_test.sqlite3"),
             pool_size: 1,
             journal_mode: :wal,
             busy_timeout: 5_000
           )
end

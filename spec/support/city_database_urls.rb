# Builds a postgres:// URL for a city test database, honoring DATABASE_HOST
# so specs work whether the suite runs against localhost or a container's
# view of the host (docker-compose sets DATABASE_HOST for exactly this).
#
# This is the exact trap that once broke 205 of 337 examples: a hardcoded
# 127.0.0.1 masks itself as correct on a laptop and breaks the moment the
# suite runs from a container that only sees the DB as some other host.
module CityDatabaseUrls
  extend self

  def city_database_url(database, user: "rota_saude", password: ENV.fetch("POSTGRES_PASSWORD", "postgres"))
    host = ENV.fetch("DATABASE_HOST", "127.0.0.1")
    port = ENV.fetch("DATABASE_PORT", "5432")
    "postgres://#{user}:#{password}@#{host}:#{port}/#{database}"
  end
end

RSpec.configure do |config|
  config.include CityDatabaseUrls
end

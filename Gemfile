source "https://rubygems.org"

ruby file: ".ruby-version"

gem "rails", "~> 8.0"
gem "pg", "~> 1.5"
gem "puma", ">= 6.0"

# Backend modulo "Solid" do Rails 8.
gem "solid_queue"   # ADR-0001 — fila
gem "solid_cache"   # cache de Protocols.current (ADR-0016)

gem "bootsnap", require: false
gem "tzinfo-data", platforms: %i[mingw mswin x64_mingw jruby]

# Filtros e parsers
gem "jbuilder"
gem "rack-cors"

group :development, :test do
  gem "debug", platforms: %i[mri windows]
  gem "rspec-rails"
  gem "factory_bot_rails"
  gem "rubocop-rails-omakase", require: false
end

group :development do
  gem "web-console"
end

group :test do
  gem "webmock"
  gem "vcr"
end

# JSON Schema (draft 2020-12) validation for the protocol definition gate (F-03.9).
gem "json_schemer"

gem "bcrypt", "~> 3.1"
gem "rotp", "~> 6.3"   # TOTP RFC 6238 — ADR-0022
gem "jwt", "~> 2.8"    # OIDC id_token verification — ADR-0022 (gov.br seam)

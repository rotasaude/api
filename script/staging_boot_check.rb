# Boot real de RAILS_ENV=staging, sem banco (spec da API de manutenção §4 e §10).
# Roda no job `staging-boot` da CI e à mão:
#   RAILS_ENV=staging bin/rails runner script/staging_boot_check.rb
# Nunca imprime segredo: só nomes, booleanos e a lista de hosts.
failures = []
check = ->(ok, message) { failures << message unless ok }

check.(Rails.env.staging?, "Rails.env é #{Rails.env}, não staging")
check.(Rota.deployed?, "Rota.deployed? é falso")

credentials_file = Pathname(Rails.application.config.credentials.content_path.to_s).basename.to_s
check.(credentials_file == "staging.yml.enc", "credentials vêm de #{credentials_file}, não de staging.yml.enc")

check.(Rails.application.config.hosts.any?, "config.hosts vazio: HostAuthorization inerte")
check.(Rails.application.middleware.map(&:klass).include?(ActionDispatch::HostAuthorization),
       "ActionDispatch::HostAuthorization não está instalado")

cookie_store = Rails.application.middleware.find { |middleware| middleware.klass == ActionDispatch::Session::CookieStore }
cookie_options = cookie_store&.args&.last
check.(cookie_options.is_a?(Hash) && cookie_options[:secure] == true, "CookieStore sem secure: true")

city_url = URI.parse(CityDatabase.url_for(slug: "curitiba", password: "inert"))
check.(city_url.query == "sslmode=require", "URL do banco da cidade sem sslmode=require")
check.(city_url.port == 5432, "URL do banco da cidade fora da porta 5432")

abort("STAGING_BOOT_FAILED\n- #{failures.join("\n- ")}") if failures.any?

puts "STAGING_BOOT_OK hosts=#{Rails.application.config.hosts.inspect}"

# Registra uma cidade no catálogo. NÃO cria o banco nem roda migrations —
# isso é o Plano 4 (provisionamento em duas fases). Aqui só existe o suficiente
# para desenvolvimento.
class CityProvisioner
  def self.call(slug:, name:, uf: nil)
    existing = City.find_by(slug: slug)
    return existing if existing

    City.create!(
      slug: slug,
      name: name,
      uf: uf,
      status: "provisioning",
      database_url: database_url_for(slug),
      encryption_key: SecureRandom.hex(32)
    )
  end

  def self.database_url_for(slug)
    host = ENV.fetch("DATABASE_HOST", "127.0.0.1")
    port = ENV.fetch("DATABASE_PORT", "5432")
    user = ENV.fetch("BOOTSTRAP_SUPERUSER", "rota_saude")
    pwd  = ENV.fetch("POSTGRES_PASSWORD", "postgres")
    "postgres://#{user}:#{pwd}@#{host}:#{port}/rota_saude_city_#{slug}"
  end
end

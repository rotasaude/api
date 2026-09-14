# Cidade provisionada DE VERDADE para specs de ciclo de vida (Plano 4): linha no
# catálogo, banco e role próprios (CityDatabase) e schema migrado. Exige
# `self.use_transactional_tests = false`.
#
# Sempre limpe com cleanup_provisioned_city!: um pool registrado para um banco
# apagado derruba todo exemplo transacional seguinte (setup_transactional_fixtures
# pina todo pool registrado).
module ProvisionedCities
  def provision_city!(status: "active")
    slug = "prov#{SecureRandom.hex(4)}"
    password = SecureRandom.hex(24)
    CityDatabase.ensure!(slug: slug, password: password)
    city = City.create!(slug: slug, name: "Cidade #{slug}", uf: "PR", status: "provisioning",
                        database_url: CityDatabase.url_for(slug: slug, password: password),
                        encryption_key: SecureRandom.hex(32))
    CityMigrations.run(city)
    city.update!(status: status)
    city
  end

  def cleanup_provisioned_city!(city)
    CityConnection.forget(city.shard)
    CityDatabase.drop!(slug: city.slug)
    CityChannel.where(city_id: city.id).delete_all
    CityGrant.where(city_id: city.id).delete_all
    PlatformEvent.where("payload->>'city_id' = ?", city.id).delete_all
    City.where(id: city.id).delete_all
  end
end

RSpec.configure do |config|
  config.include ProvisionedCities
end

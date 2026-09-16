FactoryBot.define do
  factory :city do
    sequence(:slug) { |n| "cidade#{n}" }
    name { "Cidade Exemplo" }
    uf { "SP" }
    status { "active" }
    database_url { "postgres://rota_city:rota_city@#{ENV.fetch('DATABASE_HOST', '127.0.0.1')}:5432/rota_saude_test_city_a" }
    encryption_key { CityTestDatabases.encryption_key_for(slug) }
    schema_version { CitySchema.expected_version.to_s }
  end
end

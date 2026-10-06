# spec/support/cnes_helpers.rb
# Módulo 16 (ADR 0028): retrato do CNES na plataforma e cadastro local
# coerentes, para Proposal/Apply.
module CnesHelpers
  def cnes_snapshot!(ibge_code: "4106902", competence: "202609", establishments: [], teams: [], bonds: [])
    Cnes::SnapshotWriter.write!(competence: competence, ibge_code: ibge_code, establishments: establishments,
                                teams: teams, bonds: bonds)
  end

  def cnes_city!
    city = City.find_by(slug: TEST_CITY_A.slug) ||
           City.create!(slug: TEST_CITY_A.slug, name: TEST_CITY_A.name, status: "active",
                        database_url: TEST_CITY_A.database_url, encryption_key: TEST_CITY_A.encryption_key,
                        schema_version: CitySchema.expected_version.to_s)
    (CityProfile.current || CityProfile.new(name: "Curitiba", uf: "PR")).update!(ibge_code: "4106902")
    city
  end

  def professional_with!(email, unit:, cbo:, cpf: nil, cns: nil)
    user = staff_with(email, "health_professional")
    link_professional!(user, unit, cbo: cbo)
    user.reload.professional.tap { |p| p.update!(cpf: cpf, cns: cns || p.cns) }
  end
end

RSpec.configure { |c| c.include CnesHelpers }

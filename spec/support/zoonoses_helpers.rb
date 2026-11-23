# Módulo 35b (ADR 0054): cidade do centro de zoonoses (a visita domiciliar e
# o `zoonoses` ligados, sem o `vector_control`: sem cascata), a equipe, a
# coordenação (a do 35a), a UVZ, a veterinária (Q12: com o papel), o tutor e o
# animal. Os helpers das tasks seguintes entram neste arquivo. Tudo avaliado
# só na chamada.
module ZoonosesHelpers
  # Nome marcado do tutor: a guarda de sigilo procura por ele em log, evento e
  # lista (§16).
  ZOONOSES_TUTOR_NAME = "Tutora Marcada Zoonoses".freeze

  def zoonoses_city!
    city = home_visit_city!
    Platform::Features.set!(city: city, key: Zoonoses::Gate::KEY, enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    city
  end

  def zoonoses_team! = staff_with("zoonoses-#{SecureRandom.hex(4)}@cidade.gov.br", Zoonoses::Catalog::ROLE)

  # A coordenação de vigilância ambiental é o endemic_coordinator do 35a (Q1).
  def zoonoses_coordinator! = endemic_coordinator!

  def uvz_unit! = create_unit("UVZ #{SecureRandom.hex(2)}", kind: "environmental_surveillance")

  # Veterinária (Q12, Q30): só o papel zoonoses_team, o perfil CRMV completo
  # e o vínculo ativo 223305 na unidade (a UVZ, se não vier), pelo caminho
  # real (Professionals::Create e OpenLink, pelo municipal_admin).
  def veterinarian!(unit: uvz_unit!)
    user = zoonoses_team!
    n = registry_seq!
    attrs = { "professional_name" => "Veterinária #{n}", "cns" => valid_cns(n), "council" => "CRMV", "council_state" => "PR",
              "registration_number" => (90_000 + n).to_s }
    Current.set(city: Current.city || TEST_CITY_A) do
      created = Professionals::Create.call(user_id: user.id, attrs: attrs, by: zoonoses_admin)
      raise ArgumentError, "veterinarian!: #{created.reason} #{created.details.inspect}" if created.failure?

      linked = Professionals::OpenLink.call(professional: created.payload[:professional], health_unit_id: unit.id,
                                            cbo_code: Zoonoses::Catalog::VETERINARIAN_CBO, by: zoonoses_admin)
      raise ArgumentError, "veterinarian!: #{linked.reason} #{linked.details.inspect}" if linked.failure?
    end
    user.reload
  end

  # Paciente com CPF válido e o nome marcado.
  def tutor!
    n = registry_seq!
    Patient.create!(cpf: valid_cpf(n), full_name: ZOONOSES_TUTOR_NAME, mother_name: "Rita Ribeiro Lima",
                    birth_date: (Time.zone.today - 35.years - n.days).iso8601, sex: "female", race_color: "03")
  end

  # Animal direto na linha (o caminho real, Zoonoses::SaveAnimal, nasce na
  # Task 5). `over` sobrescreve qualquer coluna.
  def animal!(household: nil, tutor: nil, species: "dog", **over)
    Animal.create!({ species: species, sex: "unknown", household: household, tutor_patient: tutor, community: false,
                     status: "active", created_by_user: zoonoses_author }.merge(over))
  end

  private

  def zoonoses_author = (@zoonoses_author ||= zoonoses_team!)

  def zoonoses_admin = (@zoonoses_admin ||= staff_with("admin-zoonoses-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
end

RSpec.configure { |c| c.include ZoonosesHelpers }

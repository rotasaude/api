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

  # Observação direto na linha (o caminho real, Zoonoses::OpenObservation,
  # nasce na Task 7). Notificação de acidente com animal pelo comando do 25;
  # `state: "closed"` nasce já com o desfecho (o trigger só vigia o UPDATE).
  def bite_observation!(notification: nil, place: "home", state: "open", **over)
    notification ||= begin
      # A lista nacional de doenças (platform) e o interruptor da vigilância, só se faltarem.
      Surveillance::DiseaseList::Load.call unless Surveillance::Diseases.find(Zoonoses::Catalog::OBSERVATION_DISEASE)
      notification!(patient: tutor!, disease_code: Zoonoses::Catalog::OBSERVATION_DISEASE)
    end
    exposure = over.fetch(:exposure_on, Time.zone.today - 3)
    closed = state == "closed"
    BiteObservation.create!({ disease_notification: notification, species: "dog", exposure_on: exposure, ends_on: exposure + 10,
                              place: place, state: state, outcome: ("healthy" if closed), outcome_on: (exposure + 10 if closed),
                              closed_by_user: (zoonoses_author if closed) }.merge(over))
  end

  # Inquérito direto na linha (Task 13 traz o comando); o bairro é o do primeiro quarteirão.
  def leish_survey!(blocks:, kind: "sample", stage: "open", **over)
    blocks = Array(blocks)
    LeishSurvey.create!({ name: "Inquérito #{SecureRandom.hex(3)}", kind: kind, neighborhood: blocks.first.neighborhood,
                          city_block_ids: blocks.map(&:id), dog_population: 400, target_dogs: 80, starts_on: Time.zone.today,
                          ends_on: Time.zone.today + 30, stage: stage, parameters_version: 0 }.merge(over))
  end

  # Estada direto na linha (Task 8 traz o comando); na UVZ, se a unidade não vier.
  def shelter_stay!(animal:, entry_kind: "collection", **over)
    ShelterStay.create!({ animal: animal, health_unit: uvz_unit!, entry_kind: entry_kind, entered_on: Time.zone.today }.merge(over))
  end

  # Eutanásia crua (a veterinária é a do `by`; Task 8 traz o comando, com a
  # morte do animal e as ligações).
  def euthanasia!(animal:, by: veterinarian!, **over)
    Euthanasia.create!({ animal: animal, performed_on: Time.zone.today, professional: by.professional, reason: "untreatable_suffering",
                         reason_note: "Sofrimento sem tratamento possível.", legal_basis: %w[cfmv_1000_2012] }.merge(over))
  end

  private

  def zoonoses_author = (@zoonoses_author ||= zoonoses_team!)

  def zoonoses_admin = (@zoonoses_admin ||= staff_with("admin-zoonoses-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
end

RSpec.configure { |c| c.include ZoonosesHelpers }

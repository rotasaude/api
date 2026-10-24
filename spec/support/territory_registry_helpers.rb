# Módulo 24a (ADR 0042): cidade com o prontuário, care_lines,
# territory_registry e o LEDI prontos (PEC falso), equipes, ACS sem conselho,
# enfermeiro, microáreas, domicílios e cadastros individuais.
# Cenário de teste: domicílio e cadastro gravam as LINHAS direto (cabeçalho +
# versão 1); os caminhos reais são TerritoryRegistry::SaveHousehold e
# SaveRegistration (Tasks 9/10), e estes helpers passam a chamá-los depois
# delas (Step 6 da Task 10).
module TerritoryRegistryHelpers
  def registry_city!
    city = care_city!
    stub_pec!
    ledi_ready!(city, pec_url: "https://pec.a.test", record_mode: "record")
    Platform::Features.set!(city: city, key: "territory_registry", enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    city
  end

  def registry_seq! = (@registry_seq = (@registry_seq || 700) + 1)

  # CPF com os dois dígitos verificadores certos, um por n.
  def valid_cpf(n)
    nums = format("%09d", 413_000_000 + n).chars.map(&:to_i)
    first = CitizenIdentity::Cpf.check_digit(nums)
    (nums + [ first, CitizenIdentity::Cpf.check_digit(nums + [ first ]) ]).join
  end

  # CNS provisório (prefixo 7) com a soma ponderada certa, um por n.
  def valid_cns(n) = Professionals::Cns.generate("territory-registry:#{n}")

  def registry_team!(unit = nil)
    unit ||= care_unit!
    unit.update!(cnes: format("%07d", SecureRandom.random_number(10**7))) if unit.cnes.blank?
    HealthTeam.create!(health_unit: unit, ine: format("%010d", SecureRandom.random_number(10**10)), kind: "70",
                       name: "ESF #{unit.name}")
  end

  # ACS: perfil SEM conselho, CNS válido, vínculo 515105 na unidade e membro
  # da equipe (a da unidade, ou uma nova).
  def registry_acs!(unit = nil, team: nil)
    registry_field_professional!(unit, team: team, cbo: TerritoryRegistry::Catalog::ACS_CBO, council: false)
  end

  # Enfermeiro (223505, COREN) com vínculo na unidade e membro da equipe.
  def registry_nurse!(unit = nil, team: nil)
    registry_field_professional!(unit, team: team, cbo: "223505", council: true)
  end

  def registry_micro_area!(code:, team: nil, acs: nil)
    team ||= registry_team!
    MicroArea.create!(team: team, code: code, name: "Microárea #{code}", acs_professional: acs&.professional)
  end

  # Domicílio ativo, versão 1, gravado pelo ACS da microárea (ou um da equipe).
  def registry_household!(micro_area: nil, **over)
    micro_area ||= registry_micro_area!(code: "01")
    author = registry_author_of(micro_area)
    now = Time.current
    household = Household.create!(micro_area: micro_area, status: "active", version: 1, registered_at: now,
                                  registered_by_user: author)
    HouseholdVersion.create!({ household: household, version: 1, micro_area: micro_area, team: micro_area.team,
                               property_type: "1", address: registry_address, living_conditions: registry_living_conditions,
                               contact_phone: "4133334444", refused: "false", families_snapshot: [], status: "active",
                               origin: "save", **registry_saved_by(author, micro_area.team), created_at: now }.merge(over))
    household
  end

  # Cadastro individual ativo, versão 1, no domicílio (novo, se não vier).
  def registry_registration!(patient: nil, household: nil, **over)
    household ||= registry_household!
    patient ||= registry_patient!
    area = household.micro_area
    author = registry_author_of(area)
    now = Time.current
    header_columns = IndividualRegistration.column_names
    registration = IndividualRegistration.create!({ patient: patient, team: area.team, micro_area: area, household: household,
                                                    is_responsible: false, version: 1, refused: "false", registered_at: now,
                                                    registered_by_user: author }.merge(over.slice(*header_columns.map(&:to_sym))))
    IndividualRegistrationVersion.create!({ registration: registration, version: 1, patient: patient, team: area.team,
                                            micro_area: area, household: household, is_responsible: registration.is_responsible,
                                            identity: registry_identity(patient), identification: registry_identification,
                                            sociodemographic: registry_sociodemographic, health_conditions: registry_health_conditions,
                                            refused: registration.refused, origin: "save", **registry_saved_by(author, area.team),
                                            created_at: now }.merge(over.slice(*IndividualRegistrationVersion.column_names.map(&:to_sym))))
    registration
  end

  def registry_patient!
    n = registry_seq!
    Patient.create!(cpf: valid_cpf(n), full_name: "Joana Ribeiro Lima", mother_name: "Rita Ribeiro Lima",
                    birth_date: (Time.zone.today - 40.years - n.days).iso8601, sex: "female")
  end

  # Paciente digitado sem CPF (justificativa 3), com CNS (ou sem, com cns: nil),
  # pelo caminho real (Patients::CreateTyped). Demografia do BPA-I opcional.
  def registry_no_cpf_patient!(cns: valid_cns(registry_seq!), demographics: false)
    attrs = { "full_name" => "Lia Santos", "birth_date" => "2026-08-01", "sex" => "female", "no_cpf_reason" => "3", "cns" => cns }
    result = Patients::CreateTyped.call(attrs: attrs, by: verifier!)
    raise "paciente sem CPF recusado: #{result.reason}" if result.failure?

    result.payload[:patient].tap { |patient| patient.update!(BillingHelpers::DEMOGRAPHICS) if demographics }
  end

  # Identidade de ficha LEDI (Ledi::Fichas::ScreeningIdentity) com valores fixos.
  def ledi_identity(citizen_cpf:, citizen_cns:)
    started = Time.zone.parse("2026-10-07 09:10")
    Ledi::Fichas::ScreeningIdentity.new(cnes: "1234567", ine: "0000123456", professional_cns: "700000000000005", cbo: "225125",
                                        citizen_cpf: citizen_cpf, citizen_cns: citizen_cns, birth_date: Date.new(2026, 8, 1),
                                        sex: "female", started_at: started, ended_at: started + 20.minutes, ibge_code: "4106902")
  end

  def ledi_care = Ledi::Fichas::IndividualCare::Care.new(care_type: 5, problems: [], conducts: [ 1 ], exams: [], measurements: nil)

  def bpa_header
    Billing::BpaFile::Header.new(competence: "202610", origin_name: "SMS Curitiba", origin_acronym: nil, origin_cnpj: "11222333000181",
                                 destination_body: "Secretaria Municipal de Saude", management: "M")
  end

  # Linha BPA-I com valores fixos; o paciente identificado por cpf: ou cns:.
  def bpa_i_line(cpf:, cns:)
    Billing::BpaFile::ILine.new(key: "i01", cnes: "7654321", competence: "202610", professional_cns: "798312812760829", cbo: "225125",
                                performed_on: Date.new(2026, 10, 7), procedure: "0301010072", sex: "F", ibge: "410690", cid10: nil,
                                age: 0, quantity: 1, character: "01", name: "Lia Santos", birth_date: Date.new(2026, 8, 1),
                                race_color: "03", ethnicity: nil, zip: "80010000", street: "Rua XV de Novembro", number: "1200",
                                complement: nil, district: "Centro", phone: nil, cpf: cpf, cns: cns)
  end

  def registry_address
    { "zip" => "80010000", "street_type" => "081", "street" => "Rua das Flores", "number" => "120", "no_number" => false,
      "complement" => nil, "district" => "Centro", "neighborhood_id" => nil, "reference" => nil }
  end

  def registry_living_conditions
    { "localizacao" => 83, "situacao_moradia_posse_terra" => 75, "abastecimento_agua" => 117, "nu_moradores" => 3 }
  end

  def registry_identity(patient)
    { "full_name" => patient.full_name, "birth_date" => patient.birth_date, "sex" => patient.sex,
      "mother_name" => patient.mother_name, "cpf" => patient.cpf, "cns" => patient.cns }
  end

  def registry_identification = { "nacionalidade_cidadao" => 1, "codigo_ibge_municipio_nascimento" => "4106902" }

  def registry_sociodemographic
    { "status_deseja_informar_orientacao_sexual" => false, "status_deseja_informar_identidade_genero" => false }
  end

  def registry_health_conditions = { "status_tem_diabetes" => true, "status_tem_hipertensao_arterial" => false }

  private

  def registry_field_professional!(unit, team:, cbo:, council:)
    unit ||= team&.health_unit || care_unit!
    team ||= HealthTeam.find_by(health_unit: unit) || registry_team!(unit)
    n = registry_seq!
    user = staff_with("campo-#{SecureRandom.hex(4)}@cidade.gov.br", "health_professional")
    registry = council ? { council: "COREN", council_state: "PR", registration_number: (50_000 + n).to_s } : {}
    Professional.create!(user: user, professional_name: "Profissional #{n}", cns: valid_cns(n), **registry)
    link_professional!(user, unit, cbo: cbo)
    HealthTeamMember.create!(professional: user.reload.professional, health_team: team, cbo_code: cbo,
                             started_on: Time.zone.today - 30)
    user
  end

  def registry_author_of(area)
    area.acs_professional&.user || registry_acs!(area.team.health_unit, team: area.team)
  end

  def registry_saved_by(user, team)
    member = HealthTeamMember.active.find_by!(professional: user.professional, health_team: team)
    { saved_by_user: user, saved_by_professional: user.professional, saved_cbo: member.cbo_code }
  end
end

RSpec.configure { |c| c.include TerritoryRegistryHelpers }

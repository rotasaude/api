require "rails_helper"

# Módulo 24a (ADR 0042; contrato §5, §14 L4, L5, L7, L17; plano, Desvios 3,
# 5, 8 e 12; F-24.3): cadastro individual como versão imutável + ficha; a
# pessoa vem de patient_id, citizen_id (par validado → Patients::Resolve) ou
# new_patient (Patients::CreateTyped); raça/cor e etnia moram no paciente.
RSpec.describe TerritoryRegistry::SaveRegistration do
  before { registry_city! }

  let(:household) { registry_household! }
  let(:acs) { registry_acs_of(household) }

  def save(params, by: acs, registration: nil) = described_class.call(params: params, by: by, registration: registration)

  def new_patient(**over)
    { "full_name" => "Lia Santos", "birth_date" => "1990-08-01", "sex" => "female", "mother_name" => "Carla Santos",
      "no_cpf_reason" => "3", "cns" => valid_cns(registry_seq!) }.merge(over.stringify_keys)
  end

  def params(**over) = registry_registration_params(household).merge("patient_demographics" => { "race_color" => "03" }).merge(over.stringify_keys)

  it "new_patient: paciente digitado, versão 1 com o retrato da identidade, ficha, evento e o endereço do domicílio no paciente" do
    result = save(params(new_patient: new_patient))
    expect(result).to be_ok
    registration = result.payload[:registration]
    version = result.payload[:version]
    patient = registration.patient
    expect(registration).to have_attributes(version: 1, household_id: household.id, micro_area_id: household.micro_area_id,
                                            team_id: household.micro_area.team_id, refused?: false, registered_by_user_id: acs.id)
    expect(version).to have_attributes(origin: "save", saved_by_user_id: acs.id, saved_cbo: "515105", version: 1)
    expect(version.identity).to include("full_name" => "Lia Santos", "race_color" => "03", "cpf" => nil, "no_cpf_reason" => "3")
    expect(version.street_situation).to eq("status_situacao_rua" => false)
    expect(patient).to have_attributes(race_color: "03", address_street: "das Flores", address_zip: "80010000", address_number: "120")
    expect(LediOutboxEntry.where(source_id: version.id, ficha_type: "cadastro_individual")).to exist
    expect(DomainEvent.where(name: "territory_registration.saved").last.payload)
      .to eq("registration_id" => registration.id, "registration_version_id" => version.id, "patient_id" => patient.id, "user_id" => acs.id)
  end

  it "recusas do paciente digitado com o caminho do corpo; nada gravado" do
    expect(save(params(new_patient: new_patient(full_name: "Lia")))).to have_attributes(reason: :invalid_registration)
    expect(save(params(new_patient: new_patient(full_name: "Lia"))).details).to eq(path: "new_patient.full_name")
    expect(save(params(new_patient: new_patient(cns: "123"))).details).to eq(path: "new_patient.cns")
    expect(save(params(new_patient: new_patient(no_cpf_reason: nil, cns: nil))).reason).to eq(:cpf_or_reason_required)
    expect(save(params(new_patient: new_patient(mother_name: nil))).details).to eq(path: "new_patient.mother_name")
    expect(save(params(new_patient: new_patient(birth_date: "1890-01-01"))).details).to eq(path: "new_patient.birth_date")
    expect(save(params(new_patient: new_patient, patient_id: registry_patient!.id)).details).to eq(path: "new_patient")
    expect(Patient.where(no_cpf_reason: "3")).to be_empty
    expect(IndividualRegistration.count).to eq(0)
  end

  it "paciente existente: segundo cadastro ativo → already_registered com o id do ativo" do
    patient = registry_patient!
    first = save(registry_registration_params(household, patient: patient))
    expect(first).to be_ok
    second = save(registry_registration_params(household, patient: patient))
    expect(second.reason).to eq(:already_registered)
    expect(second.details).to eq(registration_id: first.payload[:registration].id)
  end

  it "citizen_id: par validado sem paciente cria pelo Resolve; par não validado → citizen_not_verified" do
    citizen = verified_citizen!(31)
    result = save(params(citizen_id: citizen.id))
    expect(result).to be_ok
    expect(citizen.reload.patient_id).to eq(result.payload[:registration].patient_id)
    # L4: a marca é de validação POSTERIOR ao cadastro; nascer do par validado não marca
    expect(result.payload[:registration].identity_changed_at).to be_nil
    pending_pair = screening_citizen!(32, age: 30, sex: "male")
    expect(save(params(citizen_id: pending_pair.id)).reason).to eq(:citizen_not_verified)
    expect(save(params(citizen_id: "nada")).details).to eq(path: "citizen_id")
  end

  it "patient_id digitado + cpf de par validado na criação: a identidade validada entra, sem a marca identity_changed_at" do
    patient = registry_no_cpf_patient!
    citizen = verified_citizen!(35, full_name: "Lia Santos Moreira", sex: "female")
    # a mãe vem do par validado (sem desconhece_nome_mae)
    result = save(registry_registration_params(household, patient: patient).merge("cpf" => citizen.cpf, "identification" => registry_identification))
    expect(result).to be_ok
    expect(result.payload[:version].identity).to include("full_name" => "Lia Santos Moreira", "cpf" => citizen.cpf)
    expect(result.payload[:registration].identity_changed_at).to be_nil
  end

  it "família: precisa ser do domicílio e ativa; is_responsible bate com o responsável" do
    responsible = registry_patient!
    family = registry_family!(household, responsible: responsible)
    other_family = registry_family!(registry_household!)
    base = registry_registration_params(household, patient: responsible)
    expect(save(base.merge("family_id" => other_family.id)).details).to eq(path: "family_id")
    expect(save(base.merge("family_id" => family.id, "is_responsible" => false)).details).to eq(path: "is_responsible")
    expect(save(base.merge("family_id" => family.id, "is_responsible" => true))).to be_ok
    member = registry_patient!
    expect(save(registry_registration_params(household, patient: member).merge("family_id" => family.id, "is_responsible" => true)).details)
      .to eq(path: "is_responsible")
    expect(save(registry_registration_params(nil, patient: member).merge("family_id" => family.id)).details).to eq(path: "family_id")
  end

  it "sem domicílio exige team_id (fora de área, L7); fora da equipe → out_of_scope; técnico → cbo_not_allowed" do
    team = household.micro_area.team
    patient = registry_patient!
    expect(save(registry_registration_params(nil, patient: patient)).details).to eq(path: "team_id")
    result = save(registry_registration_params(team, patient: patient))
    expect(result).to be_ok
    expect(result.payload[:registration]).to have_attributes(household_id: nil, micro_area_id: nil, team_id: team.id)
    expect(patient.reload.address_street).to be_nil
    stranger = registry_nurse!(care_unit!)
    expect(save(registry_registration_params(household, patient: registry_patient!), by: stranger).reason).to eq(:out_of_scope)
    technician = screener!(team.health_unit, cbo: "322245")
    HealthTeamMember.create!(professional: technician.professional, health_team: team, cbo_code: "322245", started_on: Time.zone.today - 1)
    expect(save(registry_registration_params(household, patient: registry_patient!), by: technician).reason).to eq(:cbo_not_allowed)
    other_acs = registry_acs!(team.health_unit, team: team)
    expect(save(registry_registration_params(household, patient: registry_patient!), by: other_acs).reason).to eq(:out_of_scope)
  end

  it "microárea inativa nunca é destino → micro_area_id" do
    household.micro_area.update!(active: false)
    result = save(registry_registration_params(household, patient: registry_patient!), by: registry_nurse!(household.micro_area.team.health_unit,
                                                                                                         team: household.micro_area.team))
    expect(result.reason).to eq(:invalid_registration)
    expect(result.details).to eq(path: "micro_area_id")
  end

  it "domicílio que muda de microárea entre a leitura e a trava → stale_version, nada gravado" do
    other_area = registry_micro_area!(code: "09", team: household.micro_area.team)
    allow(TerritoryRegistry::Access).to receive(:registrar?).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap { Household.where(id: household.id).update_all(micro_area_id: other_area.id) }
    end
    result = save(registry_registration_params(household, patient: registry_patient!))
    expect(result.reason).to eq(:stale_version)
    expect(IndividualRegistration.count).to eq(0)
  end

  context "etnia (L17)" do
    it "raça/cor 05 com etnia sem código LEDI → invalid_ethnicity, nada gravado" do
      result = save(params(new_patient: new_patient, patient_demographics: { "race_color" => "05", "ethnicity" => "0300" }))
      expect(result.reason).to eq(:invalid_ethnicity)
      expect(result.details).to eq(path: "patient_demographics.ethnicity")
      expect(IndividualRegistration.count).to eq(0)
    end

    it "raça/cor 05 com etnia que tem código LEDI (0304 → 406) grava no paciente" do
      result = save(params(new_patient: new_patient, patient_demographics: { "race_color" => "05", "ethnicity" => "0304" }))
      expect(result).to be_ok
      expect(result.payload[:registration].patient).to have_attributes(race_color: "05", ethnicity: "0304")
    end

    it "outra raça/cor: a etnia não recusa (e não fica no paciente)" do
      result = save(params(new_patient: new_patient, patient_demographics: { "race_color" => "01", "ethnicity" => "0300" }))
      expect(result).to be_ok
      expect(result.payload[:registration].patient).to have_attributes(race_color: "01", ethnicity: nil)
    end
  end

  it "raça/cor obrigatória sem recusa; regras da ficha com o caminho do corpo" do
    result = save(params(new_patient: new_patient, patient_demographics: nil))
    expect(result.details).to eq(path: "patient_demographics.race_color")
    result = save(params(new_patient: new_patient, street_situation: nil))
    expect(result.details).to eq(path: "street_situation.status_situacao_rua")
    result = save(params(new_patient: new_patient, health_conditions: { "status_tem_diabetes" => "sim" }))
    expect(result.details).to eq(path: "health_conditions.status_tem_diabetes")
  end

  context "identidade (L4)" do
    it "paciente com par validado: nome, nascimento, sexo e mãe só leitura → identity_locked; o mesmo valor passa" do
      patient, citizen = exam_patient!(33, age: 40, sex: "female")
      base = registry_registration_params(household, patient: patient)
      result = save(base.merge("patient" => { "full_name" => "Outra Pessoa Qualquer" }))
      expect(result.reason).to eq(:identity_locked)
      expect(result.details).to eq(path: "patient.full_name")
      expect(save(base.merge("patient" => { "birth_date" => "1950-01-01" })).details).to eq(path: "patient.birth_date")
      expect(save(base.merge("patient" => { "full_name" => citizen.full_name, "sex" => "female" }))).to be_ok
    end

    it "paciente digitado sem par: a identidade do corpo vai para o paciente; recusa com patient.<campo>" do
      patient = registry_no_cpf_patient!
      base = registry_registration_params(household, patient: patient).merge("identification" => registry_identification)
      expect(save(base).details).to eq(path: "patient.mother_name")
      expect(save(base.merge("patient" => { "full_name" => "X" })).details).to eq(path: "patient.full_name")
      result = save(base.merge("patient" => { "full_name" => "Lia Santos Rocha", "mother_name" => "Carla Santos" }))
      expect(result).to be_ok
      expect(patient.reload).to have_attributes(full_name: "Lia Santos Rocha", mother_name: "Carla Santos")
      expect(result.payload[:version].identity).to include("full_name" => "Lia Santos Rocha")
    end
  end

  context "PATCH" do
    let(:registration) { save(params(new_patient: new_patient(cns: nil, no_cpf_reason: "5"))).payload[:registration] }

    it "versão esperada; nova versão; CNS grava no paciente (cns_taken se de outro); saída congela (invalid_transition)" do
      body = params("version" => 1)
      expect(save(body.merge("version" => 3), registration: registration).reason).to eq(:stale_version)
      expect(save(body.except("version"), registration: registration).details).to eq(path: "version")
      taken = registry_no_cpf_patient!
      expect(save(body.merge("cns" => taken.cns), registration: registration).reason).to eq(:cns_taken)
      result = save(body.merge("cns" => valid_cns(77)), registration: registration)
      expect(result).to be_ok
      expect(result.payload[:version].version).to eq(2)
      expect(registration.reload.patient.cns).to eq(valid_cns(77))
      expect(LediOutboxEntry.where(source_id: result.payload[:version].id)).to exist
      TerritoryRegistry::ExitRegistration.call(registration: registration.reload, params: { "reason" => "moved", "on" => Time.zone.today.iso8601 },
                                               by: acs)
      expect(save(body.merge("version" => 3), registration: registration.reload).reason).to eq(:invalid_transition)
    end

    it "CPF de outro paciente → cpf_taken; CPF de par validado: a identidade validada substitui a digitada numa versão só" do
      other = registry_patient!
      body = params("version" => 1)
      expect(save(body.merge("cpf" => other.cpf), registration: registration).reason).to eq(:cpf_taken)
      citizen = verified_citizen!(34, full_name: "Lia Santos Pereira", sex: "female")
      result = save(body.merge("cpf" => citizen.cpf), registration: registration)
      expect(result).to be_ok
      expect(registration.reload).to have_attributes(version: 2)
      expect(registration.identity_changed_at).to be_present
      expect(result.payload[:version].identity).to include("full_name" => "Lia Santos Pereira", "cpf" => citizen.cpf)
      expect(registration.versions.pluck(:origin)).to eq(%w[save save])
    end

    it "troca de domicílio copia o endereço do novo domicílio para o paciente" do
      other = registry_household!(micro_area: household.micro_area)
      address = { "street" => "Outra", "number" => "9" }
      TerritoryRegistry::SaveHousehold.call(params: registry_household_params(other).deep_merge("address" => address,
                                                                                                "version" => other.version),
                                            by: acs, household: other)
      result = save(params("version" => 1, "household_id" => other.id), registration: registration)
      expect(result).to be_ok
      expect(registration.reload.patient).to have_attributes(address_street: "Outra", address_number: "9")
    end
  end
end

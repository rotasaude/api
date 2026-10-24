require "rails_helper"

# Módulo 24a (ADR 0042): o banco garante o que o modelo não vê — versões só
# acréscimo (a re-cifra regrava só o cifrado), um cadastro ativo por
# paciente, saída uma vez e cadastro saído congelado, CPF ou justificativa,
# microárea de identidade fixa e conselho do profissional todo ou nenhum.
# Cada erro de SQL esperado roda num savepoint (`attempt`): sem ele, o erro
# aborta a transação do exemplo e a linha seguinte falha por outro motivo.
RSpec.describe "Cadastro territorial — imutabilidade e constraints" do
  before { registry_city! }
  after { Current.reset }

  let(:registration) { registry_registration! }

  # update_columns escreve os atributos na memória ANTES do UPDATE: depois de
  # uma recusa, o objeto fica com o valor recusado (use reload). E o `let`
  # preguiçoso avaliado dentro do savepoint nasce e morre com ele.
  def attempt(&) = ApplicationRecord.transaction(requires_new: true, &)

  it "versão de cadastro individual nunca muda nem some; sob re-cifra só os campos cifrados" do
    version = registration.versions.first
    expect { attempt { version.update_columns(version: 9) } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { attempt { IndividualRegistrationVersion.where(id: version.id).delete_all } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    CityEncryption.allowing_reencryption { version.update_columns(health_conditions: version.health_conditions) }
    expect { CityEncryption.allowing_reencryption { version.update_columns(origin: "exit") } }.to raise_error(ActiveRecord::StatementInvalid)
    expect(version.reload.health_conditions).to include("status_tem_diabetes" => true)
  end

  it "versão de domicílio idem" do
    version = registry_household!.versions.first
    expect { attempt { version.update_columns(property_type: "2") } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { attempt { HouseholdVersion.where(id: version.id).delete_all } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    CityEncryption.allowing_reencryption { version.update_columns(address: version.address) }
  end

  it "um cadastro ativo por paciente; saída só uma vez; cadastro saído congela" do
    duplicate = registration.attributes.except("id", "created_at", "updated_at")
    expect { attempt { IndividualRegistration.create!(duplicate) } }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_individual_registrations_one_active/)
    registration.update_columns(exit_reason: "moved", exited_on: Time.zone.today)
    expect { attempt { registration.update_columns(exit_reason: "death") } }.to raise_error(ActiveRecord::StatementInvalid, /frozen/)
    expect { attempt { registration.update_columns(version: 5) } }.to raise_error(ActiveRecord::StatementInvalid, /frozen/)
    expect { attempt { registration.delete } }.to raise_error(ActiveRecord::StatementInvalid, /never deleted/)
    CityEncryption.allowing_reencryption { registration.update_columns(refused: registration.refused) }
    expect(IndividualRegistration.active_registrations.where(patient_id: registration.patient_id)).to be_empty
  end

  it "óbito: data obrigatória; data e número da DO só com death" do
    registration
    expect { attempt { registration.update_columns(exit_reason: "death", exited_on: Time.zone.today) } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_individual_registrations_values/)
    expect { attempt { registration.update_columns(death_on: Time.zone.today) } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_individual_registrations_values/)
    expect { attempt { registration.update_columns(exit_reason: "moved", exited_on: Time.zone.today, death_certificate: "123456789") } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_individual_registrations_values/)
    registration.reload.update_columns(exit_reason: "death", exited_on: Time.zone.today, death_on: Time.zone.today - 1,
                                death_certificate: "123456789")
    expect(registration.reload.death_certificate).to eq("123456789")
  end

  it "patients: CPF ou justificativa, nunca os dois nem nenhum; CPF só de nulo para valor, levando a justificativa" do
    patient = Patient.create!(full_name: "Ana Clara Souza", birth_date: "2026-09-01", sex: "female", no_cpf_reason: "3")
    expect(patient.cpf_masked).to be_nil
    expect { attempt { patient.update_columns(no_cpf_reason: nil) } }.to raise_error(ActiveRecord::StatementInvalid, /ck_patients_cpf_or_reason/)
    expect { attempt { patient.update_columns(cpf: valid_cpf(91)) } }.to raise_error(ActiveRecord::StatementInvalid, /no-CPF reason/)
    patient.update_columns(cpf: valid_cpf(91), no_cpf_reason: nil)
    expect { attempt { patient.update_columns(cpf: valid_cpf(92)) } }.to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
    expect { attempt { patient.update_columns(cpf: nil, no_cpf_reason: "3") } }
      .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
    expect { Patient.create!(full_name: "Sem Nada", birth_date: "2000-01-01", sex: "male") }.to raise_error(ActiveRecord::RecordInvalid)
    expect(Patient.new(cpf: valid_cpf(93), no_cpf_reason: "3")).not_to be_valid
  end

  it "patients: CNS único quando presente, cifrado determinístico" do
    cns = valid_cns(1)
    patient = Patient.create!(full_name: "Ana Clara Souza", no_cpf_reason: "3", cns: cns)
    expect(Patient.find_by(cns: cns)).to eq(patient)
    expect { attempt { Patient.create!(full_name: "Outra Pessoa", no_cpf_reason: "3", cns: cns) } }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_patients_cns/)
    raw = ApplicationRecord.connection.select_value("SELECT cns FROM patients WHERE id = '#{patient.id}'")
    expect(raw).not_to include(cns)
  end

  it "microárea: código e equipe nunca mudam; código repetido na equipe recusado; nada se apaga" do
    area = registry_micro_area!(code: "01")
    team = area.team
    expect { attempt { area.update_columns(code: "02") } }.to raise_error(ActiveRecord::StatementInvalid, /never change/)
    expect { attempt { area.reload.update_columns(team_id: registry_team!.id) } }.to raise_error(ActiveRecord::StatementInvalid, /never change/)
    expect { attempt { MicroArea.create!(team: team, code: "01", name: "Outra") } }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { attempt { area.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    expect { attempt { MicroArea.create!(team: team, code: "00", name: "Zero") } }.to raise_error(ActiveRecord::RecordInvalid)
    area.reload.update_columns(name: "Norte", active: false)
  end

  it "domicílio e família: nada se apaga; a família não troca de domicílio nem de responsável" do
    household = registry_household!
    family = Family.create!(household: household, responsible_patient: registry_registration!(household: household).patient,
                            members_count: 3, income_band: "2", living_since: "2020-03")
    expect { attempt { household.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    expect { attempt { family.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    expect { attempt { family.update_columns(household_id: registry_household!.id) } }.to raise_error(ActiveRecord::StatementInvalid, /never change/)
    family.update_columns(moved_out: true, members_count: 2)
    expect(household.latest_version.version).to eq(1)
    raw = ApplicationRecord.connection.select_value("SELECT living_since FROM families WHERE id = '#{family.id}'")
    expect(raw).not_to include("2020-03")
  end

  it "professionals: conselho todo ou nenhum" do
    professional = registry_acs!.professional
    expect(professional.council).to be_nil
    expect { attempt { professional.update_columns(council_state: "PR") } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_professionals_council_all_or_none/)
    professional.council_state = "PR"
    expect(professional).not_to be_valid
    expect(professional.errors.attribute_names).to include(:council)
  end

  it "nada pessoal no inspect nem no banco em claro" do
    version = registration.versions.first
    expect(version.inspect).not_to include("Diabetes", "true", registration.patient.full_name)
    expect(registration.inspect).not_to include("false", registration.patient.full_name)
    raw = ApplicationRecord.connection.select_value("SELECT health_conditions FROM individual_registration_versions WHERE id = '#{version.id}'")
    expect(raw).not_to include("status_tem_diabetes")
  end
end

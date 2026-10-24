require "rails_helper"

# ADR 0040 (spec §2 decisões 2, 8, 9; plano, Desvios 5–7). Review Focus 1 e 2.
RSpec.describe CareLines::Suggest do
  include ActiveSupport::Testing::TimeHelpers

  before { care_city! }

  let(:today) { Time.zone.today }
  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let!(:team) { care_team!(unit, doctor) }
  let!(:diabetes) { adopted_line!("diabetes_c4") }

  it "problema ativo → sugestão pendente da equipe da última consulta, com o problema como evidência; idempotente" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    expect(described_class.run(today: today)).to eq(created: 1, closures: 0)
    suggestion = CareLineSuggestion.sole
    problem = patient.problems.sole
    expect(suggestion).to have_attributes(patient_id: patient.id, citizen_id: nil, care_line: diabetes, team: team, reason: "problem",
                                          status: "pending", evidence_ref: "patient_problem:#{problem.id}")
    expect(DomainEvent.where(name: "care_line_suggestion.created").last.payload).to eq("care_line_suggestion_id" => suggestion.id)
    expect(described_class.run(today: today)).to eq(created: 0, closures: 0)
  end

  it "idade e sexo e condição declarada olham pares validados sem paciente; par sem equipe não recebe" do
    elderly = adopted_line!("elderly_c6")
    neighborhood = care_neighborhood!(unit)
    older = care_citizen!(age: 72, sex: "female", neighborhood: neighborhood)
    homeless = care_citizen!(age: 75, sex: "male")
    declared = care_citizen!(age: 40, sex: "female", neighborhood: neighborhood)
    declare!(declared, "diabetes")
    described_class.run(today: today)
    expect(CareLineSuggestion.where(citizen_id: older.id).pluck(:care_line_id, :reason)).to eq([ [ elderly.id, "age_sex" ] ])
    expect(CareLineSuggestion.where(citizen_id: declared.id).pluck(:care_line_id, :reason)).to eq([ [ diabetes.id, "declared" ] ])
    expect(CareLineSuggestion.where(citizen_id: homeless.id)).not_to exist
  end

  it "recusada não volta por 365 dias; inscrito não recebe; linha inativa não sugere" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    described_class.run(today: today)
    CareLineSuggestion.sole.update!(status: "dismissed", decided_by_user: doctor, decided_at: Time.current, dismiss_reason: "Acompanha no ambulatório")
    expect(described_class.run(today: today + 1)).to eq(created: 0, closures: 0)
    expect(described_class.run(today: today + 366)[:created]).to eq(0) # created_at real ainda é hoje: o corte usa created_at
    travel_to(366.days.from_now) { expect(described_class.run(today: Time.zone.today)[:created]).to eq(1) }
    CareLineSuggestion.where(status: "pending").delete_all
    care_enrollment!(patient: patient, line: diabetes, team: team, by: doctor)
    expect(described_class.run(today: today)[:created]).to eq(0)
    diabetes.update!(active: false)
    other = care_patient!(age: 60, sex: "female", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    described_class.run(today: today)
    expect(CareLineSuggestion.where(patient_id: other.id)).not_to exist
  end

  it "encerramento só com todos os problemas elegíveis resolvidos; nunca encerra sozinho" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90], %w[cid10 E119] ], unit: unit, doctor: doctor)
    enrollment = care_enrollment!(patient: patient, line: diabetes, team: team, by: doctor)
    resolve_problem!(patient, "T90", by: doctor)
    expect(described_class.run(today: today)).to eq(created: 0, closures: 0)
    resolve_problem!(patient, "E119", by: doctor)
    expect(described_class.run(today: today)).to eq(created: 0, closures: 1)
    closure = CareLineSuggestion.sole
    expect(closure).to have_attributes(reason: "resolved_problem", enrollment_id: enrollment.id, patient_id: patient.id, team: team)
    expect(enrollment.reload.status).to eq("active")
    expect(described_class.run(today: today)[:closures]).to eq(0)
  end

  it "for_patient e for_citizen: só a pessoa do evento" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    care_patient!(age: 59, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    expect(described_class.for_patient(patient.id, today: today)).to eq(1)
    expect(CareLineSuggestion.pluck(:patient_id)).to eq([ patient.id ])
    citizen = care_citizen!(age: 30, sex: "female", neighborhood: care_neighborhood!(unit))
    declare!(citizen, "diabetes")
    expect(described_class.for_citizen(citizen.id, today: today)).to eq(1)
  end

  it "par com sugestão recusada que vira paciente não recebe outra por 365 dias" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    pair = Citizen.find_by!(patient_id: patient.id)
    CareLineSuggestion.create!(citizen: pair, care_line: diabetes, team: team, reason: "declared", status: "dismissed",
                               decided_by_user: doctor, decided_at: Time.current, dismiss_reason: "Acompanha no ambulatório")
    expect(described_class.run(today: today)).to eq(created: 0, closures: 0)
    expect(CareLineSuggestion.where(patient_id: patient.id)).not_to exist
  end

  it "encerramento duplicado da mesma inscrição é recusado pelo índice e convive com a sugestão de inscrição pendente" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    enrollment = care_enrollment!(patient: patient, line: diabetes, team: team, by: doctor)
    resolve_problem!(patient, "T90", by: doctor)
    described_class.run(today: today)
    attrs = { patient_id: patient.id, care_line_id: diabetes.id, team_id: team.id, reason: "resolved_problem", enrollment_id: enrollment.id }
    expect { CareLineSuggestion.create!(attrs) }.to raise_error(ActiveRecord::RecordNotUnique)
    CareLineSuggestion.create!(patient_id: patient.id, care_line_id: diabetes.id, team_id: team.id, reason: "problem")
    expect(CareLineSuggestion.where(patient_id: patient.id).pluck(:reason)).to contain_exactly("resolved_problem", "problem")
    expect(described_class.run(today: today)).to eq(created: 0, closures: 0)
  end

  it "a quarentena de 365 dias conta da decisão, não da criação da sugestão" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    CareLineSuggestion.create!(patient: patient, care_line: diabetes, team: team, reason: "problem", created_at: 300.days.ago)
    CareLineSuggestion.sole.update!(status: "dismissed", decided_by_user: doctor, decided_at: Time.current, dismiss_reason: "Acompanha no ambulatório")
    travel_to(100.days.from_now) { expect(described_class.run(today: Time.zone.today)[:created]).to eq(0) }
    travel_to(366.days.from_now) { expect(described_class.run(today: Time.zone.today)[:created]).to eq(1) }
  end

  it "sugestão aceita dentro de 365 dias não volta" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    CareLineSuggestion.create!(patient: patient, care_line: diabetes, team: team, reason: "problem", status: "accepted",
                               decided_by_user: doctor, decided_at: Time.current, created_at: 300.days.ago)
    travel_to(100.days.from_now) { expect(described_class.run(today: Time.zone.today)[:created]).to eq(0) }
    travel_to(366.days.from_now) { expect(described_class.run(today: Time.zone.today)[:created]).to eq(1) }
  end

  # Revisão final, I2 (extensão do Desvio 6): a inscrição encerrada também
  # segura a sugestão de inscrição por 365 dias (de ended_at); o óbito, para
  # sempre e em qualquer linha. Só a SUGESTÃO: a inscrição manual segue possível.
  def end_enrollment!(enrollment, reason, at)
    enrollment.update!(status: "ended", ended_reason: reason, ended_at: at, ended_by_user: doctor)
  end

  it "inscrição encerrada há menos de 365 dias não gera sugestão nova (run e for_patient); a inscrição manual segue possível" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    end_enrollment!(care_enrollment!(patient: patient, line: diabetes, team: team, by: doctor, enrolled_at: 2.years.ago), "other", 364.days.ago)
    expect(described_class.run(today: today)).to eq(created: 0, closures: 0)
    expect(described_class.for_patient(patient.id, today: today)).to eq(0)
    expect(CareLineSuggestion.where(patient_id: patient.id)).not_to exist
    manual = CareLines::Enroll.call(patient: patient, line: diabetes, team: team, by: doctor, today: today)
    expect(manual.payload[:enrollment]).to have_attributes(source: "manual", status: "active")
  end

  it "encerrada há 366 dias por discharge volta a sugerir" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    end_enrollment!(care_enrollment!(patient: patient, line: diabetes, team: team, by: doctor, enrolled_at: 2.years.ago), "discharge", 366.days.ago)
    expect(described_class.run(today: today)).to eq(created: 1, closures: 0)
    expect(CareLineSuggestion.sole).to have_attributes(patient_id: patient.id, care_line: diabetes, reason: "problem")
  end

  it "óbito em qualquer linha, mesmo há anos: nunca mais sugestão, nem de inscrição nem de encerramento; a inscrição manual segue possível" do
    hypertension = adopted_line!("hypertension_c5")
    adopted_line!("elderly_c6")
    patient = care_patient!(age: 72, sex: "male", problems: [ %w[ciap2 T90], %w[ciap2 K86] ], unit: unit, doctor: doctor)
    end_enrollment!(care_enrollment!(patient: patient, line: diabetes, team: team, by: doctor, enrolled_at: 3.years.ago), "death", 2.years.ago)
    care_enrollment!(patient: patient, line: hypertension, team: team, by: doctor)
    resolve_problem!(patient, "K86", by: doctor)
    expect(described_class.run(today: today)).to eq(created: 0, closures: 0)
    expect(described_class.for_patient(patient.id, today: today)).to eq(0)
    expect(CareLineSuggestion.where(patient_id: patient.id)).not_to exist
    manual = CareLines::Enroll.call(patient: patient, line: diabetes, team: team, by: doctor, today: today)
    expect(manual.payload[:enrollment]).to have_attributes(source: "manual", status: "active")
  end

  it "a consulta das inscrições encerradas é em lote: o número de SQL do run não cresce com o número de pacientes" do
    queries = lambda do
      count = 0
      counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { described_class.run(today: today) }
      count
    end
    ended = lambda do
      patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
      end_enrollment!(care_enrollment!(patient: patient, line: diabetes, team: team, by: doctor, enrolled_at: 2.years.ago), "moved", 10.days.ago)
    end
    ended.call
    small = queries.call
    4.times { ended.call }
    expect(queries.call).to eq(small)
    expect(CareLineSuggestion.count).to eq(0)
  end

  # Revisão final, Minor 1: a mesma pessoa uma vez só, por CPF.
  it "par validado sem paciente com o CPF de um paciente não recebe; dois pares sem paciente do mesmo CPF, só o mais antigo" do
    elderly = adopted_line!("elderly_c6")
    neighborhood = care_neighborhood!(unit)
    patient = care_patient!(age: 72, sex: "female")
    Citizen.find_by!(patient_id: patient.id).update!(neighborhood: neighborhood)
    twin = care_citizen!(age: 72, sex: "female", neighborhood: neighborhood)
    twin.update!(cpf: patient.cpf)
    older = care_citizen!(age: 75, sex: "male", neighborhood: neighborhood)
    newer = care_citizen!(age: 75, sex: "male", neighborhood: neighborhood)
    newer.update!(cpf: older.cpf)
    older.update_columns(created_at: 2.days.ago)

    described_class.run(today: today)
    expect(CareLineSuggestion.where(care_line: elderly).pluck(:patient_id, :citizen_id)).to contain_exactly([ patient.id, nil ], [ nil, older.id ])
    expect(described_class.for_citizen(twin.id, today: today) + described_class.for_citizen(newer.id, today: today)).to eq(0)
    population = CareLines::TeamPopulation.call(team: team, line: elderly, rules: elderly.eligibility)
    expect(population.map { |person, _| person.patient_id || person.citizen_id }).to contain_exactly(patient.id, older.id)
  end

  it "fronteira de lote: com BATCH 1 as duas pessoas são processadas (idade e sexo, e encerramento)" do
    stub_const("CareLines::Suggest::BATCH", 1)
    elderly = adopted_line!("elderly_c6")
    two = Array.new(2) { care_patient!(age: 72, sex: "female", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor) }
    described_class.run(today: today)
    expect(CareLineSuggestion.where(care_line: elderly).pluck(:patient_id)).to match_array(two.map(&:id))
    CareLineSuggestion.delete_all
    two.each do |patient|
      care_enrollment!(patient: patient, line: diabetes, team: team, by: doctor)
      resolve_problem!(patient, "T90", by: doctor)
    end
    expect(described_class.run(today: today)[:closures]).to eq(2)
    expect(CareLineSuggestion.where(reason: "resolved_problem").pluck(:patient_id)).to match_array(two.map(&:id))
  end

  # Módulo 24a (contrato §9; F-24.8): a saída do cadastro por óbito cala as
  # sugestões como a inscrição encerrada por óbito.
  it "saída do cadastro individual por óbito: nem sugestão de inscrição nem de encerramento" do
    registry_city!
    hypertension = adopted_line!("hypertension_c5")
    area = registry_micro_area!(code: "01", team: team)
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90], %w[ciap2 K86] ], unit: unit, doctor: doctor)
    care_enrollment!(patient: patient, line: hypertension, team: team, by: doctor)
    resolve_problem!(patient, "K86", by: doctor)
    registration = registry_registration!(patient: patient, household: registry_household!(micro_area: area))
    params = { "reason" => "death", "on" => today.iso8601, "death_on" => today.iso8601 }
    expect(TerritoryRegistry::ExitRegistration.call(registration: registration, params: params, by: registry_acs_of(area))).to be_ok
    expect(described_class.run(today: today)).to eq(created: 0, closures: 0)
    expect(described_class.for_patient(patient.id, today: today)).to eq(0)
    expect(CareLineSuggestion.where(patient_id: patient.id)).not_to exist
  end
end

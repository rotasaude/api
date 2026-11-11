require "rails_helper"
require Rails.root.join("db/city_migrate/20261104900002_add_psychosocial_care.rb").to_s

# Módulo 31 (ADR 0049): o banco do CAPS. Leito sem duas permanências que se
# cruzam (exclusion GiST, intervalo [)), uma matrícula aberta por paciente e
# CAPS, ação imutável (só o cancelamento, uma vez; mês fechado recusa), PTS e
# participante só acréscimo, RAAS do mês exportada congelada, fechamento do mês
# reaberto uma vez, telefone da unidade (P27) e nada clínico em inspect/as_json.
RSpec.describe "Esquema do módulo 31", type: :model do
  let!(:city) { psychosocial_city! }
  let(:caps) { caps!(modality: "caps_ad_iii") }

  # Escrita crua (delete, update_columns, SQL) que o banco recusa: sem savepoint,
  # a recusa aborta a transação do exemplo (o create!/update! já roda no dele).
  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  def action!(staff, **over)
    PsychosocialAction.create!({ health_unit: caps, sigtap_code: "0301080208", instrument: "raas_psi", performed_at: 1.hour.ago,
                                 month: Date.current.beginning_of_month, place: "caps", quantity: 1, professional_user: staff,
                                 cbo_code: "251510" }.merge(over))
  end

  it "o banco recusa duas permanências que se cruzam no mesmo leito; encostadas valem" do
    bed = bed!(caps)
    a = enrollment!(caps)
    b = enrollment!(caps)
    stay = ->(enrollment, from, to) do
      PsychosocialNightStay.create!(psychosocial_bed: bed, health_unit: caps, psychosocial_enrollment: enrollment, patient_id: enrollment.patient_id,
                                    started_at: from, expected_end_at: to, ended_at: to, end_reason: "Alta do acolhimento",
                                    started_by_user: a.reference_user, closed_by_user: a.reference_user)
    end
    stay.call(a, 2.days.ago.change(hour: 19), 1.day.ago.change(hour: 8))
    expect { stay.call(b, 1.day.ago.change(hour: 8), 1.day.ago.change(hour: 20)) }.not_to raise_error
    expect { stay.call(b, 1.day.ago.change(hour: 7), 1.day.ago.change(hour: 9)) }
      .to raise_error(ActiveRecord::ExclusionViolation, /excl_psychosocial_night_stays_bed/)
  end

  it "permanência aberta ocupa o leito até fechar, uma por paciente; fechada nunca muda" do
    bed = bed!(caps)
    e = enrollment!(caps)
    open = PsychosocialNightStay.create!(psychosocial_bed: bed, health_unit: caps, psychosocial_enrollment: e, patient_id: e.patient_id,
                                         started_at: 1.day.ago.change(hour: 19), expected_end_at: 1.day.from_now.change(hour: 8),
                                         started_by_user: e.reference_user)
    other = enrollment!(caps)
    expect do
      PsychosocialNightStay.create!(psychosocial_bed: bed, health_unit: caps, psychosocial_enrollment: other, patient_id: other.patient_id,
                                    started_at: 5.days.from_now, expected_end_at: 6.days.from_now, started_by_user: e.reference_user)
    end.to raise_error(ActiveRecord::ExclusionViolation)
    expect do
      PsychosocialNightStay.create!(psychosocial_bed: bed!(caps, label: "L2"), health_unit: caps, psychosocial_enrollment: e,
                                    patient_id: e.patient_id, started_at: 1.hour.ago, expected_end_at: 1.day.from_now,
                                    started_by_user: e.reference_user)
    end.to raise_error(ActiveRecord::RecordNotUnique, /idx_psychosocial_night_stays_open_patient/)
    refused(/only receives the closing/) { open.update_columns(expected_end_at: 2.days.from_now) }
    open.update!(ended_at: Time.current, end_reason: "Alta do acolhimento", closed_by_user: e.reference_user)
    refused(/closed stay never changes/) { open.update_columns(end_reason: "Outro motivo") }
    refused { open.delete }
  end

  it "uma matrícula aberta por paciente e CAPS; encerrada libera" do
    first = enrollment!(caps)
    expect { enrollment!(caps, patient: first.patient) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_psychosocial_enrollments_open/)
    first.update!(destination: "01", closed_on: Date.current, closed_by_user: first.reference_user)
    expect { enrollment!(caps, patient: first.patient) }.not_to raise_error
    refused { first.delete }
  end

  it "destino 00 nunca encerra; CAPS exige modalidade; modalidade e classificação só no CAPS" do
    e = enrollment!(caps)
    expect { e.update!(destination: "00", closed_on: Date.current, closed_by_user: e.reference_user) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_psychosocial_enrollments_closing/)
    expect { HealthUnit.create!(name: "CAPS sem modalidade", kind: "caps") }.to raise_error(ActiveRecord::RecordInvalid)
    expect { HealthUnit.new(name: "CAPS sem modalidade", kind: "caps").save!(validate: false) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_health_units_caps/)
    expect { HealthUnit.create!(name: "UBS com modalidade", kind: "ubs", caps_modality: "caps_ii") }.to raise_error(ActiveRecord::RecordInvalid)
    expect { HealthUnit.new(name: "UBS com modalidade", kind: "ubs", caps_modality: "caps_ii").save!(validate: false) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_health_units_caps/)
    expect { HealthUnit.new(name: "UBS classificada", kind: "ubs", service_classification: "001").save!(validate: false) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_health_units_caps/)
    expect { HealthUnit.new(name: "CAPS X", kind: "caps", caps_modality: "caps_x").save!(validate: false) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_health_units_caps/)
    expect([ caps.caps?, caps.night_capable?, caps!(modality: "caps_ii").night_capable? ]).to eq([ true, true, false ])
  end

  it "P27: telefone da unidade só com 10 ou 11 dígitos, ou nulo; o modelo normaliza" do
    unit = HealthUnit.create!(name: "UBS Fone", kind: "ubs", phone: "(41) 3350-1234")
    expect(unit.phone).to eq("4133501234")
    expect { unit.update!(phone: "4133") }.to raise_error(ActiveRecord::RecordInvalid)
    expect { unit.update!(phone: nil) }.not_to raise_error
    refused(/ck_health_units_phone/) { unit.update_columns(phone: "413350123") }
    refused(/ck_health_units_phone/) { unit.update_columns(phone: "41a3350123") }
  end

  it "ação é imutável: só o cancelamento, uma vez; mês fechado recusa inserção" do
    staff = caps_staff!(caps)
    action = action!(staff)
    refused(/only the cancellation/) { action.update_column(:quantity, 2) }
    action.update!(cancelled_at: Time.current, cancel_reason: "Registrada no usuário errado", cancelled_by_user: staff)
    expect { action.update!(cancel_reason: "Outro motivo qualquer") }.to raise_error(ActiveRecord::StatementInvalid, /cancelled once/)
    refused { action.reload.delete }
    PsychosocialMonthClosure.create!(health_unit: caps, month: Date.current.beginning_of_month, closed_by_user: staff, closed_at: Time.current)
    expect { action.dup.tap { |copy| copy.assign_attributes(cancelled_at: nil, cancel_reason: nil, cancelled_by_user: nil) }.save! }
      .to raise_error(ActiveRecord::StatementInvalid, /month closed/)
    expect { action!(staff, health_unit: caps!(modality: "caps_ii")) }.not_to raise_error
  end

  it "mês de ação e de RAAS é sempre o dia 1º" do
    staff = caps_staff!(caps)
    expect { action!(staff, month: Date.current.beginning_of_month + 1) }.to raise_error(ActiveRecord::StatementInvalid, /ck_psychosocial_actions_month/)
  end

  it "fechamento do mês: um ativo por CAPS e mês; reaberto uma vez libera outro" do
    staff = caps_staff!(caps, lead: true)
    month = Date.current.beginning_of_month
    closure = PsychosocialMonthClosure.create!(health_unit: caps, month: month, closed_by_user: staff, closed_at: Time.current)
    expect { PsychosocialMonthClosure.create!(health_unit: caps, month: month, closed_by_user: staff, closed_at: Time.current) }
      .to raise_error(ActiveRecord::RecordNotUnique)
    closure.update!(reopened_at: Time.current, reopened_by_user: staff, reopen_reason: "Faltou a ação do grupo de quarta")
    refused(/reopened once/) { closure.update_columns(reopened_at: Time.current + 1.minute) }
    refused { closure.delete }
    expect { PsychosocialMonthClosure.create!(health_unit: caps, month: month, closed_by_user: staff, closed_at: Time.current) }.not_to raise_error
  end

  it "versão do PTS e participante nunca mudam nem somem" do
    e = enrollment!(caps)
    plan = PsychosocialCarePlan.create!(psychosocial_enrollment: e, version: 1, needs: "Isolamento social", goals: [],
                                        intensity: "intensive", review_on: Date.current + 90, created_by_user: e.reference_user)
    expect(plan.reload.goals).to eq([])
    refused { plan.update_column(:intensity, "non_intensive") }
    refused { plan.delete }
    action = action!(caps_staff!(caps))
    participant = PsychosocialActionParticipant.create!(psychosocial_action: action, position: 1, psychosocial_enrollment: e, patient_id: e.patient_id)
    refused { participant.update_column(:position, 2) }
    refused { participant.delete }
    expect { PsychosocialActionParticipant.create!(psychosocial_action: action, position: 2, patient_id: e.patient_id, family_name: "Mãe") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_psychosocial_action_participants_who/)
  end

  it "RAAS do mês: uma por matrícula e mês; foto só fora de open; exportada congela" do
    e = enrollment!(caps)
    record = PsychosocialMonthlyRecord.find_by!(psychosocial_enrollment: e, month: e.started_on.beginning_of_month)
    expect { PsychosocialMonthlyRecord.create!(psychosocial_enrollment: e, health_unit: caps, month: record.month) }
      .to raise_error(ActiveRecord::RecordNotUnique)
    refused(/ck_psychosocial_monthly_records_snapshot/) { record.update_columns(status: "closed") }
    record.reload.update!(status: "closed", snapshot: { "cid_main" => "F200" }, closed_at: Time.current)
    refused(/never change/) { record.update_columns(month: record.month.prev_month) }
    record.update!(status: "exported")
    refused(/exported record never changes/) { record.update_columns(homeless: true) }
    refused { record.delete }
  end

  it "a re-cifra regrava só as colunas cifradas das tabelas imutáveis" do
    staff = caps_staff!(caps)
    action = action!(staff, notes: "Evolução estável, sem crise")
    action.update!(cancelled_at: Time.current, cancel_reason: "Registrada no usuário errado", cancelled_by_user: staff)
    expect { CityEncryption.allowing_reencryption { action.encrypt } }.not_to raise_error
    expect(action.reload).to have_attributes(notes: "Evolução estável, sem crise", cancel_reason: "Registrada no usuário errado")
    refused(/psychosocial_actions/) { CityEncryption.allowing_reencryption { action.update_columns(notes: "x", quantity: 2) } }
    e = enrollment!(caps)
    plan = PsychosocialCarePlan.create!(psychosocial_enrollment: e, version: 1, needs: "Isolamento social", goals: [ "Voltar ao trabalho" ],
                                        intensity: "intensive", review_on: Date.current + 90, created_by_user: e.reference_user)
    expect { CityEncryption.allowing_reencryption { plan.encrypt } }.not_to raise_error
    expect(plan.reload.goals).to eq([ "Voltar ao trabalho" ])
    record = PsychosocialMonthlyRecord.find_by!(psychosocial_enrollment: e)
    record.update!(status: "closed", snapshot: { "cid_main" => "F200" }, closed_at: Time.current)
    record.update!(status: "exported")
    expect { CityEncryption.allowing_reencryption { record.encrypt } }.not_to raise_error
    expect(record.reload.snapshot).to eq("cid_main" => "F200")
  end

  it "parâmetros: uma linha só, com os padrões do limite noturno e da revisão do PTS" do
    settings = PsychosocialSetting.current
    expect([ settings.id, settings.care_plan_review_days ]).to eq([ 1, 90 ])
    expect(settings.night_limits).to eq(AddPsychosocialCare::DEFAULT_NIGHT_LIMITS)
    expect { PsychosocialSetting.ensure_defaults! }.not_to(change { PsychosocialSetting.count })
    refused(/ck_psychosocial_settings_singleton/) do
      ApplicationRecord.connection.execute("INSERT INTO psychosocial_settings (id, updated_at) VALUES (2, now())")
    end
    refused { settings.delete }
  end

  it "TRUNCATE recusado nas 16 tabelas" do
    AddPsychosocialCare::TABLES.each do |table|
      refused(/TRUNCATE refused/) { ApplicationRecord.connection.execute("TRUNCATE #{table} CASCADE") }
    end
    expect(AddPsychosocialCare::TABLES.size).to eq(16)
  end

  it "papéis entram nas travas; nada clínico em inspect/as_json" do
    expect(Membership::PRIVILEGED_ROLES).to include("psychosocial_staff", "psychosocial_lead")
    expect(Membership::ROLES).to include(*AddPsychosocialCare::ROLES)
    expect(AddPsychosocialCare::HEALTH_UNIT_KINDS).to eq(HealthUnit::KINDS)
    expect(AddPsychosocialCare::CAPS_MODALITIES).to eq(HealthUnit::CAPS_MODALITIES)
    expect { caps_staff!(caps, lead: true) }.not_to raise_error
    e = enrollment!(caps)
    expect([ e.inspect, e.to_s, e.as_json.to_s ].join).not_to include("F200")
    expect(e.as_json).to eq("id" => e.id)
    expect(e.cid_main).to eq("F200")
    expect(e.patient.cns).to be_present
    expect(e).to be_open
  end
end

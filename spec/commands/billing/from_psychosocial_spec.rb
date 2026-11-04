require "rails_helper"

# Produção do CAPS no BPA (ADR 0049; contrato §8, §15 P2 e P3; plano, Desvio
# 11): só as ações bpa_c e bpa_i viram linha de performed_procedures (source
# psychosocial), uma por ação. BPA-C sem paciente nem CID, com a quantidade da
# ação; BPA-I com o paciente do único participante e o CID principal da
# matrícula, quando houver. Estabelecimento = o CAPS; profissional e CBO os da
# ação. RAAS nunca vai. Cancelar a ação cancela a linha (Billing::Cancel);
# linha já no arquivo de competência fechada impede o cancelamento da ação.
RSpec.describe Billing::FromPsychosocial do
  let!(:city) { psychosocial_city!(billing: true) }
  let(:caps) { caps! }
  let(:staff) { caps_staff!(caps, cbo: "251510") }

  it "BPA-C: uma linha por ação, sem paciente, com a quantidade da ação; nunca uma por participante" do
    action = record_action!(caps, staff, sigtap_code: "0301080313", quantity: 3,
                                         participants: [ { patient_id: caps_patient!.id }, { patient_id: caps_patient!.id } ])
    line = described_class.call(action)
    expect(line).to have_attributes(source: "psychosocial", patient_id: nil, cid10: nil, quantity: 3, instrument: "bpa_c",
                                    health_unit_id: caps.id, cbo_code: "251510", professional_user_id: staff.id,
                                    psychosocial_action_id: action.id, recorded_by_user_id: nil, character: "elective",
                                    performed_on: action.performed_at.in_time_zone.to_date, billable: true, blocking_reasons: [])
    expect(line.billing_period).to have_attributes(health_unit_id: caps.id, competence: action.performed_at.in_time_zone.strftime("%Y%m"))
    expect(described_class.call(action)).to be_nil
    expect(PerformedProcedure.where(psychosocial_action_id: action.id).count).to eq(1)
    expect(Billing::Json.procedure(line)).to include(patient: nil, source: "psychosocial",
                                                     source_ref: { type: "psychosocial_action", id: action.id })
  end

  it "BPA-I leva o paciente do único participante; RAAS nunca vai; ação cancelada não vai" do
    patient = caps_patient!
    reception_action = record_action!(caps, staff, sigtap_code: "0301080232", participants: [ { patient_id: patient.id } ])
    expect(described_class.call(reception_action)).to have_attributes(instrument: "bpa_i", patient_id: patient.id, cid10: nil, quantity: 1)
    raas = record_action!(caps, staff, sigtap_code: "0301080208", participants: [ { enrollment_id: enrollment!(caps).id } ])
    expect(described_class.call(raas)).to be_nil
    cancelled = record_action!(caps, staff, sigtap_code: "0301080313")
    Psychosocial::CancelAction.call(action: cancelled, reason: "Lançada em duplicidade", by: staff)
    expect(described_class.call(cancelled.reload)).to be_nil
    expect(PerformedProcedure.where(psychosocial_action_id: [ raas.id, cancelled.id ])).to be_empty
  end

  it "BPA-I de participante matriculado leva o CID principal da matrícula" do
    enrollment = enrollment!(caps, cid: "F200")
    action = PsychosocialAction.create!(health_unit: caps, sigtap_code: "0301080232", instrument: "bpa_i", performed_at: Time.current,
                                        month: Date.current.beginning_of_month, place: "caps", quantity: 1, professional_user: staff,
                                        cbo_code: "251510")
    PsychosocialActionParticipant.create!(psychosocial_action: action, position: 1, psychosocial_enrollment: enrollment,
                                          patient_id: enrollment.patient_id)
    expect(described_class.call(action)).to have_attributes(instrument: "bpa_i", patient_id: enrollment.patient_id, cid10: "F200")
  end

  it "matriciamento (Task 11): a ação BPA-C do matriciamento vira uma linha sem paciente; o caso compartilhado não entra" do
    patient = caps_patient!
    team = HealthTeam.create!(health_unit: HealthUnit.create!(name: "UBS Boa Vista", kind: "ubs"), ine: "0000123456", kind: "70",
                              name: "eSF Boa Vista")
    matrix = matrix_case!(caps, team, patient, "Caso discutido com a equipe da UBS", by: staff)
    action = matrix.psychosocial_matrix_support.psychosocial_action
    line = described_class.call(action)
    expect(line).to have_attributes(source: "psychosocial", instrument: "bpa_c", patient_id: nil, sigtap_code: "0301080305",
                                    health_unit_id: caps.id)
    expect(PerformedProcedure.where(patient_id: patient.id)).to be_empty
  end

  it "erro do banco no INSERT → InsertFailed só com o id da ação, sem a causa" do
    action = record_action!(caps, staff, sigtap_code: "0301080313")
    allow(Billing::Record).to receive(:insert!).and_raise(ActiveRecord::StatementInvalid, "DETAIL: Failing row contains (F200, Fulano)")
    expect { described_class.call(action) }.to raise_error(described_class::InsertFailed) { |e|
      expect(e.message).to eq("psychosocial_action_id=#{action.id} ActiveRecord::StatementInvalid")
      expect(e.cause).to be_nil
    }
  end

  describe "banco (900003)" do
    let(:patient) { caps_patient! }

    it "recusa linha sem paciente de outra fonte, fonte psychosocial sem ação e ação em outra fonte; uma linha por ação" do
      action = record_action!(caps, staff, sigtap_code: "0301080313")
      expect { raw_procedure!(unit: caps, patient: nil, professional: staff, source: "manual") }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_performed_procedures_patient/)
      expect { raw_procedure!(unit: caps, patient: patient, professional: staff, source: "psychosocial") }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_performed_procedures_source_ref/)
      expect { raw_procedure!(unit: caps, patient: patient, professional: staff, source: "manual", psychosocial_action: action) }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_performed_procedures_source_ref/)
      raw_procedure!(unit: caps, patient: nil, professional: staff, source: "psychosocial", psychosocial_action: action, instrument: "bpa_c",
                     cid10: nil, cbo_code: "251510", sigtap_code: "0301080313")
      expect { raw_procedure!(unit: caps, patient: nil, professional: staff, source: "psychosocial", psychosocial_action: action, instrument: "bpa_c", cid10: nil) }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_performed_procedures_psychosocial_action/)
    end

    it "a linha sem paciente aceita o instrumento regravado (o CHECK não depende dele) e a ação não muda depois" do
      action = record_action!(caps, staff, sigtap_code: "0301080313")
      line = raw_procedure!(unit: caps, patient: nil, professional: staff, source: "psychosocial", psychosocial_action: action,
                            instrument: "bpa_c", cid10: nil, cbo_code: "251510", sigtap_code: "0301080313")
      expect { line.update!(instrument: "not_bpa", billable: false, blocking_reasons: %w[not_bpa_instrument]) }.not_to raise_error
      expect { line.update_columns(psychosocial_action_id: record_action!(caps, staff, sigtap_code: "0301080313").id) }
        .to raise_error(ActiveRecord::StatementInvalid, /clinical content is immutable/)
    end
  end

  describe "cancelamento (Psychosocial::CancelAction)" do
    let(:clerk) { billing_clerk! }

    it "cancelar a ação cancela a linha na mesma transação, com um motivo fixo (nunca o texto do CAPS)" do
      action = record_action!(caps, staff, sigtap_code: "0301080305")
      line = described_class.call(action)
      result = Psychosocial::CancelAction.call(action: action, reason: "Matriciamento lançado em duplicidade", by: staff)
      expect(result).to be_ok
      expect(line.reload).to have_attributes(status: "cancelled", cancelled_by_user_id: staff.id,
                                             cancel_reason: Psychosocial::CancelAction::BILLING_CANCEL_REASON)
      expect(line.cancel_reason).not_to include("duplicidade")
      expect(DomainEvent.where(name: "performed_procedure.cancelled").map { |e| e.payload["performed_procedure_id"] }).to eq([ line.id ])
    end

    it "linha já cancelada pelo faturamento: a ação cancela mesmo assim" do
      action = record_action!(caps, staff, sigtap_code: "0301080305")
      line = described_class.call(action)
      expect(Billing::Cancel.call(procedure: line, reason: "Lançamento conferido e retirado", by: clerk)).to be_ok
      expect(Psychosocial::CancelAction.call(action: action, reason: "Matriciamento lançado em duplicidade", by: staff)).to be_ok
      expect(action.reload).to be_cancelled
      expect(line.reload.cancel_reason).to eq("Lançamento conferido e retirado")
    end

    it "linha no arquivo de competência fechada → already_exported, nada muda; reaberta a competência, cancela" do
      billing_settings!
      action = record_action!(caps, staff, sigtap_code: "0301080305")
      line = described_class.call(action)
      closed = Billing::Close.call(period: line.billing_period, by: clerk)
      expect(closed).to be_ok
      expect(line.reload.billing_export_id).to eq(closed.payload[:export].id)

      result = Psychosocial::CancelAction.call(action: action, reason: "Matriciamento lançado em duplicidade", by: staff)
      expect(result.reason).to eq(:already_exported)
      expect(action.reload).not_to be_cancelled
      expect(line.reload.status).to eq("recorded")
      expect(DomainEvent.where(name: %w[psychosocial.action_cancelled performed_procedure.cancelled])).to be_empty

      expect(Billing::Reopen.call(period: line.billing_period.reload, reason: "Correção do faturamento do CAPS", by: clerk)).to be_ok
      expect(Psychosocial::CancelAction.call(action: action, reason: "Matriciamento lançado em duplicidade", by: staff)).to be_ok
      expect(line.reload.status).to eq("cancelled")
    end

    it "trava na ordem do ledger: CAPS → competência → ação → linha" do
      action = record_action!(caps, staff, sigtap_code: "0301080305")
      described_class.call(action)
      locks = []
      ActiveSupport::Notifications.subscribed(->(*, payload) { locks << payload[:sql] if payload[:sql].to_s.match?(/FOR (SHARE|UPDATE)/) },
                                              "sql.active_record") do
        Psychosocial::CancelAction.call(action: action, reason: "Matriciamento lançado em duplicidade", by: staff)
      end
      tables = locks.map { |sql| sql[/FROM "(\w+)"/, 1] }
      expect(tables.uniq).to eq(%w[health_units billing_periods psychosocial_actions performed_procedures])
    end
  end
end

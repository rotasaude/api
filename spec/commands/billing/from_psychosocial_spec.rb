require "rails_helper"
require Rails.root.join("db/city_migrate/20261104900003_add_psychosocial_billing_source.rb").to_s

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

  # P3: participante matriculado só dá BPA-I com um código que tem `02` e não
  # tem `09`. A amostra não tem esse código; a release de M-2 do spec o cria.
  it "BPA-I de participante matriculado (código 02 sem 09) leva o CID principal da matrícula" do
    month = Date.current.beginning_of_month << 2
    release = TerminologyRelease.create!(kind: "sigtap", version: month.strftime("%Y%m"), source_sha256: "d" * 64, imported_by: "rspec",
                                         imported_at: Time.current, status: "importing")
    SigtapProcedure.create!(release: release, code: "0301080232", name: "ACOLHIMENTO INICIAL POR CAPS")
    SigtapProcedureInstrument.create!(release: release, procedure_code: "0301080232", instrument_code: "02", instrument_name: "BPA (INDIVIDUALIZADO)")
    SigtapProcedureCbo.create!(release: release, procedure_code: "0301080232", cbo_code: "251510")
    release.update!(status: "active", activated_at: Time.current)
    enrollment = enrollment!(caps, cid: "F200", started_on: month)
    action = record_action!(caps, staff, sigtap_code: "0301080232", performed_at: month.in_time_zone.change(hour: 10) + 9.days,
                                         participants: [ { enrollment_id: enrollment.id } ])
    expect(action.instrument).to eq("bpa_i")
    expect(described_class.call(action)).to have_attributes(instrument: "bpa_i", patient_id: enrollment.patient_id, cid10: "F200",
                                                            performed_on: month + 9)
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

    it "a migração espelha as fontes do modelo" do
      expect(AddPsychosocialBillingSource::SOURCES).to eq(PerformedProcedure::SOURCES - %w[urgency])
    end

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

    # [tabela, modo] de cada SELECT ... FOR ... da chamada, na ordem.
    def locks_of
      locks = []
      ActiveSupport::Notifications.subscribed(lambda { |*, payload|
        sql = payload[:sql].to_s
        mode = sql[/FOR (NO KEY UPDATE|KEY SHARE|SHARE|UPDATE)/, 1]
        locks << [ sql[/FROM "(\w+)"/, 1], mode ] if mode
      }, "sql.active_record") { yield }
      locks.uniq
    end

    it "a gravação trava o CAPS com FOR NO KEY UPDATE (serializa com o FOR SHARE do cancelamento) e depois a competência" do
      action = record_action!(caps, staff, sigtap_code: "0301080305")
      expect(locks_of { described_class.call(action) })
        .to eq([ [ "health_units", "NO KEY UPDATE" ], [ "billing_periods", "SHARE" ] ])
    end

    it "linha exportada entre a leitura e a trava da competência (fechamento em curso) → already_exported, nunca 500" do
      billing_settings!
      action = record_action!(caps, staff, sigtap_code: "0301080305")
      line = described_class.call(action)
      stale = PerformedProcedure.find(line.id)
      expect(Billing::Close.call(period: line.billing_period, by: clerk)).to be_ok
      allow(PerformedProcedure).to receive(:find_by).and_call_original
      allow(PerformedProcedure).to receive(:find_by).with(psychosocial_action_id: action.id).and_return(stale)
      expect(Billing::Cancel).not_to receive(:call) # a releitura recusa antes; o Billing::Cancel é só a rede

      result = Psychosocial::CancelAction.call(action: action, reason: "Matriciamento lançado em duplicidade", by: staff)

      expect(result.reason).to eq(:already_exported)
      expect(action.reload).not_to be_cancelled
      expect(line.reload.status).to eq("recorded")
      expect(DomainEvent.where(name: %w[psychosocial.action_cancelled performed_procedure.cancelled])).to be_empty
    end

    it "already_exported do Billing::Cancel vira 409 already_exported, nunca LineCancelRefused" do
      action = record_action!(caps, staff, sigtap_code: "0301080305")
      line = described_class.call(action)
      allow(Billing::Cancel).to receive(:call).and_return(Result.fail(:already_exported))

      result = Psychosocial::CancelAction.call(action: action, reason: "Matriciamento lançado em duplicidade", by: staff)

      expect(result.reason).to eq(:already_exported)
      expect(Psychosocial::BaseController::FAILURE_STATUS.fetch(:already_exported)).to eq(:conflict)
      expect(action.reload).not_to be_cancelled
      expect(line.reload.status).to eq("recorded")
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

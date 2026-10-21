require "rails_helper"

# ADR 0039 (Invariantes; spec §4): procedimento só acréscimo no conteúdo
# clínico (a crítica, o cancelamento uma vez e o arquivo que o incluiu
# andam; o CBO só nasce de NULL); competência imutável no estabelecimento e
# na competência, versão só cresce; arquivo nunca alterado; nada se apaga.
RSpec.describe "Tabelas do faturamento (ADR 0039)" do
  before { billing_city! }

  let(:unit) { upa! }
  let(:doctor) { doctor!(unit) }
  let(:patient) { billing_patient! }
  let!(:procedure) { raw_procedure!(unit: unit, patient: patient, professional: doctor) }
  let(:conn) { ApplicationRecord.connection }

  def rolled_back = ApplicationRecord.transaction(requires_new: true) do
    yield
    raise ActiveRecord::Rollback
  end

  def refused(pattern, &block)
    expect { rolled_back(&block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  it "procedimento: conteúdo clínico imutável, sem DELETE, cancelamento uma vez" do
    refused(/clinical content is immutable/) { procedure.update_columns(sigtap_code: "0301010072") }
    refused(/clinical content is immutable/) { procedure.update_columns(performed_on: procedure.performed_on - 1) }
    refused(/append-only/) { conn.execute("DELETE FROM performed_procedures WHERE id = '#{procedure.id}'") }
    procedure.update!(billable: false, blocking_reasons: %w[cbo_not_allowed])
    procedure.update!(status: "cancelled", cancel_reason: "Lançado em duplicidade", cancelled_at: Time.current, cancelled_by_user: doctor)
    refused(/cancellation is final/) { procedure.update_columns(status: "recorded", cancel_reason: nil, cancelled_at: nil, cancelled_by_user_id: nil) }
  end

  it "o CBO só nasce de NULL" do
    blank = raw_procedure!(unit: unit, patient: patient, professional: doctor, cbo_code: nil)
    blank.update!(cbo_code: "225125")
    refused(/cbo_code only fills once/) { blank.update_columns(cbo_code: "223505") }
  end

  it "checks: um estabelecimento só, faturável sem motivo, cancelado com motivo" do
    refused(/ck_performed_procedures_establishment/) { raw_procedure!(unit: unit, patient: patient, professional: doctor, exam_provider: lab_provider!) }
    refused(/ck_performed_procedures_billable/) { procedure.update_columns(billable: true, blocking_reasons: %w[cid_required]) }
    refused(/ck_performed_procedures_cancelled/) { procedure.update_columns(status: "cancelled") }
    refused(/ck_performed_procedures_quantity/) { raw_procedure!(unit: unit, patient: patient, professional: doctor, quantity: 1000) }
  end

  it "competência: estabelecimento e competência imutáveis, versão só cresce, sem DELETE" do
    period = BillingPeriod.create!(health_unit: unit, competence: Time.zone.today.strftime("%Y%m"))
    refused(/establishment and competence are immutable/) { period.update_columns(competence: "202001") }
    period.update!(status: "closed", version: 1, closed_at: Time.current, closed_by_user: doctor)
    refused(/version only grows/) { period.update_columns(version: 0) }
    refused(/append-only/) { conn.execute("DELETE FROM billing_periods WHERE id = '#{period.id}'") }
    refused(/ck_billing_periods_establishment/) { BillingPeriod.create!(competence: "202609") }
  end

  it "arquivo: nunca alterado nem apagado; conteúdo e motivos cifrados" do
    period = BillingPeriod.create!(health_unit: unit, competence: Time.zone.today.strftime("%Y%m"))
    export = BillingExport.create!(billing_period: period, version: 1, cnes: unit.cnes, competence: period.competence, file: "01#BPA#\r\n",
                                   sha256: "a" * 64, lines_bpa_c: 1, lines_bpa_i: 0, sheets: 1, control_field: 1111,
                                   generated_by_user: doctor, generated_at: Time.current)
    refused(/append-only/) { export.update_columns(sha256: "b" * 64) }
    refused(/append-only/) { conn.execute("DELETE FROM billing_exports WHERE id = '#{export.id}'") }
    expect(conn.select_value("SELECT file FROM billing_exports WHERE id = '#{export.id}'")).not_to include("#BPA#")
    procedure.update!(status: "cancelled", cancel_reason: "Lançado em duplicidade", cancelled_at: Time.current, cancelled_by_user: doctor)
    expect(conn.select_value("SELECT cancel_reason FROM performed_procedures WHERE id = '#{procedure.id}'")).not_to include("duplicidade")
    expect(CityEncryption::CITY_KEYED_TARGETS).to include([ PerformedProcedure, :cancel_reason ], [ BillingPeriod, :reopened_reason ],
                                                           [ BillingExport, :file ], [ Patient, :race_color ], [ Patient, :address_street ])
    expect(conn.select_value("SELECT address_street FROM patients WHERE id = '#{patient.id}'")).not_to include("Novembro")
    expect(export.inspect).not_to include("#BPA#")
  end

  it "papel billing_clerk aceito pelo banco e privilegiado" do
    expect { billing_clerk! }.not_to raise_error
    expect(Membership::PRIVILEGED_ROLES).to include("billing_clerk")
  end
end

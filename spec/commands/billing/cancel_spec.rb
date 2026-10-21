require "rails_helper"

# Contrato §3 com B8: cancelar com motivo (10..500, cifrado); uma vez; 409 already_exported se o
# procedimento entrou no arquivo de uma competência fechada; depois da
# reabertura, pode.
RSpec.describe Billing::Cancel do
  before { billing_city! }

  let(:unit) { upa! }
  let(:doctor) { doctor!(unit) }
  let(:procedure) { recorded_procedure!(unit: unit, professional: doctor) }

  it "cancela com motivo e publica só o id" do
    result = described_class.call(procedure: procedure, reason: "  Lançado em duplicidade ", by: doctor)
    expect(result.payload[:procedure]).to have_attributes(status: "cancelled", cancel_reason: "Lançado em duplicidade", cancelled_by_user_id: doctor.id)
    expect(DomainEvent.where(name: "performed_procedure.cancelled").last.payload).to eq("performed_procedure_id" => procedure.id)
  end

  it "motivo obrigatório e até 500; cancelado não cancela de novo" do
    expect(described_class.call(procedure: procedure, reason: " ", by: doctor).reason).to eq(:reason_required)
    expect(described_class.call(procedure: procedure, reason: "Curto    ", by: doctor).reason).to eq(:reason_required)
    expect(described_class.call(procedure: procedure, reason: "x" * 501, by: doctor).reason).to eq(:reason_required)
    expect(described_class.call(procedure: procedure, reason: 7, by: doctor).reason).to eq(:reason_required)
    described_class.call(procedure: procedure, reason: "Erro de digitação", by: doctor)
    expect(described_class.call(procedure: procedure.reload, reason: "Erro de digitação", by: doctor).reason).to eq(:invalid_transition)
  end

  it "409 se já entrou no arquivo de competência fechada; reaberta, cancela" do
    period = procedure.billing_period
    export = BillingExport.create!(billing_period: period, version: 1, cnes: unit.cnes, competence: period.competence, file: "x",
                                   sha256: "a" * 64, lines_bpa_c: 0, lines_bpa_i: 1, sheets: 1, control_field: 1111,
                                   generated_by_user: doctor, generated_at: Time.current)
    procedure.update!(billing_export: export)
    period.update!(status: "closed", version: 1, closed_at: Time.current, closed_by_user: doctor)
    expect(described_class.call(procedure: procedure, reason: "Erro de digitação", by: doctor).reason).to eq(:already_exported)
    period.update!(status: "open", reopened_reason: "Correção do CNS", reopened_at: Time.current, reopened_by_user: doctor)
    expect(described_class.call(procedure: procedure, reason: "Erro de digitação", by: doctor)).to be_ok
  end
end

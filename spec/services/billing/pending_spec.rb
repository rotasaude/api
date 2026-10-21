require "rails_helper"

# Contrato §5 com B6: pendências recalculadas na hora (sem gravar), só de
# procedimento BPA não faturável; correção pelo primeiro motivo corrigível;
# o item traz o que a tela mostra.
RSpec.describe Billing::Pending do
  before { billing_city! }

  let(:unit) { upa! }
  let(:doctor) { doctor!(unit) }
  let(:patient) { billing_patient! }

  it "lista o corrigível, com a forma de B6; ignora o faturável e o que não é BPA" do
    recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    apac = recorded_procedure!(unit: unit, professional: doctor, patient: patient, sigtap_code: "0604320124", cid10: nil)
    cid = recorded_procedure!(unit: unit, professional: doctor, patient: patient, cid10: nil)
    items = described_class.call(cid.billing_period)
    expect(items).to eq([ { procedure_id: cid.id, reasons: %w[cid_required], fix: "procedure", performed_on: cid.performed_on.iso8601,
                            sigtap_code: "0301060029", label: "ATENDIMENTO DE URGENCIA C/ OBSERVACAO ATE 24 HORAS EM ATENCAO ESPECIALIZADA",
                            patient: { id: patient.id, display_name: "Maria Aparecida da Silva" },
                            professional: { user_id: doctor.id, name: doctor.professional.professional_name } } ])
    expect(items.map { |i| i[:procedure_id] }).not_to include(apac.id)
    expect(described_class::FIX).to include("missing_professional_cns" => "professional", "missing_required_patient_field" => "patient",
                                            "missing_establishment_cnes" => "establishment")
  end

  it "recalcula sem gravar: o cadastro corrigido some da lista antes do fechamento" do
    unit.update!(cnes: nil)
    procedure = recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    expect(described_class.call(procedure.billing_period).sole).to include(fix: "establishment", reasons: %w[missing_establishment_cnes])
    unit.update!(cnes: billing_cnes)
    expect(described_class.call(procedure.billing_period)).to eq([])
    expect(procedure.reload.blocking_reasons).to eq(%w[missing_establishment_cnes])
  end
end

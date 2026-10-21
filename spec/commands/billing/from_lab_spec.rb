require "rails_helper"

# Contrato §4 (F-22.3): cada item do PRIMEIRO laudo liberado do laboratório
# municipal vira procedimento (source lab_report, estabelecimento =
# laboratório, profissional = liberador com o CBO do vínculo dele, data =
# coleta, quantidade 1). Retificação não cria; idempotente por item;
# liberador sem vínculo = pendência de CBO. §13 E10: o original já
# retificado (replaces_report_id nulo) ainda vale.
RSpec.describe Billing::FromLab do
  before { billing_city!(lab: true) }

  let(:provider) { lab_provider! }
  let(:lead) { lab_releaser!(provider, lead: true).tap { |user| link_professional!(user, create_unit("UBS #{SecureRandom.hex(2)}"), cbo: "221205") } }
  let(:glucose) { lab_exam!(provider: provider) }

  def released_report(req)
    item = type!(req.items.first, { glicose: "98" })
    result = Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "advanced", totp: totp_for(lead), by: lead)
    raise "liberação recusada: #{result.reason}" if result.failure?

    result.payload[:report]
  end

  it "cria um procedimento por item, faturável em BPA-C, com a data da coleta" do
    req = received_requisition!(provider: provider, exams: [ glucose ])
    report = released_report(req)
    expect(described_class.call(report)).to eq(1)
    procedure = PerformedProcedure.find_by!(lab_report_item_id: report.report_items.first.id)
    collected = req.samples.first.reload.collected_at.in_time_zone.to_date
    expect(procedure).to have_attributes(source: "lab_report", exam_provider_id: provider.id, health_unit_id: nil, patient_id: req.patient_id,
                                         professional_user_id: lead.id, cbo_code: "221205", sigtap_code: "0202010473", quantity: 1,
                                         performed_on: collected, instrument: "bpa_c", billable: true, recorded_by_user_id: nil)
    expect(procedure.billing_period).to have_attributes(exam_provider_id: provider.id, status: "open")
  end

  it "idempotente por item; laudo que retifica outro, retirado ou pendente de assinatura não cria" do
    req = received_requisition!(provider: provider, exams: [ glucose ])
    report = released_report(req)
    described_class.call(report)
    expect(described_class.call(report)).to eq(0)
    # O caminho real da retificação é o do 21b (rectification_spec); aqui basta a forma do laudo novo.
    expect(described_class.call(report.dup.tap { |r| r.replaces_report_id = report.id })).to eq(0)
    expect(described_class.call(report.dup.tap { |r| r.status = "withdrawn" })).to eq(0)
    expect(described_class.call(report.dup.tap { |r| r.status = "pending_signature" })).to eq(0)
    expect(PerformedProcedure.where(exam_provider_id: provider.id).count).to eq(1)
  end

  it "E10: original já retificado antes do consumidor rodar ainda gera a produção, uma vez" do
    req = received_requisition!(provider: provider, exams: [ glucose ])
    report = released_report(req)
    report.update!(status: "rectified")
    expect(described_class.call(report)).to eq(1)
    expect(described_class.call(report)).to eq(0)
    expect(PerformedProcedure.where(exam_provider_id: provider.id).count).to eq(1)
  end

  it "liberador sem vínculo: grava com a pendência de CBO" do
    deputy = lab_releaser!(provider, deputy: true)
    req = received_requisition!(provider: provider, exams: [ glucose ])
    item = type!(req.items.first, { glicose: "98" })
    lead # o RT precisa existir para liberar
    report = Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "advanced", totp: totp_for(deputy), by: deputy).payload[:report]
    described_class.call(report)
    expect(PerformedProcedure.find_by!(lab_report_item_id: report.report_items.first.id))
      .to have_attributes(cbo_code: nil, billable: false, blocking_reasons: %w[missing_professional_cbo])
  end
end

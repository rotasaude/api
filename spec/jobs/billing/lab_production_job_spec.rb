require "rails_helper"

# A liberação publica lab_report.released; o consumidor (idempotente por
# evento e por item) chama Billing::FromLab só com procedure_billing ligado.
RSpec.describe Billing::LabProductionJob, type: :job do
  before { billing_city!(lab: true) }

  let(:provider) { lab_provider! }
  let(:lead) { lab_releaser!(provider, lead: true).tap { |user| link_professional!(user, create_unit("UBS #{SecureRandom.hex(2)}"), cbo: "221205") } }

  def report!
    req = received_requisition!(provider: provider, exams: [ lab_exam!(provider: provider) ])
    item = type!(req.items.first, { glicose: "98" })
    Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "advanced", totp: totp_for(lead), by: lead).payload[:report]
  end

  def args(report, event_id: SecureRandom.uuid)
    { event_id: event_id, event_name: "lab_report.released", city_slug: Current.city.slug, payload: { "lab_report_id" => report.id } }
  end

  it "o evento da liberação está ligado ao consumidor" do
    expect(DomainEvents.registry["lab_report.released"].map(&:job)).to eq([ "Billing::LabProductionJob" ])
  end

  it "cria a produção; o mesmo evento de novo não duplica" do
    report = report!
    payload = args(report)
    described_class.new.perform(**payload)
    described_class.new.perform(**payload)
    expect(PerformedProcedure.where(exam_provider_id: provider.id, source: "lab_report").count).to eq(1)
  end

  it "com o interruptor desligado, nada" do
    report = report!
    Platform::Features.set!(city: Current.city, key: "procedure_billing", enabled: false, maintainer: ledi_maintainer!)
    described_class.new.perform(**args(report))
    expect(PerformedProcedure.count).to eq(0)
  end
end

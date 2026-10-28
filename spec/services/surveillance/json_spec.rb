require "rails_helper"

# Contrato §2 e §15 K5: a forma <notification> montada na mão (o as_json do
# modelo é redigido de propósito).
RSpec.describe Surveillance::Json do
  before { surveillance_city! }

  let(:unit) { create_unit("UBS Json #{SecureRandom.hex(2)}") }

  it "paciente sem CPF: has_cpf false e CNS só com os 4 últimos dígitos; rede de segurança sem notificador nem bairro" do
    patient = registry_no_cpf_patient!
    n = notification!(patient: patient, origin: "safety_net", unit: unit)
    json = described_class.notification(n)
    expect(json[:patient]).to eq(id: patient.id, display_name: "Lia Santos", has_cpf: false, cns_masked: patient.cns_masked)
    expect(json[:patient][:cns_masked]).to match(/\A\*\*\* \*\*\*\* \*\*\*\* \d{4}\z/)
    expect(json).to include(origin: "safety_net", status: "possible", notifier: nil, neighborhood: nil, consultation_id: nil)
    expect(json[:events].map { |e| [ e[:status], e[:by] ] }).to eq([ [ "possible", nil ] ])
  end

  it "list_item não traz form nem events" do
    n = notification!(patient: surveillance_patient!(61), unit: unit)
    expect(described_class.list_item(n).keys).not_to include(:form, :events)
    expect(described_class.notification(n, full: false).keys).not_to include(:form, :events)
    expect(described_class.notification(n).keys).to include(:form, :events)
  end

  it "vencida: possible ou notified com o prazo passado" do
    n = notification!(patient: surveillance_patient!(62), unit: unit, suspected_at: 10.days.ago)
    expect(described_class.list_item(n)[:overdue]).to be(true)
    n.update_columns(status: "investigating")
    expect(described_class.list_item(n.reload)[:overdue]).to be(false)
  end

  it "doença local desativada: mantém o nome" do
    local = LocalNotifiableDisease.create!(code: "local_antiga", name: "Agravo antigo", deadline: "weekly", cid10: [], ciap2: [],
                                           repeat_after_days: 30, active: true, updated_by_user: surveillance_officer!)
    n = notification!(patient: surveillance_patient!(63), unit: unit, disease_code: "local_antiga")
    expect(described_class.list_item(n)[:disease]).to eq(code: "local_antiga", name: "Agravo antigo", deadline: "weekly")
    local.update!(active: false)
    expect(described_class.list_item(n)[:disease][:name]).to eq("Agravo antigo")
  end

  it "doença que a lista vigente não traz mais: o próprio código como nome" do
    n = notification!(patient: surveillance_patient!(64), unit: unit)
    allow(Surveillance::Diseases).to receive(:all).and_return([])
    expect(described_class.list_item(n)[:disease]).to eq(code: "dengue", name: "dengue", deadline: n.deadline)
  end
end

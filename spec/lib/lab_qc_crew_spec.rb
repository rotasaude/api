require "rails_helper"
require Rails.root.join("lib/lab_crew").to_s
require Rails.root.join("lib/lab_qc_crew").to_s

# Semente de dev do 21c (dev fictício que imita o real): dois aparelhos
# (bioquímica e hematologia) ligados às versões dos exames; material de dois
# níveis com lote e referência da bula (os mesmos códigos e alvos do
# fake-middleware); 20 corridas aprovadas de história (sugestão de
# referência); itens de estoque com lotes, um vencendo e um abaixo do
# mínimo; lote em uso. Idempotente.
RSpec.describe LabQcCrew do
  before do
    lab_city!(fake_middleware: true)
    Lab::Templates::Load.sigtap_codes.each { |c| SigtapProcedure.find_or_create_by!(release: sigtap_release!, code: c) { |p| p.name = "EXAME #{c}" } }
    Maintainer.find_by(email_address: "dev@local") ||
      Maintainer.create!(email_address: "dev@local", password: "dev-password-123", otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    ExamProvider.create!(name: LabCrew::LAB, kind: "municipal", cnes: "2385123")
    %w[UBS\ Jardim\ das\ Flores UBS\ Vila\ Esperança].each { |name| HealthUnit.find_or_create_by!(name: name) { |u| u.kind = "ubs" } }
    LabCrew.seed_platform!
    LabCrew.seed_current_city(slug: "curitiba", password: "dev-password", admin: lab_admin!)
  end

  let(:lab) { ExamProvider.find_by!(name: LabCrew::LAB) }

  it "aparelhos, CIQ com história, estoque com alertas e lote em uso; segunda rodada não muda nada" do
    result = described_class.seed_current_city(slug: "curitiba", admin: lab_admin!)
    expect(result[:switch]).to start_with("ligado")
    expect(LabInstrument.where(exam_provider: lab).pluck(:hl7_equipment_id)).to contain_exactly("BIO-01", "HEM-01")
    expect(LabExam.find_by!(exam_provider: lab, sigtap_code: "0202010473").current_version.lab_instrument.hl7_equipment_id).to eq("BIO-01")
    expect(LabExam.find_by!(exam_provider: lab, sigtap_code: "0202020380").current_version.lab_instrument.hl7_equipment_id).to eq("HEM-01")
    lot = LabQcLot.find_by!(lot_number: FakeMiddleware::QcPlan::LOT)
    expect(lot.level_barcodes).to eq(FakeMiddleware::QcPlan::BARCODES)
    expect(LabQcTarget.where(lab_qc_lot: lot).pluck(:source)).to eq(%w[package_insert] * 4)
    expect(LabQcRun.where(status: "approved").count).to eq(20)
    expect([ LabQcBlock.count, LabQcValue.where.not(outcome: "ok").count ]).to eq([ 0, 0 ])
    expect(Lab::Qc::Suggestions.list(provider_id: lab.id).map(&:runs)).to eq([ 20 ] * 4)
    alerts = Lab::Inventory::Alerts.call(provider_id: lab.id)
    expect(alerts[:expiring].map { |l| l[:lot_number] }).to eq([ "GL2603" ])
    expect(alerts[:below_minimum].map { |x| x[:name] }).to eq([ "Creatinina Jaffé — kit 300 testes" ])
    expect(LabSupplyInUse.current.joins(:lab_supply_lot).pluck("lab_supply_lots.lot_number")).to contain_exactly("GL2609", "CR2611")
    snapshot = -> { [ LabInstrument, LabExamVersion, LabQcMaterial, LabQcLot, LabQcTarget, LabQcValue, LabSupply, LabSupplyLot, LabSupplyMovement, LabSupplyInUse ].map(&:count) }
    expect { described_class.seed_current_city(slug: "curitiba", admin: lab_admin!) }.not_to(change { snapshot.call })
  end

  it "fora de Curitiba não liga nada" do
    expect(described_class.seed_current_city(slug: "maringa", admin: lab_admin!)[:switch]).to start_with("desligado")
  end
end

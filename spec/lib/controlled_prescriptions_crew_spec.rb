require "rails_helper"
require Rails.root.join("lib/controlled_prescriptions_crew")

# Semente de dev do 19d (ADR 0034): dev é fictício mas imita o real — só
# Curitiba liga, dentista com CRO e CBO real, contatos plausíveis, um bloco
# simulado; reexecutar não duplica nada.
RSpec.describe ControlledPrescriptionsCrew do
  before do
    documents_city!
    Maintainer.find_or_create_by!(email_address: "dev@local") do |maintainer|
      maintainer.password = "dev-password"
      maintainer.otp_secret = ROTP::Base32.random
      maintainer.otp_enabled_at = Time.current
    end
  end

  let!(:unit) { HealthUnit.create!(name: described_class::UNIT, kind: "ubs") }
  let!(:doctor) { doctor!(unit).tap { |user| user.update!(email_address: "profissional@curitiba.demo") } }
  let(:admin) { municipal_admin! }

  it "liga, cria o dentista, os contatos e o bloco; idempotente" do
    first = described_class.seed_current_city(slug: "curitiba", password: "dev-password", admin: admin)
    expect(first[:switch]).to eq("ligado")
    expect(Sncr::Mock.on?(Current.city)).to be(true)
    dentist = User.find_by!(email_address: "dentista@curitiba.demo")
    expect(dentist.professional).to have_attributes(council: "CRO")
    expect(dentist.professional.cpf).to be_present
    expect(dentist.professional.links.active.pluck(:cbo_code)).to eq([ "223208" ])
    expect([ doctor, dentist ].map { |user| user.professional.reload.prescriber_contact }).to all(be_present)
    expect(Sncr::Stock.summary(user: doctor, simulated: true).transform_values { |row| row[:free] }).to eq("rce" => 1000, "ret" => 1000)

    described_class.seed_current_city(slug: "curitiba", password: "dev-password", admin: admin)
    expect(SncrNumberBatch.where(user_id: doctor.id).count).to eq(2)
    expect(User.where(email_address: "dentista@curitiba.demo").count).to eq(1)
  end

  # FW6: com número livre do tipo no simulado, não pede bloco (não gasta cota);
  # depois de esgotar, o próximo bloco vem na faixa seguinte (não é absorvido).
  it "bloco só para o tipo sem estoque livre; esgotado, o próximo bloco não colide com o anterior" do
    prefix = Time.zone.today.strftime("%y%m")
    Sncr::Stock.record_batch!(user: doctor, kind: "rce", simulated: true,
                              block: Sncr::Client::Block.new(first: "#{prefix}.1-41.0500001", last: "#{prefix}.1-41.0500001", quantity: 1))
    first = described_class.seed_current_city(slug: "curitiba", password: "dev-password", admin: admin)
    expect(first[:block]).to eq("1.000 RET simulados")
    expect(SncrNumberBatch.where(user_id: doctor.id).group(:kind).count).to eq("rce" => 1, "ret" => 1)

    allow(SncrNumber).to receive(:available).and_return(SncrNumber.none) # o estoque livre acabou
    expect(described_class.ensure_block(doctor)).to eq("1.000 RCE + 1.000 RET simulados")
    ret = SncrNumberBatch.where(user_id: doctor.id, kind: "ret").order(:month_request).last
    expect(ret).to have_attributes(month_request: 2, quantity: 1000)
    expect(SncrNumber.where(batch_id: ret.id).count).to eq(1000)
    expect(SncrNumber.where(user_id: doctor.id, kind: "ret", simulated: true).count).to eq(2000)
    expect(SncrNumber.where(user_id: doctor.id, kind: "rce", simulated: true).count).to eq(1001)
  end

  it "grava endereço e telefone nos formatos do esquema, pela normalização da Task 10" do
    described_class.seed_current_city(slug: "curitiba", password: "dev-password", admin: admin)
    [ doctor, User.find_by!(email_address: "dentista@curitiba.demo") ].each do |user|
      contact = user.professional.reload.prescriber_contact
      normalized, field = ClinicalDocuments::Address.normalize(contact["address"])
      expect(field).to be_nil
      expect(contact["address"]).to eq(normalized)
      expect(contact["address"]).to include("uf" => "PR", "zip" => match(/\A\d{8}\z/))
      expect(contact["phone"]).to match(/\A\d{10,11}\z/)
    end
  end

  it "o dentista tem CNS e CPF com dígito válido" do
    described_class.seed_current_city(slug: "curitiba", password: "dev-password", admin: admin)
    professional = User.find_by!(email_address: "dentista@curitiba.demo").professional
    nums = professional.cpf.chars.map(&:to_i)
    expect(professional.cpf).to match(/\A\d{11}\z/)
    expect(nums[9]).to eq(CitizenIdentity::Cpf.check_digit(nums[0, 9]))
    expect(nums[10]).to eq(CitizenIdentity::Cpf.check_digit(nums[0, 10]))
    expect(Professionals::Cns.valid?(professional.cns)).to be(true)
  end

  it "outra cidade: nada liga" do
    expect(described_class.seed_current_city(slug: "maringa", password: "x", admin: admin)[:switch]).to eq("desligado (só Curitiba liga)")
    expect(Platform::Features.enabled?(Current.city, "controlled_prescriptions")).to be(false)
  end
end

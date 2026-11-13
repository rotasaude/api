require "rails_helper"
require "webmock/rspec"
require Rails.root.join("lib/vaccination_crew").to_s
require_relative "../../lib/fake_rnds/app"

# Semente de dev do módulo 29 (ADR 0047) no banco de teste (nunca no de dev),
# com o mínimo do elenco anterior: o admin, o almoxarife do 27a, a UBS Jardim
# das Flores (sem CNES, como no dev) e o IBGE da cidade. Cada exemplo prova o
# que a prova no navegador precisa achar sem preparo manual, e a dose de
# exemplo é entregue de ponta a ponta ao FakeRnds::App em processo
# (WebMock#to_rack). Idempotente; a saída nunca leva dado de paciente.
RSpec.describe VaccinationCrew do
  let!(:city) { clinical_city! }
  let(:base) { "http://fake-rnds.test:8094" }
  let(:fake) { FakeRnds::App.new(timeout_delay: 0) }
  let(:room) { VaccineRoom.find_by!(name: described_class::ROOM) }
  let(:central) { StockLocation.find_by!(kind: "cold_chain_central") }

  # A cadeia anterior do db/seeds.rb, uma vez por arquivo (api#159).
  seed_once do
    clinical_city!
    cnes_city!
    staff_with("admin@curitiba.demo", "municipal_admin")
    staff_with("almoxarifado@curitiba.demo", "stock_keeper")
    Maintainer.create!(email_address: "dev@local", password: "s3nha-forte-1", otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    create_unit(CareLinesCrew::UNIT)
    cnes_snapshot!
  end

  before { Current.city = City.find(city.id) }

  after do
    Rails.cache.clear
    Current.reset
  end

  def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")

  def user(prefix) = User.find_by!(email_address: "#{prefix}@curitiba.demo")

  def balance(location, code) = StockMovement.where(stock_location_id: location.id, immunobiological_code: code).sum(:quantity)

  def counts
    [ VaccineRoom.count, VaccineRoomStaff.count, StockLocation.count, StockLot.count, StockMovement.count, StockTransfer.count, StockOpening.count,
      ColdChainEquipment.count, IntegrationCredential.count, Immunization.count, RndsOutboxEntry.count, VaccinationRecordCheck.count,
      CnesProfessionalBond.count, Patient.count, CityFeature.count ]
  end

  it "liga os interruptores e deixa a RNDS simulada utilizável, com a sala, a equipe e o go-live" do
    result = seed
    expect(result[:switch]).to eq("ligado (vaccination)")
    expect(result[:rnds]).to eq("RNDS simulada utilizável")
    expect(Vaccination::Gate.usable?(city)).to be(true)
    expect(Rnds::Gate.usable?(city)).to be(true)
    expect(Rnds::Mock.on?(city)).to be(true)
    expect(room.health_unit.name).to eq(CareLinesCrew::UNIT)
    expect(VaccinationSetting.current.go_live_on).to eq(Time.zone.today - 1.year)
    expect(room.staff.active.pluck(:role)).to contain_exactly("vaccinator", "room_lead")
    expect(user("vacinadora").professional).to have_attributes(professional_name: "Vera Vacinadora", council: "COREN")
    expect(user("vacina.responsavel").professional.professional_name).to eq("Rita Responsável")
    expect(user("vacinadora").professional.links.active.pluck(:cbo_code)).to eq([ "322205" ])
    expect(user("vacina.responsavel").professional.links.active.pluck(:cbo_code)).to eq([ "223505" ])
    expect(result[:users].map { |u| [ u[:email], u[:role] ] })
      .to contain_exactly([ "vacinadora@curitiba.demo", "vaccinator" ], [ "vacina.responsavel@curitiba.demo", "room_lead" ])
  end

  it "põe o CNES na unidade e o CNS da vacinadora no retrato, e a NT 115 passa" do
    seed
    unit = room.health_unit
    expect(unit.cnes).to match(/\A\d{7}\z/)
    bonds = CnesSnapshot.order(competence: :desc).first.bonds.where(cnes: unit.cnes)
    expect(bonds.map { |bond| [ bond.cns, bond.cbo_code ] }).to eq([ [ user("vacinadora").professional.cns, "322205" ] ])
  end

  it "abre a rede de frio com o almoxarife do 27a e os 4 lotes (penta, VIP, SCR, BCG) e manda metade à sala" do
    seed
    expect(central.name).to eq("Rede de frio municipal")
    expect(StockLocationStaff.active.where(stock_location_id: central.id).map(&:user)).to eq([ user("almoxarifado") ])
    expect(StockLot.where(item_kind: "immunobiological").pluck(:immunobiological_code, :manufacturer_key))
      .to contain_exactly(%w[42 serum], %w[22 sanofi], %w[24 biomanguinhos], %w[15 serum])
    expect(StockLot.where(item_kind: "immunobiological").pluck(:expires_on)).to all(be > Time.zone.today)
    # rede de frio: entrada (frascos × doses) menos o que seguiu; sala: o recebido menos a dose de exemplo
    expect(%w[42 22 24 15].map { |code| balance(central, code) }).to eq([ 30, 100, 50, 50 ])
    expect(%w[42 22 24 15].map { |code| balance(room.stock_location, code) }).to eq([ 29, 100, 50, 50 ])
    expect(StockTransfer.sole.status).to eq("received")
  end

  it "põe a Geladeira 1 na sala e a credencial rnds com o PFX de teste aceito pelo fake-rnds" do
    seed
    expect(ColdChainEquipment.where(stock_location_id: room.stock_location_id).pluck(:name, :kind, :min_c, :max_c))
      .to eq([ [ "Geladeira 1", "refrigerator", 2, 8 ] ])
    credential = IntegrationCredential.find_by!(kind: "rnds")
    expect(credential.requester_cnes).to eq(room.health_unit.cnes)
    certificate = OpenSSL::PKCS12.new(credential.pfx_bytes, credential.pfx_password).certificate
    expect(certificate.subject.to_s).to eq("/CN=Rota Saude Simulado")
    expect(certificate.not_after).to be > 5.years.from_now
    expect(Platform::Features.usable?(city, "rnds_immunization")).to be(true)
  end

  it "grava a credencial pelo comando: evento e auditoria da plataforma" do
    seed
    expect(DomainEvent.where(name: "integration_credential.changed").last.payload).to eq("kind" => "rnds", "user_id" => user("admin").id)
    expect(PlatformEvent.where(name: "rnds.credential_set").last.payload).to eq("city_id" => city.id)
  end

  it "retoma o recebimento de uma transferência enviada e não recebida" do
    allow(Pharmacy::ReceiveTransfer).to receive(:call).and_return(Result.fail(:location_inactive))
    expect { seed }.to raise_error(/recebimento na sala/)
    expect(StockTransfer.sole.status).to eq("sent")
    allow(Pharmacy::ReceiveTransfer).to receive(:call).and_call_original
    seed
    expect(StockTransfer.sole.status).to eq("received")
    expect(balance(room.stock_location, "22")).to eq(100)
  end

  it "grava a dose de exemplo de uma criança de dois meses com a caderneta conferida e na fila da RNDS" do
    seed
    dose = Immunization.sole
    expect(dose).to have_attributes(immunobiological_code: "42", dose_code: "1", transcription: false)
    expect(dose.vaccinator_user).to eq(user("vacinadora"))
    expect(dose.patient.age).to eq(0)
    expect(Date.iso8601(dose.patient.birth_date)).to be >= VaccinationSetting.current.go_live_on
    expect(VaccinationRecordCheck.where(patient_id: dose.patient_id).pluck(:mode)).to eq([ "born_after_go_live" ])
    expect(RndsOutboxEntry.where(immunization_id: dose.id).pluck(:kind, :status)).to eq([ %w[application pending] ])
  end

  it "a RNDS simulada aceita a dose quando o job roda com o FakeRnds::App em processo" do
    seed
    Rnds::Client.reset_cache!
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("FAKE_RNDS_URL").and_return(base)
    stub_request(:any, /\A#{Regexp.escape(base)}/).to_rack(fake)
    Rnds::DeliverJob.perform_now
    entry = RndsOutboxEntry.sole
    expect(entry).to have_attributes(status: "accepted", rnds_id: fake.accepted.last[:id], error: nil, attempts: 1)
    expect(fake.log.last[2]["authorization"]).to eq(user("vacinadora").professional.cns)
  end

  it "é idempotente: repetir não muda nenhuma contagem nem a credencial" do
    seed
    credential = IntegrationCredential.find_by!(kind: "rnds")
    before = counts
    secret = credential.secret
    again = seed
    expect(counts).to eq(before)
    expect(IntegrationCredential.find_by!(kind: "rnds").secret).to eq(secret)
    expect(again[:lots]).to eq(4)
    expect(again[:doses]).to eq(1)
  end

  it "não troca o go-live que já foi gravado" do
    admin = user("admin")
    Vaccination::SaveSettings.call(attrs: { "go_live_on" => "2026-01-15" }, by: admin)
    seed
    expect(VaccinationSetting.current.go_live_on).to eq(Date.new(2026, 1, 15))
  end

  it "fora de Curitiba e sem o mantenedor de dev não liga nada" do
    expect(described_class.seed_current_city(slug: "outra", password: "dev-password")).to include(switch: "fora", rooms: [], users: [])
    Maintainer.where(email_address: "dev@local").destroy_all
    expect(described_class.seed_current_city(slug: "curitiba", password: "dev-password")[:switch]).to start_with("desligado")
    expect(VaccineRoom.count).to eq(0)
  end

  it "recusa rodar em ambiente implantado" do
    allow(Rota).to receive(:deployed?).and_return(true)
    expect { seed }.to raise_error(/só de dev/)
  end

  it "a saída traz só e-mail, papel e otpauth: nunca dado de paciente nem do certificado" do
    lines = described_class.summary_lines(seed, password: "dev-password").join("\n")
    expect(lines).to include("vacinadora@curitiba.demo (vaccinator)", "vacina.responsavel@curitiba.demo (room_lead)", "otpauth://")
    patient = Immunization.sole.patient
    expect(lines).not_to include(patient.full_name, patient.cpf, patient.cns, described_class::CERTIFICATE_PASSWORD)
  end
end

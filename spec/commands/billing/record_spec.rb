require "rails_helper"

# ADR 0039 (spec §5.1, §5.3, §5.4; contrato §3 e §5): grava sempre, com a
# crítica nos campos; competência do estabelecimento faturante nasce aberta;
# UBS sem competência; procedimento de competência fechada vai para a
# próxima aberta, atrasado; entradas inválidas recusadas sem gravar nada.
RSpec.describe Billing::Record do
  include ActiveSupport::Testing::TimeHelpers

  before do
    travel_to(Time.zone.local(Time.zone.today.year, Time.zone.today.month, 15, 12, 0, 0))
    billing_city!
  end

  after { travel_back }

  let(:unit) { upa! }
  let(:doctor) { doctor!(unit) }
  let(:patient) { billing_patient! }
  let(:today) { Time.zone.today }
  let(:establishment) { Billing::Establishment.for_unit(unit) }

  def record(over = {}, establishment: self.establishment, professional: doctor)
    described_class.call(patient: patient, establishment: establishment, professional: professional, source: "manual", recorded_by: professional,
                         params: { "performed_on" => today.iso8601, "sigtap_code" => "0301060029", "quantity" => 1, "cid10" => "I10" }.merge(over))
  end

  it "grava faturável na competência do mês, que nasce aberta, e publica só ids" do
    procedure = record.payload[:procedure]
    expect(procedure).to have_attributes(instrument: "bpa_i", billable: true, blocking_reasons: [], cbo_code: "225125", source: "manual",
                                         billing_competence: today.strftime("%Y%m"), late: false, sigtap_fallback: false,
                                         character: "elective", recorded_by_user_id: doctor.id)
    expect(procedure.billing_period).to have_attributes(status: "open", version: 0, health_unit_id: unit.id, competence: today.strftime("%Y%m"))
    event = DomainEvent.where(name: "performed_procedure.recorded").order(:occurred_at).last
    expect(event.payload).to eq("performed_procedure_id" => procedure.id, "source" => "manual", "billable" => true)
  end

  it "sempre grava: não faturável fica com o motivo" do
    procedure = record({ "cid10" => nil }).payload[:procedure]
    expect(procedure).to have_attributes(billable: false, blocking_reasons: %w[cid_required], status: "recorded")
  end

  it "UBS nunca ganha competência" do
    ubs = create_unit("UBS #{SecureRandom.hex(2)}")
    ubs.update!(cnes: billing_cnes)
    link_professional!(doctor, ubs, cbo: "225125")
    procedure = record({}, establishment: Billing::Establishment.for_unit(ubs)).payload[:procedure]
    expect(procedure).to have_attributes(billable: false, blocking_reasons: %w[establishment_is_aps], billing_period_id: nil, billing_competence: nil)
    expect(BillingPeriod.where(health_unit_id: ubs.id)).to be_empty
  end

  it "recusa entrada inválida sem gravar nada" do
    {
      { "sigtap_code" => "030106002" } => :invalid_sigtap_code, { "sigtap_code" => 301_060_029 } => :invalid_sigtap_code,
      { "quantity" => 0 } => :invalid_quantity, { "quantity" => 1000 } => :invalid_quantity, { "quantity" => "1" } => :invalid_quantity,
      { "performed_on" => (today + 1).iso8601 } => :invalid_date,
      { "performed_on" => (today << 4).end_of_month.iso8601 } => :invalid_date, { "performed_on" => "15/10/2026" } => :invalid_date,
      { "cid10" => "I1" } => :invalid_cid10, { "cid10" => "Z999" } => :invalid_cid10, { "character" => "emergency" } => :invalid_character
    }.each do |over, reason|
      expect(record(over).reason).to eq(reason), over.inspect
    end
    expect(PerformedProcedure.count).to eq(0)
    expect(BillingPeriod.count).to eq(0)
  end

  it "aceita a data até o 1º dia da competência de 3 meses antes e CID com ponto" do
    result = record({ "performed_on" => (today << 3).beginning_of_month.iso8601, "cid10" => "e11.9" })
    expect(result).to be_ok
    expect(result.payload[:procedure].cid10).to eq("E119")
  end

  it "atraso de competência: competência fechada empurra para a próxima aberta, com late" do
    previous = (today << 1).strftime("%Y%m")
    BillingPeriod.create!(health_unit: unit, competence: previous, status: "closed", version: 1, closed_at: Time.current, closed_by_user: doctor)
    procedure = record({ "performed_on" => (today << 1).iso8601 }).payload[:procedure]
    expect(procedure).to have_attributes(billing_competence: today.strftime("%Y%m"), late: true, performed_on: today << 1)
  end

  it "duas competências fechadas seguidas: pula as duas" do
    [ 2, 1 ].each do |back|
      BillingPeriod.create!(health_unit: unit, competence: (today << back).strftime("%Y%m"), status: "closed", version: 1,
                            closed_at: Time.current, closed_by_user: doctor)
    end
    procedure = record({ "performed_on" => (today << 2).iso8601 }).payload[:procedure]
    expect(procedure).to have_attributes(billing_competence: today.strftime("%Y%m"), late: true)
  end

  # §13 E18: competência ≤ última fechada, mesmo sem período próprio, é
  # atrasada e vai para a primeira aberta depois da última fechada; nunca
  # nasce período no passado.
  it "competência antiga sem período próprio (M-1 fechada, M-2 sem período) cai em M, atrasada" do
    BillingPeriod.create!(health_unit: unit, competence: (today << 1).strftime("%Y%m"), status: "closed", version: 1,
                          closed_at: Time.current, closed_by_user: doctor)
    procedure = record({ "performed_on" => (today << 2).iso8601 }).payload[:procedure]
    expect(procedure).to have_attributes(billing_competence: today.strftime("%Y%m"), late: true, performed_on: today << 2)
    expect(procedure.billing_period).to have_attributes(status: "open", competence: today.strftime("%Y%m"))
    expect(BillingPeriod.where(health_unit_id: unit.id).pluck(:competence))
      .to contain_exactly((today << 1).strftime("%Y%m"), today.strftime("%Y%m"))
  end

  it "competência posterior à última fechada segue na própria, sem atraso" do
    BillingPeriod.create!(health_unit: unit, competence: (today << 2).strftime("%Y%m"), status: "closed", version: 1,
                          closed_at: Time.current, closed_by_user: doctor)
    procedure = record({ "performed_on" => (today << 1).iso8601 }).payload[:procedure]
    expect(procedure).to have_attributes(billing_competence: (today << 1).strftime("%Y%m"), late: false)
  end

  it "laboratório municipal tem competência própria" do
    lab = lab_provider!
    procedure = record({ "sigtap_code" => "0202010473", "cid10" => nil }, establishment: Billing::Establishment.for_lab(lab)).payload[:procedure]
    expect(procedure.billing_period).to have_attributes(exam_provider_id: lab.id, health_unit_id: nil)
  end
end

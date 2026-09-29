# spec/jobs/campaigns/sms_batch_job_spec.rb
require "rails_helper"

RSpec.describe Campaigns::SmsBatchJob do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city_record) { register_test_city! }
  let(:campaign) { sent_campaign!(sms_enabled: true) }
  let(:inside) { Time.zone.now.change(hour: 10) }
  let(:text) { Campaigns::SmsText.body(city_record) }

  before { CityProfile.create!(name: "Curitiba", campaigns_sms_enabled: true) }

  def run = described_class.perform_now(city_slug: TEST_CITY_A.slug, campaign_id: campaign.id)
  def deliveries = SmsGateway::Test.deliveries
  def opted_person = person!.tap { |p| opt_in!(p) }

  it "dentro da janela: envia o texto fixo e marca sent com a hora" do
    citizen = opted_person
    row = recipient!(campaign, citizen)
    travel_to(inside) { run }
    expect(row.reload.sms_status).to eq("sent")
    expect(row.sms_sent_at).to be_within(1.second).of(inside)
    expect(deliveries).to eq([ { phone: citizen.phone, body: text } ])
  end

  it "antes das 8h e a partir das 20h: adia, não envia e se reagenda para as 8h seguintes" do
    row = recipient!(campaign, opted_person)
    early = Time.zone.now.change(hour: 7, min: 59)
    travel_to(early) do
      expect { run }.to have_enqueued_job(described_class)
        .with(city_slug: TEST_CITY_A.slug, campaign_id: campaign.id).at(early.change(hour: 8, min: 0))
    end
    expect(row.reload.sms_status).to eq("deferred")

    late = Time.zone.now.change(hour: 20, min: 0)
    travel_to(late) { expect { run }.to have_enqueued_job(described_class).at((late + 1.day).change(hour: 8)) }
    expect(row.reload.sms_status).to eq("deferred")
    expect(deliveries).to be_empty

    travel_to((late + 1.day).change(hour: 8)) { run }
    expect(row.reload.sms_status).to eq("sent")
  end

  it "gateway não configurado: pendentes e adiados viram unavailable, com um evento só" do
    rows = [ recipient!(campaign, opted_person), recipient!(campaign, opted_person, sms_status: "deferred") ]
    with_sms_gateway(nil) { travel_to(inside) { run; run } }
    expect(rows.map { |r| r.reload.sms_status }).to eq(%w[unavailable unavailable])
    expect(DomainEvent.where(name: "campaign.sms_unavailable").map(&:payload))
      .to eq([ { "campaign_id" => campaign.id, "count" => 2 } ])
  end

  it "gateway não configurado fora da janela (22h e 06h): unavailable na hora, sem adiar, com um evento só" do
    rows = [ recipient!(campaign, opted_person), recipient!(campaign, opted_person, sms_status: "deferred") ]
    with_sms_gateway(nil) do
      travel_to(Time.zone.now.change(hour: 22)) { expect { run }.not_to have_enqueued_job(described_class) }
      expect(rows.map { |r| r.reload.sms_status }).to eq(%w[unavailable unavailable])
      travel_to((Time.zone.now + 1.day).change(hour: 6)) { expect { run }.not_to have_enqueued_job(described_class) }
    end
    expect(rows.map { |r| r.reload.sms_status }).to eq(%w[unavailable unavailable])
    expect(DomainEvent.where(name: "campaign.sms_unavailable").map(&:payload))
      .to eq([ { "campaign_id" => campaign.id, "count" => 2 } ])
  end

  it "gateway não configurado às 06h, primeira execução: unavailable, não deferred" do
    row = recipient!(campaign, opted_person)
    with_sms_gateway(nil) do
      travel_to(Time.zone.now.change(hour: 6)) { expect { run }.not_to have_enqueued_job(described_class) }
    end
    expect(row.reload.sms_status).to eq("unavailable")
    expect(DomainEvent.where(name: "campaign.sms_unavailable").count).to eq(1)
  end

  it "gateway configurado que cai no meio do lote: o destinatário vira unavailable e o evento sai uma vez por campanha" do
    stub_const("Campaigns::SmsBatchJob::BATCH_SIZE", 2)
    people = Array.new(4) { opted_person }
    rows = people.map { |p| recipient!(campaign, p) }.sort_by(&:id)
    by_phone = rows.to_h { |r| [ r.citizen.phone, r ] }
    down_after_first = false
    allow(SmsGateway).to receive(:deliver).and_wrap_original do |original, **args|
      raise SmsGateway::Unavailable, "provedor fora do ar" if down_after_first

      down_after_first = true
      original.call(**args)
    end
    travel_to(inside) { run; run }

    statuses = rows.map { |r| r.reload.sms_status }
    expect(statuses).to eq(%w[sent unavailable unavailable unavailable])
    expect(deliveries.map { |d| by_phone.fetch(d[:phone]) }).to eq([ rows.first ])
    expect(DomainEvent.where(name: "campaign.sms_unavailable").map(&:payload))
      .to eq([ { "campaign_id" => campaign.id, "count" => 1 } ])
  end

  it "uma falha não interrompe o lote: tenta de novo uma vez e grava só a classe do erro" do
    bad = opted_person
    good = opted_person
    bad_row = recipient!(campaign, bad)
    good_row = recipient!(campaign, good)
    calls = Hash.new(0)
    allow(SmsGateway).to receive(:deliver).and_wrap_original do |original, **args|
      calls[args[:phone]] += 1
      raise Errno::ECONNRESET, "falhou para #{args[:phone]}" if args[:phone] == bad.phone

      original.call(**args)
    end
    travel_to(inside) { run }
    expect(calls[bad.phone]).to eq(2)
    expect(bad_row.reload).to have_attributes(sms_status: "failed", sms_error: "Errno::ECONNRESET")
    expect(good_row.reload.sms_status).to eq("sent")
  end

  it "opt-out depois do congelamento: não envia, vira not_opted_in" do
    citizen = opted_person
    row = recipient!(campaign, citizen)
    opt_in!(citizen, false)
    travel_to(inside) { run }
    expect(row.reload.sms_status).to eq("not_opted_in")
    expect(deliveries).to be_empty
  end

  it "lote cheio: envia o lote e reenfileira a si mesmo para o resto" do
    stub_const("Campaigns::SmsBatchJob::BATCH_SIZE", 2)
    3.times { recipient!(campaign, opted_person) }
    travel_to(inside) do
      expect { run }.to have_enqueued_job(described_class).with(city_slug: TEST_CITY_A.slug, campaign_id: campaign.id)
    end
    expect(campaign.recipients.group(:sms_status).count).to eq("sent" => 2, "pending" => 1)
  end

  it "não toca linha que não é pending/deferred, nem campanha que não está sent" do
    row = recipient!(campaign, opted_person, sms_status: "duplicate_phone")
    travel_to(inside) { expect { run }.not_to have_enqueued_job(described_class) }
    expect(row.reload.sms_status).to eq("duplicate_phone")
    expect { described_class.perform_now(city_slug: TEST_CITY_A.slug, campaign_id: draft_campaign!.id) }.not_to raise_error
    expect(deliveries).to be_empty
  end
end

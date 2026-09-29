# spec/jobs/campaigns/dispatch_job_spec.rb
require "rails_helper"

RSpec.describe Campaigns::DispatchJob do
  let!(:city_record) { register_test_city! }

  before { CityProfile.create!(name: "Curitiba") }

  def run(campaign) = described_class.perform_now(city_slug: TEST_CITY_A.slug, campaign_id: campaign.id)

  def sending!(audience = city_audience)
    draft_campaign!(audience: audience).tap do |c|
      c.update_columns(status: "sending", dispatched_by_user_id: c.created_by_user_id)
    end
  end

  it "congela o público, grava contagens e a chave, publica campaign.dispatched; rodar de novo não faz nada" do
    5.times { person! }
    campaign = sending!
    run(campaign)
    expect(campaign.reload).to have_attributes(status: "sent", recipients_count: 5, phones_count: 5, sms_enabled: false)
    expect(campaign.dispatched_at).to be_present
    expect { run(campaign) }.not_to change(CampaignRecipient, :count)
    expect(DomainEvent.where(name: "campaign.dispatched").map(&:payload)).to eq([
      { "campaign_id" => campaign.id, "recipients_count" => 5, "phones_count" => 5, "sms_enabled" => false,
        "dispatched_by_user_id" => campaign.dispatched_by_user_id, "audience" => city_audience }
    ])
  end

  it "público que encolheu abaixo de 5 telefones: failed/below_minimum, nenhuma linha, nenhum SMS" do
    sms_profile!(enabled: true)
    4.times { person!.tap { |p| opt_in!(p) } }
    campaign = sending!
    expect { run(campaign) }.not_to have_enqueued_job(Campaigns::SmsBatchJob)
    expect(campaign.reload).to have_attributes(status: "failed", failure_reason: "below_minimum", recipients_count: nil)
    expect(CampaignRecipient.where(campaign_id: campaign.id)).to be_empty
    expect(DomainEvent.where(name: "campaign.failed").map(&:payload)).to eq([
      { "campaign_id" => campaign.id, "reason" => "below_minimum", "dispatched_by_user_id" => campaign.dispatched_by_user_id }
    ])
  end

  it "estado do SMS por destinatário: opt-in, sem opt-in e telefone repetido" do
    sms_profile!(enabled: true)
    shared = next_phone
    first, second = %w[a b].map { |s| person!(phone: shared, cpf: CampaignHistory.cpf_for("#{shared}-#{s}")) }.sort_by(&:id)
    [ first, second ].each { |p| opt_in!(p) }
    not_opted_same_phone = person!(phone: shared, cpf: CampaignHistory.cpf_for("#{shared}-c"))
    no_opt = person!
    3.times { person!.tap { |p| opt_in!(p) } }
    campaign = sending!

    expect { run(campaign) }.to have_enqueued_job(Campaigns::SmsBatchJob)
      .with(city_slug: TEST_CITY_A.slug, campaign_id: campaign.id)
    statuses = campaign.recipients.to_h { |r| [ r.citizen_id, r.sms_status ] }
    expect(statuses.values_at(first.id, second.id, not_opted_same_phone.id, no_opt.id))
      .to eq(%w[pending duplicate_phone not_opted_in not_opted_in])
    expect(statuses.values.tally).to eq("pending" => 4, "duplicate_phone" => 1, "not_opted_in" => 2)
    expect(campaign.reload).to have_attributes(sms_enabled: true, recipients_count: 7, phones_count: 5)
  end

  it "o menor citizen_id COM opt-in recebe, mesmo sem ser o menor do telefone" do
    sms_profile!(enabled: true)
    shared = next_phone
    lower, higher = %w[a b].map { |s| person!(phone: shared, cpf: CampaignHistory.cpf_for("#{shared}-#{s}")) }.sort_by(&:id)
    opt_in!(higher)
    4.times { person! }
    campaign = sending!
    run(campaign)
    statuses = campaign.recipients.to_h { |r| [ r.citizen_id, r.sms_status ] }
    expect(statuses.values_at(lower.id, higher.id)).to eq(%w[not_opted_in pending])
  end

  it "chave desligada no congelamento: todos not_opted_in, sem lote de SMS" do
    sms_profile!(enabled: false)
    5.times { person!.tap { |p| opt_in!(p) } }
    campaign = sending!
    expect { run(campaign) }.not_to have_enqueued_job(Campaigns::SmsBatchJob)
    expect(campaign.recipients.distinct.pluck(:sms_status)).to eq([ "not_opted_in" ])
    expect(campaign.recipients.where(sms_status: "pending")).to be_empty
    expect(campaign.reload.sms_enabled).to be(false)
  end

  it "revogado depois da prévia não é congelado" do
    people = Array.new(6) { person! }
    campaign = sending!
    revoked_conversation!(people.first)
    run(campaign)
    expect(campaign.recipients.pluck(:citizen_id)).not_to include(people.first.id)
    expect(campaign.reload.recipients_count).to eq(5)
  end

  it "só age em campanha sending" do
    5.times { person! }
    campaign = draft_campaign!
    run(campaign)
    expect(campaign.reload.status).to eq("draft")
    expect(campaign.recipients).to be_empty
  end
end

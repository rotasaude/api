# spec/support/campaign_helpers.rb
# Módulo 12 (ADR 0024): campanhas prontas para specs. A campanha enviada chega a
# `sent` pelo mesmo caminho que o trigger aceita (draft → sending → sent).
module CampaignHelpers
  def city_audience(*criteria)
    { "version" => 1, "geo" => { "scope" => "city" }, "clinical" => { "all" => criteria } }
  end

  def draft_campaign!(by: nil, title: "Vacinação contra a gripe",
                      body: "A campanha de vacinação começa na segunda-feira.", audience: city_audience)
    by ||= User.create!(email_address: "autor-#{SecureRandom.hex(4)}@cidade.gov.br", password: "senha-segura-123")
    Campaign.create!(title: title, body: body, audience: audience, created_by_user: by)
  end

  def sent_campaign!(by: nil, title: "Vacinação contra a gripe", sms_enabled: false, dispatched_at: Time.current)
    campaign = draft_campaign!(by: by, title: title)
    campaign.update_columns(status: "sending", dispatched_by_user_id: campaign.created_by_user_id)
    campaign.update_columns(status: "sent", sms_enabled: sms_enabled, recipients_count: 0, phones_count: 0,
                            dispatched_at: dispatched_at)
    campaign
  end

  def recipient!(campaign, citizen, sms_status: "pending")
    CampaignRecipient.create!(campaign: campaign, citizen: citizen, sms_status: sms_status)
  end

  # SQL cru num savepoint: um erro do trigger não aborta a transação do exemplo.
  def sql_in_savepoint(statement)
    ApplicationRecord.transaction(requires_new: true) { ApplicationRecord.connection.execute(statement) }
  end

  def with_sms_gateway(value)
    previous = Rails.configuration.x.sms_gateway
    Rails.configuration.x.sms_gateway = value
    yield
  ensure
    Rails.configuration.x.sms_gateway = previous
  end

  def sms_profile!(enabled:)
    (CityProfile.current || CityProfile.new(name: "Curitiba")).tap { |p| p.update!(campaigns_sms_enabled: enabled) }
  end
end

RSpec.configure do |c|
  c.include CampaignHelpers
  c.before { SmsGateway::Test.reset! }
end

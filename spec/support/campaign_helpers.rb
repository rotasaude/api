require Rails.root.join("lib/campaign_history").to_s

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

  # Telefones distintos por exemplo (+55 41 99xxxxxxx).
  def next_phone
    @campaign_phone_seq = (@campaign_phone_seq || 0) + 1
    format("+554199%07d", @campaign_phone_seq)
  end

  def person!(phone: next_phone, cpf: nil, neighborhood: nil)
    CampaignHistory.citizen!(cpf: cpf || CampaignHistory.cpf_for(phone), phone: phone, neighborhood: neighborhood)
  end

  def staff!
    @campaign_staff ||= staff_with("recepcao-#{SecureRandom.hex(4)}@cidade.gov.br", "citizen_verifier")
  end

  def unit!
    @campaign_unit ||= create_unit("UBS Campanha")
  end

  def opt_in!(citizen, value = true)
    CitizenContactPreference.for(citizen.id).tap { |p| p.update!(sms_opt_in: value) }
  end

  # Conversa revogada do cidadão, criada em `at` (a revogação vale para o
  # público só se esta for a conversa mais recente dele).
  def revoked_conversation!(citizen, at: 1.hour.ago)
    conversation = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "revoked",
                                        created_at: at)
    Consent.create!(conversation: conversation, version: 1, policy_text_sha: "sha-teste", channel: "web",
                    given_at: at, revoked_at: at + 1.minute)
    conversation
  end

  # Triagem do WhatsApp antigo: conversa sem cidadão.
  def anonymous_triage!(at:)
    conversation = Conversation.create!(phone: "+5541911110000", state: "completed", created_at: at - 5.minutes)
    Triage.create!(conversation: conversation, protocol_definition: CampaignHistory.protocol,
                   protocol_name: StartTriage::DEFAULT_PROTOCOL_NAME, status: "completed", tier: "alta", priority: 1,
                   answers: {}, created_at: at - 5.minutes, completed_at: at)
  end
end

RSpec.configure do |c|
  c.include CampaignHelpers
  c.before { SmsGateway::Test.reset! }
end

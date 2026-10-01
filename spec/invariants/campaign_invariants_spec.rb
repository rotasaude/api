# spec/invariants/campaign_invariants_spec.rb
# Módulo 12, critério de fechamento (ADR 0024 "Invariantes"; spec 2026-09-29
# §9.2). Cada bloco tem a mutação que precisa deixá-lo vermelho (registrada no
# relatório da entrega).
require "rails_helper"

RSpec.describe "Invariantes das campanhas (ADR 0024)", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city_record) { register_test_city! }
  let(:manager) { staff_with("campanhas@cidade.gov.br", "campaign_manager") }

  before do
    create_default_protocol!
    CityProfile.create!(name: "Curitiba")
  end

  def dispatch!(campaign)
    campaign.update_columns(status: "sending", dispatched_by_user_id: campaign.created_by_user_id)
    Campaigns::DispatchJob.perform_now(city_slug: TEST_CITY_A.slug, campaign_id: campaign.id)
    campaign.reload
  end

  def sms_batch!(campaign)
    travel_to(Time.zone.now.change(hour: 10)) do
      Campaigns::SmsBatchJob.perform_now(city_slug: TEST_CITY_A.slug, campaign_id: campaign.id)
    end
  end

  # Mutação: tirar o `raise ActiveRecord::Rollback` de DispatchJob#freeze_recipients,
  # ou o `below_minimum?` de Campaigns::SendGate (app/commands/campaigns/send_gate.rb).
  it "nenhuma campanha sai com menos de 5 telefones distintos" do
    shared = next_phone
    5.times { |i| person!(phone: shared, cpf: CampaignHistory.cpf_for("#{shared}-#{i}")) }
    3.times { person! }
    campaign = draft_campaign!(by: manager)
    expect(Campaigns::Send.call(campaign: campaign, by: manager).reason).to eq(:below_minimum)
    expect(dispatch!(campaign).status).to eq("failed")
    expect(CampaignRecipient.where(campaign_id: campaign.id)).to be_empty
  end

  # Mutação: tirar o `where("citizens.id NOT IN (#{REVOKED_SQL})")` de
  # Campaigns::Audience#citizen_ids.
  it "cidadão com a conversa mais recente revogada nunca entra no público" do
    revoked = person!.tap { |c| revoked_conversation!(c) }
    5.times { person! }
    campaign = dispatch!(draft_campaign!(by: manager))
    expect(campaign.recipients.pluck(:citizen_id)).not_to include(revoked.id)
    expect(Citizen.where(id: Campaigns::Audience.new(city_audience).citizen_ids)).not_to include(revoked)
  end

  # Mutação: tirar a conferência `opted.include?` de SmsBatchJob#deliver; ou,
  # no INSERT do DispatchJob, trocar `NOT #{sms_enabled ? ...}` por `NOT TRUE`.
  it "nenhum SMS sem opt-in vigente, nem com a chave desligada no congelamento" do
    people = Array.new(5) { person!.tap { |p| opt_in!(p) } }
    sms_profile!(enabled: false)
    off = dispatch!(draft_campaign!(by: manager))
    sms_profile!(enabled: true)
    sms_batch!(off)
    expect(SmsGateway::Test.deliveries).to be_empty

    on = dispatch!(draft_campaign!(by: manager))
    opt_in!(people.first, false)
    sms_batch!(on)
    expect(SmsGateway::Test.deliveries.map { |d| d[:phone] }).to match_array(people.drop(1).map(&:phone))
  end

  # Mutação: em SmsBatchJob, trocar `SmsText.body(Current.city)` por
  # "#{campaign.title}: #{SmsText.link(Current.city)}?c=#{campaign.id}".
  it "o SMS é sempre o texto fixo, e o link não carrega identificador" do
    sms_profile!(enabled: true)
    5.times { person!.tap { |p| opt_in!(p) } }
    campaign = dispatch!(draft_campaign!(by: manager, title: "Dengue no bairro"))
    sms_batch!(campaign)
    bodies = SmsGateway::Test.deliveries.map { |d| d[:body] }.uniq
    expect(bodies).to eq([ Campaigns::SmsText.body(city_record) ])
    expect(bodies.first).not_to match(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/)
    expect(bodies.first).not_to include("Dengue", campaign.id)
    expect(bodies.first).to end_with("/wpda/avisos")
  end

  # Mutação: acrescentar `recipients: campaign.recipients.pluck(:citizen_id)` em
  # Campaigns::Presenter.full.
  it "nenhuma resposta do dashboard traz a lista de destinatários" do
    people = Array.new(5) { person! }
    campaign = dispatch!(draft_campaign!(by: manager))
    sign_in_as(manager)
    bodies = []
    [ "/campaigns", "/campaigns/#{campaign.id}", "/campaigns/options", "/campaigns/sms_setting" ].each do |path|
      get path
      bodies << response.body
    end
    json_post "/campaigns/preview", audience: city_audience
    bodies << response.body
    secrets = people.flat_map { |p| [ p.id, p.cpf, p.phone ] }
    bodies.each do |text|
      secrets.each { |secret| expect(text).not_to include(secret) }
      expect(text).not_to match(/"(recipients|citizens?_ids?)"\s*:\s*\[/)
    end
  end

  # Mutação: apagar o bloco DO $do$ dos triggers de campanha em
  # db/city_triggers.sql e recarregar os bancos de teste.
  it "a campanha enviada é imutável; do destinatário só mudam leitura e SMS" do
    campaign = sent_campaign!(by: manager)
    row = recipient!(campaign, person!)
    expect { sql_in_savepoint("UPDATE campaigns SET body = 'Texto trocado depois' WHERE id = '#{campaign.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid)
    expect { sql_in_savepoint("UPDATE campaign_recipients SET citizen_id = '#{person!.id}' WHERE id = '#{row.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid)
    expect(campaign.reload.body).to eq("A campanha de vacinação começa na segunda-feira.")
  end

  # Mutação: tirar a chamada a Campaigns::ForgetRevokedRecipients de
  # AnonymizeRevokedTriageJob#handle.
  it "a revogação que anonimiza o cidadão apaga as linhas dele em campaign_recipients" do
    citizen = person!
    conversation = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "consented")
    Consent.create!(conversation: conversation, version: 1, policy_text_sha: "sha-teste", channel: "web",
                    given_at: Time.current)
    recipient!(sent_campaign!(by: manager), citizen, sms_status: "not_opted_in")
    RevokeConsent.call(conversation: conversation, origin: "web")
    AnonymizeRevokedTriageJob.new.handle(conversation_id: conversation.id)
    expect(CampaignRecipient.where(citizen_id: citizen.id)).to be_empty
  end

  # Mutação: pôr `citizen_ids: campaign.recipients.pluck(:citizen_id)` em
  # campaign.dispatched, ou `phone: citizen.phone` em citizen.contact_preferences_changed.
  it "nenhum payload de evento de campanha carrega CPF, telefone ou lista de cidadãos" do
    people = Array.new(5) { person! }
    centro = Neighborhood.create!(name: "Centro", source: "seed")
    attrs = { "title" => "Vacinação contra a gripe", "body" => "Procure a unidade mais próxima.", "audience" => city_audience }
    campaign = Campaigns::Create.call(attrs: attrs, by: manager).payload[:campaign]
    Campaigns::Schedule.call(campaign: campaign, send_at: 1.day.from_now.iso8601, by: manager)
    Campaigns::Unschedule.call(campaign: campaign, by: manager)
    Campaigns::Send.call(campaign: campaign, by: manager)
    Campaigns::DispatchJob.perform_now(city_slug: TEST_CITY_A.slug, campaign_id: campaign.id)
    empty = draft_campaign!(by: manager, audience: { "version" => 1, "clinical" => { "all" => [] },
                                                     "geo" => { "scope" => "neighborhoods", "neighborhood_ids" => [ centro.id ] } })
    dispatch!(empty)
    Campaigns::Cancel.call(campaign: draft_campaign!(by: manager), by: manager)
    Campaigns::SetSmsEnabled.call(enabled: true, by: manager)
    Citizens::UpdateContactPreferences.call(citizen: people.first, changes: { "sms_opt_in" => true })
    unavailable = sent_campaign!(by: manager, sms_enabled: true)
    recipient!(unavailable, people.last)
    with_sms_gateway(nil) { sms_batch!(unavailable) }

    names = %w[campaign.created campaign.scheduled campaign.unscheduled campaign.cancelled campaign.dispatched
               campaign.failed campaign.sms_unavailable citizen.contact_preferences_changed city.campaigns_sms_toggled]
    events = DomainEvent.where(name: names).to_a
    expect(events.map(&:name).uniq).to match_array(names)
    secrets = people.flat_map { |p| [ p.cpf, p.phone, p.phone.delete("+") ] }
    events.each do |event|
      json = event.payload.to_json
      secrets.each { |secret| expect(json).not_to include(secret), "#{event.name} vazou dado pessoal" }
      expect(event.payload.values.grep(Array)).to be_empty, "#{event.name} carrega lista"
      next if event.name == "citizen.contact_preferences_changed"

      people.each { |p| expect(json).not_to include(p.id), "#{event.name} carrega id de cidadão" }
    end
  end

  # Mutação: acrescentar `config.x.sms_gateway = :log` em config/environments/production.rb.
  it "production e staging não configuram gateway de SMS: o deploy não envia SMS" do
    %w[production staging].each do |env|
      expect(File.read(Rails.root.join("config/environments/#{env}.rb"))).not_to include("sms_gateway"), env
    end
  end

  # Mutação: acrescentar `phone: citizen.phone` aos argumentos de qualquer um
  # dos 5 perform_later de campanha: Send → DispatchJob (send.rb), DueJob →
  # DispatchJob (due_job.rb), DispatchJob → SmsBatchJob (dispatch_job.rb),
  # SmsBatchJob fora da janela 8h–20h (sms_batch_job.rb) e SmsBatchJob com
  # lote cheio (sms_batch_job.rb). Cada etapa exige que o job esperado tenha
  # sido enfileirado, para o exemplo não passar no vazio.
  it "jobs de campanha recebem só o slug e o id" do
    sms_profile!(enabled: true)
    5.times { person!.tap { |p| opt_in!(p) } }
    queue = ActiveJob::Base.queue_adapter
    stage = lambda do |expected|
      jobs = queue.enqueued_jobs.select { |j| j["job_class"].start_with?("Campaigns::") }
      expect(jobs.map { |j| j["job_class"] }).to include(expected)
      jobs.each do |job|
        expect(job["arguments"].first.keys - [ "_aj_ruby2_keywords" ]).to match_array(%w[city_slug campaign_id]), job["job_class"]
      end
      queue.enqueued_jobs.clear
    end

    campaign = draft_campaign!(by: manager)
    Campaigns::Send.call(campaign: campaign, by: manager)
    stage.call("Campaigns::DispatchJob")

    due = draft_campaign!(by: manager)
    due.update_columns(status: "scheduled", send_at: 1.minute.ago)
    Campaigns::DueJob.perform_now
    stage.call("Campaigns::DispatchJob")

    Campaigns::DispatchJob.perform_now(city_slug: TEST_CITY_A.slug, campaign_id: campaign.id)
    stage.call("Campaigns::SmsBatchJob")

    travel_to(Time.zone.now.change(hour: 7)) do
      Campaigns::SmsBatchJob.perform_now(city_slug: TEST_CITY_A.slug, campaign_id: campaign.id)
    end
    stage.call("Campaigns::SmsBatchJob")

    stub_const("Campaigns::SmsBatchJob::BATCH_SIZE", 2)
    sms_batch!(campaign)
    stage.call("Campaigns::SmsBatchJob")
  end
end

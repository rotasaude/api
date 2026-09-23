require "rails_helper"

RSpec.describe NotifyCitizenJob do
  include ActiveJob::TestHelper

  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  def completed_triage(conversation)
    pd = ProtocolDefinition.create!(
      name: "notify-spec", version: 1, status: "active",
      definition: { "name" => "notify-spec", "version" => 1, "start_step_id" => "s1",
                    "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                                  "branches" => { "true" => nil, "false" => nil } }] }
    )
    triage = Triage.create!(conversation: conversation, protocol_definition: pd, protocol_name: "notify-spec",
                            status: "completed", tier: "alta", priority: 1, completed_at: Time.current,
                            outcome: { "trail" => [] })
    token = ReportSnapshot.mint_token
    ReportSnapshot.create!(triage: triage, protocol_definition: pd, outcome: { "tier" => "alta" },
                           payload: { "tier" => "alta" }, token: token,
                           signature: ReportSnapshot.sign(token), expires_at: 30.days.from_now)
    triage
  end

  it "no WhatsApp, manda o link do relatório" do
    triage = completed_triage(Conversation.create!(phone: "+5541998765432", state: :completed))
    expect { described_class.new.handle(triage_id: triage.id) }.to have_enqueued_job(SendWhatsappJob)
  end

  it "na web, não manda nada: o link aparece na tela" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    conversation = Conversation.create!(phone: citizen.phone, state: :completed, channel: "web", citizen: citizen)
    triage = completed_triage(conversation)
    expect { described_class.new.handle(triage_id: triage.id) }.not_to have_enqueued_job(SendWhatsappJob)
  end
end

require "rails_helper"
require Rails.root.join("lib/signature_crew")
require Rails.root.join("lib/campaign_crew")

RSpec.describe CampaignCrew do
  let!(:boqueirao) { Neighborhood.create!(name: "Boqueirão", source: "seed") }
  let!(:santa) { Neighborhood.create!(name: "Santa Felicidade", source: "seed") }
  let(:window) { { "from" => (Time.zone.today - 60).iso8601, "to" => Time.zone.today.iso8601 } }

  before do
    create_default_protocol!
    CityProfile.create!(name: "Curitiba")
    [ [ "UBS Jardim das Flores", "ubs" ], [ "UBS Vila Esperança", "ubs" ], [ "UPA 24h Centro", "upa" ] ]
      .each { |name, kind| create_unit(name, kind: kind) }
    staff_with("recepcao@curitiba.demo", "citizen_verifier")
  end

  def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")

  def no_show_audience(*ids)
    { "version" => 1, "geo" => { "scope" => "neighborhoods", "neighborhood_ids" => ids },
      "clinical" => { "all" => [ { "kind" => "appointment_no_show" }.merge(window) ] } }
  end

  it "cria a conta campaign_manager com TOTP e casos para cada critério em dois bairros" do
    result = seed
    expect(result[:account]).to include(email: "campanhas@curitiba.demo", role: "campaign_manager")
    user = User.find_by!(email_address: "campanhas@curitiba.demo")
    expect(user).to be_mfa_enrolled
    expect(user.has_role?(:campaign_manager)).to be(true)
    expect(result[:citizens]).to eq(25)
    # índices pares de 0..23 (12 por bairro) = 12; o cidadão do telefone compartilhado não opta.
    expect(result[:opted_in]).to eq(12)
    expect(CitizenContactPreference.where(sms_opt_in: true).count).to eq(12)

    expect(Campaigns::Audience.new(no_show_audience(boqueirao.id, santa.id)).summary).to eq(citizens: 7, phones: 6)
    expect(Campaigns::Audience.new(no_show_audience(boqueirao.id)).preview).to eq(below_minimum: true)

    {
      "protocol_period" => { "protocol_name" => "triage-respiratoria" }.merge(window),
      "triage_tier" => { "tiers" => [ "alta" ] }.merge(window),
      "triage_incomplete" => window,
      "attendance_outcome" => { "outcomes" => %w[discharged referred return left] }.merge(window),
      "triaged_not_attended" => window,
      "appointment_no_show" => window,
      "appointment_request_open" => {}
    }.each do |kind, params|
      count = Citizen.where(id: Campaigns::Criteria.for(kind).relation({ "kind" => kind }.merge(params))).count
      expect(count).to be_positive, kind
    end
    expect(Citizen.all.map(&:cpf)).to all(satisfy { |cpf| CitizenIdentity::Cpf.normalize(cpf) == cpf })
  end

  it "é idempotente" do
    seed
    counts = -> { [ Citizen.count, Conversation.count, Triage.count, Attendance.count, Appointment.count ] }
    before = counts.call
    expect(seed[:new_histories]).to eq(0)
    expect(counts.call).to eq(before)
  end
end

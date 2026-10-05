# spec/lib/analytics_crew_spec.rb
require "rails_helper"
require Rails.root.join("lib/signature_crew")
require Rails.root.join("lib/analytics_crew")
require Rails.root.join("lib/triage_catalog_crew")

RSpec.describe AnalyticsCrew do
  let!(:city_record) { register_test_city! }

  before do
    create_default_protocol!
    %w[Centro Batel Portão Boqueirão].each { |name| Neighborhood.create!(name: name, source: "seed") }
    [ [ "UBS Jardim das Flores", "ubs" ], [ "UBS Vila Esperança", "ubs" ], [ "UPA 24h Centro", "upa" ] ]
      .each { |name, kind| create_unit(name, kind: kind) }
    SignatureCrew.seed_current_city(slug: "curitiba", password: "dev-password")
  end

  def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password", days: 21)

  it "cria a conta analyst, leva o protocolo marcado pelo ciclo assinado e consolida três semanas de histórico" do
    result = seed

    user = User.find_by!(email_address: "analise@curitiba.demo")
    expect(user).to be_mfa_enrolled
    expect(user.has_role?(:analyst)).to be(true)
    expect(result[:account]).to include(email: "analise@curitiba.demo", role: "analyst")
    expect(result[:protocol]).to eq(name: "triagem-arbovirose", version: 1, status: "active")
    protocol = ProtocolDefinition.find_by!(name: "triagem-arbovirose", version: 1)
    expect(protocol.definition["steps"].select { |s| s["analytic"] }.map { |s| s["answer_type"] }).to eq(%w[boolean enum])
    expect(ProtocolSignature.where(protocol_definition: protocol).pluck(:purpose).tally)
      .to eq("publication" => 2, "activation" => 2)

    expect(result[:new_triages]).to be > 50
    expect(result[:failed]).to be_nil
    expect(AnalyticsRun.where(kind: "rebuild", status: "succeeded")).to exist
    expect(AnalyticsDailyFact.where(metric: "epi.answer").distinct.pluck(:question_id)).to match_array(%w[febre sintoma])
    %w[triage.started triage.completed attendance.checked_in attendance.closed attendance.wait calibration.outcome]
      .each { |metric| expect(AnalyticsDailyFact.where(metric: metric)).to exist, metric }
    expect(CityAnalyticsIndicator.where(city_id: city_record.id)).to exist
    expect(Triage.where("created_at >= ?", Time.zone.today.beginning_of_day)).to be_empty
    expect(Citizen.all.map(&:cpf)).to all(satisfy { |cpf| CitizenIdentity::Cpf.normalize(cpf) == cpf })
  end

  it "é idempotente" do
    seed
    counts = -> { [ Triage.count, Attendance.count, AppointmentRequest.count, Appointment.count, ProtocolDefinition.count ] }
    before = counts.call

    expect(seed[:new_triages]).to eq(0)
    expect(counts.call).to eq(before)
  end

  # A semente do catálogo (módulo 15) dá título à arbovirose numa versão nova.
  # Rodar de novo não pode reativar a v1: cada db:seed alternaria as versões.
  it "não reativa a v1 quando outra versão do protocolo está ativa" do
    seed
    staff_with("admin@curitiba.demo", "municipal_admin")
    TriageCatalogCrew.seed_current_city(slug: "curitiba", ddd: "41")
    titled = ProtocolDefinition.find_by!(name: "triagem-arbovirose", status: "active")
    expect(titled.version).to be > 1

    expect { seed }.not_to change(ProtocolActivation, :count)
    expect(ProtocolDefinition.find_by!(name: "triagem-arbovirose", status: "active")).to eq(titled)
  end
end

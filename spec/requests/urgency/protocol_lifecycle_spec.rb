require "rails_helper"

# Módulo 32a (contrato §3, §14 Q1/Q16): o protocolo de classificação de risco
# pelo ciclo assinado real do 18 — rascunho, revisão, duas assinaturas,
# publicação, duas assinaturas e ativação, pelas rotas existentes. Um ativo
# por cidade pelo kind: ativar outro rebaixa o anterior a `published`, mesmo
# com outro nome. O protocolo de urgência nunca é triagem nem acolhimento, e
# a UPA fica fora da escuta inicial.
RSpec.describe "Protocolo de classificação de urgência", type: :request do
  def json = JSON.parse(response.body)

  def enrolled_user(role)
    user = User.create!(email_address: "#{role}-#{SecureRandom.hex(3)}@example.org", password: "secret123")
    Mfa::Enroll.call(user)
    user.update!(otp_enabled: true)
    Membership.create!(user: user, role: role, granted_at: Time.current)
    user
  end

  def sign_in_stepped_up!(user) = sign_in_as(user).update!(mfa_verified_at: Time.current)

  let!(:author)    { enrolled_user("protocol_author") }
  let!(:ana)       { enrolled_user("protocol_reviewer") }
  let!(:bia)       { enrolled_user("protocol_reviewer") }
  let!(:publisher) { enrolled_user("protocol_publisher") }

  def urgency_definition(name: "classificacao-urgencia", version: 1, yellow: 60)
    levels = UrgencyHelpers::LEVELS.map { |l| l["color"] == "yellow" ? l.merge("max_wait_minutes" => yellow) : l }
    { "name" => name, "version" => version, "kind" => "urgency_classification", "levels" => levels,
      "classification_rules" => UrgencyHelpers::RULES }
  end

  def expect_ok!
    expect(response).to have_http_status(:ok), -> { "#{response.status}: #{response.body}" }
  end

  # O ciclo inteiro pelas rotas, do rascunho à ativação.
  def signed_cycle!(definition)
    name = definition["name"]
    version = definition["version"]
    sign_in_as(author)
    post "/authoring/protocols/draft", params: { definition: definition }, as: :json
    expect_ok!
    post "/protocols/#{version}/submit", params: { name: name }, as: :json
    expect_ok!
    [ ana, bia ].each do |reviewer|
      sign_in_stepped_up!(reviewer)
      post "/protocols/#{version}/signatures", params: { name: name, purpose: "publication" }, as: :json
      expect_ok!
    end
    sign_in_stepped_up!(publisher)
    post "/protocols/#{version}/publish", params: { name: name }, as: :json
    expect_ok!
    [ ana, bia ].each do |reviewer|
      sign_in_stepped_up!(reviewer)
      post "/protocols/#{version}/signatures", params: { name: name, purpose: "activation" }, as: :json
      expect_ok!
    end
    sign_in_stepped_up!(publisher)
    post "/protocols/#{version}/activate", params: { name: name }, as: :json
    expect_ok!
    ProtocolDefinition.find_by!(name: name, version: version)
  end

  it "rascunho → revisão → assinaturas → publicação → ativação; a v2 rebaixa a v1; os níveis são da versão" do
    v1 = signed_cycle!(urgency_definition)
    expect(v1.status).to eq("active")
    expect(Urgency::ActiveProtocol.current).to eq(v1)
    expect(Urgency::Levels.for(v1)["yellow"]).to eq(60)

    v2 = signed_cycle!(urgency_definition(version: 2, yellow: 30))
    expect([ v1.reload.status, v2.status ]).to eq(%w[published active])
    expect(Urgency::ActiveProtocol.current).to eq(v2)
    expect(Urgency::Levels.for(v2)["yellow"]).to eq(30)
    expect(Urgency::Levels.for(v1)["yellow"]).to eq(60)
    expect(Urgency::Levels.for(nil)).to eq(Urgency::Catalog::DEFAULT_MAX_WAIT)

    # Um ativo por cidade pelo kind, não pelo nome (Q16).
    other = signed_cycle!(urgency_definition(name: "urgencia-adulto"))
    expect([ v2.reload.status, other.status ]).to eq(%w[published active])
    expect(ProtocolDefinition.urgency_protocols.active.to_a).to eq([ other ])

    # Nunca é triagem nem acolhimento.
    expect(ProtocolDefinition.triage_protocols.where(id: [ v1, v2, other ].map(&:id))).to be_empty
    expect(ProtocolDefinition.screening_protocols.where(id: [ v1, v2, other ].map(&:id))).to be_empty
    expect(Screenings::ActiveProtocol.current).to be_nil
    expect { Protocols.current(name: "urgencia-adulto") }.to raise_error(Protocols::NotFound)
  end

  it "a triagem ativa continua ativa quando a urgência é ativada" do
    create_default_protocol!
    triage = ProtocolDefinition.find_by!(name: StartTriage::DEFAULT_PROTOCOL_NAME, status: "active")
    signed_cycle!(urgency_definition)
    expect(triage.reload.status).to eq("active")
    expect(ProtocolDefinition.triage_protocols.active.pluck(:id)).to eq([ triage.id ])
  end

  it "o gate recusa o nome de outro kind; a prévia não existe para a urgência" do
    ProtocolDefinition.create!(name: "dengue", version: 1, status: "draft", definition: protocol_definition_hash(name: "dengue"))
    sign_in_as(author)
    post "/authoring/protocols/gate", params: { definition: urgency_definition(name: "dengue") }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["errors"]).to eq([ "name_kind_conflict: name 'dengue' is used by a protocol of another kind" ])

    post "/authoring/protocols/gate", params: { definition: urgency_definition }, as: :json
    expect_ok!
    post "/authoring/protocols/preview", params: { definition: urgency_definition, answers: {} }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json).to eq("valid" => false, "errors" => [ "preview is not available for urgency protocols" ])
  end

  describe "a UPA fora da escuta inicial" do
    before { Current.city = TEST_CITY_A; acolhimento! }
    after { Current.reset }

    let(:upa) { create_unit("UPA Centro", kind: "upa") }

    it "iniciar a escuta numa UPA → 422 screening_not_in_upa; a fila do acolhimento da UPA é vazia" do
      attendance = walk_in_attendance!(upa, citizen: screening_citizen!(1))
      expect(Screenings::Scope.required?(attendance)).to be(false)
      expect(Screenings::Queue.awaiting?(attendance, active: true)).to be(false)

      sign_in_as(upa_nurse!(upa))
      json_post "/attendance/attendances/#{attendance.id}/screening"
      expect([ response.status, json["error"] ]).to eq([ 422, "screening_not_in_upa" ])
      expect(Screening.where(attendance_id: attendance.id)).to be_empty

      sign_in_as(reception!)
      get "/attendance/units/#{upa.id}/screening_queue"
      expect_ok!
      expect(json).to eq("items" => [])
    end
  end
end

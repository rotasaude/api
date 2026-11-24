require "rails_helper"

# Módulo 35b, Task 10 (ADR 0054; contrato §4, §10, §16; Q13, Q26, Q33): a
# fila do centro (/zoonoses/demands) e o andamento da demanda, para team?
# (403 missing_role). A lista traz só subtipo, estado, prazo, cor, versão e o
# estado do encaminhamento — nunca o extrato, o place_address, o protocolo, a
# identidade nem o contato. O detalhe traz o extrato e o endereço e publica
# zoonoses_demand.viewed { zoonoses_demand_id, user_id } (Q26).
RSpec.describe "Zoonoses — fila de demandas", type: :request do
  let(:phone) { "+5541998765432" }
  let(:citizen_name) { "Cidadã Marcada Demanda" }
  let(:text) { "Morcego caído no chão da sala de aula, ainda vivo e se mexendo." }
  let(:address) { "Escola Municipal Rio Branco, Rua XV, 300" }
  let!(:city) do
    zoonoses_city!
    ombudsman_city!(anonymous: true)
  end
  let!(:uvz) { uvz_unit! }
  let(:team) { zoonoses_team! }
  let(:headers) { { "CONTENT_TYPE" => "application/json" } }
  let(:today) { Time.zone.today }

  def json_post_to(path, fields) = post(path, params: fields.to_json, headers: headers)

  # Manifestação identificada pela wpda, com nome e telefone do cidadão.
  def identified_demand!
    team
    citizen = web_citizen!(phone: phone, full_name: citizen_name)
    session = CitizenSession.start!(phone: phone).first
    result = Ombudsman::Register.call(attrs: { "kind" => "request", "identification_mode" => "identified", "body" => text,
                                               "zoonoses_subtype" => "bat", "place_address" => address },
                                      channel: "web", citizen: citizen, citizen_session: session, zoonoses: true)
    expect(result).to be_ok
    manifestation = result.payload.fetch(:manifestation)
    [ ZoonosesDemand.joins(:ombudsman_forwarding).find_by!(ombudsman_forwardings: { ombudsman_manifestation_id: manifestation.id }),
      manifestation ]
  end

  it "a lista não traz extract, place_address, protocol, nome nem contato" do
    demand, manifestation = identified_demand!
    sign_in_as(team)

    get "/zoonoses/demands"
    expect(response).to have_http_status(:ok)
    item = json_body["items"].sole
    forwarding = demand.ombudsman_forwarding
    expect(item).to eq("id" => demand.id, "subtype" => "bat", "state" => "open", "due_on" => forwarding.due_on.iso8601,
                       "color" => Ombudsman::Deadlines.forwarding_color(forwarding, OmbudsmanSetting.current, today: today),
                       "version" => 1, "forwarding_state" => "pending")
    expect(json_body["next_before"]).to be_nil
    [ text, address, manifestation.protocol, citizen_name, phone, phone.delete("+"), manifestation.id ].each do |secret|
      expect(response.body).not_to include(secret)
    end
    expect(DomainEvent.where(name: "zoonoses_demand.viewed").count).to eq(0)

    get "/zoonoses/demands?state=closed"
    expect(json_body["items"]).to eq([])
    get "/zoonoses/demands?state=reopened"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "state" } ])
    get "/zoonoses/demands?place_address=x"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end

  it "o detalhe traz o extrato e o endereço e publica zoonoses_demand.viewed só com ids" do
    demand, manifestation = identified_demand!
    sign_in_as(team)

    get "/zoonoses/demands/#{demand.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => demand.id, "subtype" => "bat", "state" => "open", "extract" => text, "place_address" => address,
                                 "scheduled_on" => nil, "inspected_on" => nil, "inspection_note" => nil, "outcome" => nil,
                                 "forwarding_state" => "pending", "version" => 1)
    [ manifestation.protocol, citizen_name, phone.delete("+") ].each { |secret| expect(response.body).not_to include(secret) }
    expect(DomainEvent.where(name: "zoonoses_demand.viewed").sole.payload).to eq("zoonoses_demand_id" => demand.id, "user_id" => team.id)

    get "/zoonoses/demands/#{SecureRandom.uuid}"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    expect(DomainEvent.where(name: "zoonoses_demand.viewed").count).to eq(1)
  end

  it "o andamento pela rota: schedule, inspect, close; recusas só com error e path; nada do endereço na resposta" do
    demand, = identified_demand!
    sign_in_as(team)

    json_post_to("/zoonoses/demands/#{demand.id}/schedule", { scheduled_on: (today + 1).iso8601, expected_version: 1 })
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => demand.id, "state" => "scheduled", "version" => 2, "scheduled_on" => (today + 1).iso8601)
    expect(json_body.keys).not_to include("extract", "place_address", "inspection_note")

    json_post_to("/zoonoses/demands/#{demand.id}/inspect", { inspected_on: today.iso8601, inspection_note: "Morcego recolhido.",
                                                             expected_version: 1 })
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "demand_changed" } ])

    json_post_to("/zoonoses/demands/#{demand.id}/schedule", { scheduled_on: today.iso8601, expected_version: 2 })
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])

    json_post_to("/zoonoses/demands/#{demand.id}/inspect", { inspected_on: today.iso8601, inspection_note: "Morcego recolhido.",
                                                             expected_version: 2 })
    expect(json_body).to include("state" => "inspected", "inspected_on" => today.iso8601, "version" => 3)

    json_post_to("/zoonoses/demands/#{demand.id}/close", { outcome: "resolved", text: "curto", expected_version: 3 })
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "text" } ])

    json_post_to("/zoonoses/demands/#{demand.id}/close", { outcome: "resolved", text: "Morcego recolhido e enviado ao laboratório.",
                                                           expected_version: 3 })
    expect(json_body).to include("state" => "closed", "outcome" => "resolved", "forwarding_state" => "replied", "color" => nil)
    expect(response.body).not_to include(address)

    json_post_to("/zoonoses/demands/#{demand.id}/extend", { reason: "Aguardando o laboratório.", expected_version: 4 })
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "forwarding_changed" } ])

    post "/zoonoses/demands/#{demand.id}/schedule?scheduled_on=#{today.iso8601}", params: { expected_version: 4 }.to_json, headers: headers
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end

  it "decline e extend pela rota; already_extended do 33" do
    demand, = identified_demand!
    sign_in_as(team)

    json_post_to("/zoonoses/demands/#{demand.id}/extend", { reason: "Aguardando o caminhão.", expected_version: 1 })
    expect(json_body).to include("state" => "open", "version" => 2, "forwarding_state" => "pending")
    json_post_to("/zoonoses/demands/#{demand.id}/extend", { reason: "Aguardando o caminhão.", expected_version: 2 })
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "already_extended" } ])

    json_post_to("/zoonoses/demands/#{demand.id}/decline", { text: "Fora da área de atuação do centro.", expected_version: 2 })
    expect(json_body).to include("state" => "closed", "outcome" => nil, "forwarding_state" => "declined")
  end

  it "stock_keeper → 403; zoonoses desligado → 403 feature_disabled" do
    demand, = identified_demand!
    sign_in_as(staff_with("estoque-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper"))
    get "/zoonoses/demands"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    get "/zoonoses/demands/#{demand.id}"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    json_post_to("/zoonoses/demands/#{demand.id}/schedule", { scheduled_on: today.iso8601, expected_version: 1 })
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    expect(DomainEvent.where(name: "zoonoses_demand.viewed").count).to eq(0)

    Platform::Features.set!(city: city, key: Zoonoses::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(team)
    get "/zoonoses/demands"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "zoonoses" } ])
  end
  # Q35: as rotas /zoonoses/demands (leitura e escrita) pedem o zoonoses E a
  # ouvidoria utilizáveis; com o 33 desligado, o mesmo 403 do 33. A demanda
  # fica gravada e volta quando a ouvidoria é religada.
  it "Q35: ouvidoria desligada → lista, detalhe e andamento 403 feature ombudsman; religada, a mesma demanda volta" do
    demand, = identified_demand!
    Platform::Features.set!(city: city, key: Ombudsman::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(team)
    disabled = [ 403, { "error" => "feature_disabled", "feature" => "ombudsman" } ]

    get "/zoonoses/demands"
    expect([ response.status, json_body ]).to eq(disabled)
    get "/zoonoses/demands/#{demand.id}"
    expect([ response.status, json_body ]).to eq(disabled)
    json_post_to("/zoonoses/demands/#{demand.id}/schedule", { scheduled_on: today.iso8601, expected_version: 1 })
    expect([ response.status, json_body ]).to eq(disabled)
    expect(demand.reload).to have_attributes(state: "open", version: 1)
    expect(DomainEvent.where(name: %w[zoonoses_demand.viewed zoonoses_demand.changed]).count).to eq(0)

    Platform::Features.set!(city: city, key: Ombudsman::Gate::KEY, enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    get "/zoonoses/demands"
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].pluck("id", "state", "version")).to eq([ [ demand.id, "open", 1 ] ])
  end
end

require "rails_helper"

# Contrato §7 e §11 T1, §12 P5c/P8: só par validado; cifrada; "nenhuma"
# retira as outras; condição de retirada só no corpo.
RSpec.describe "Cidadão — condição declarada", type: :request do
  before { care_city! }

  let(:citizen) { care_citizen!(age: 40, sex: "female") }
  let(:json_headers) { { "CONTENT_TYPE" => "application/json" } }

  def conditions = json_body["conditions"].map { |c| c["condition"] }

  def json_delete(citizen_id, body, query: "")
    delete "/citizen/declared_conditions?citizen_id=#{citizen_id}#{query}", params: body.to_json, headers: json_headers
  end

  it "declara, lista, retira; none retira as outras; publica só ids" do
    sign_in_citizen(citizen.phone)
    json_post "/citizen/declared_conditions", citizen_id: citizen.id, condition: "diabetes"
    expect(response).to have_http_status(:created)
    json_post "/citizen/declared_conditions", citizen_id: citizen.id, condition: "hypertension"
    json_post "/citizen/declared_conditions", citizen_id: citizen.id, condition: "diabetes"
    expect(conditions).to contain_exactly("diabetes", "hypertension")
    expect(DomainEvent.where(name: "citizen_condition.declared").count).to eq(2)
    expect(DomainEvent.where(name: "citizen_condition.declared").last.payload.keys).to match_array(%w[citizen_declared_condition_id citizen_id])
    json_delete(citizen.id, { condition: "hypertension" })
    expect(response).to have_http_status(:ok)
    expect(conditions).to eq(%w[diabetes])
    expect(DomainEvent.where(name: "citizen_condition.withdrawn").last.payload.keys).to match_array(%w[citizen_declared_condition_id citizen_id])
    json_post "/citizen/declared_conditions", citizen_id: citizen.id, condition: "none"
    expect(conditions).to eq(%w[none])
    expect(CitizenDeclaredCondition.where(citizen: citizen).count).to eq(3) # diabetes, hypertension, none
    expect(CitizenDeclaredCondition.current.where(citizen: citizen).map(&:condition)).to eq(%w[none])
    json_post "/citizen/declared_conditions", citizen_id: citizen.id, condition: "diabetes"
    expect(conditions).to eq(%w[diabetes]) # uma condição retira o "none"
    json_post "/citizen/declared_conditions", citizen_id: citizen.id, condition: "asthma"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_condition")
    get "/citizen/declared_conditions", params: { citizen_id: citizen.id }
    expect(conditions).to eq(%w[diabetes])
  end

  it "retirar: a condição só no corpo; na URL é ignorada (422), nada muda e o log não a mostra" do
    sign_in_citizen(citizen.phone)
    json_post "/citizen/declared_conditions", citizen_id: citizen.id, condition: "pregnancy"
    log = capture_log do
      delete "/citizen/declared_conditions?citizen_id=#{citizen.id}&condition=pregnancy", params: {}.to_json, headers: json_headers
    end
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_condition")
    expect(CitizenDeclaredCondition.current.where(citizen: citizen).map(&:condition)).to eq(%w[pregnancy])
    expect(log).not_to include("condition=pregnancy")
    log = capture_log do
      delete "/citizen/declared_conditions?citizen_id=#{citizen.id}", params: { condition: "pregnancy" }.to_json, headers: json_headers
    end
    expect(conditions).to eq([])
    expect(log).not_to include("pregnancy")
  end

  it "retirar condição não vigente → 404; sem JSON → 415; condição fora do domínio → 422" do
    sign_in_citizen(citizen.phone)
    json_delete(citizen.id, { condition: "diabetes" })
    expect(response).to have_http_status(:not_found)
    expect(json_body).to eq("error" => "not_found")
    json_delete(citizen.id, { condition: "asthma" })
    expect(response).to have_http_status(:unprocessable_entity)
    delete "/citizen/declared_conditions", params: { citizen_id: citizen.id, condition: "diabetes" }
    expect(response).to have_http_status(:unsupported_media_type)
    expect(json_body).to eq("error" => "json_required")
  end

  it "a condição é cifrada no banco e fora do inspect e do evento" do
    sign_in_citizen(citizen.phone)
    json_post "/citizen/declared_conditions", citizen_id: citizen.id, condition: "mental_health"
    row = CitizenDeclaredCondition.find_by!(citizen: citizen)
    raw = ApplicationRecord.connection.select_value("SELECT condition FROM citizen_declared_conditions WHERE id = '#{row.id}'")
    expect(raw).not_to include("mental_health")
    expect(DomainEvent.where(name: "citizen_condition.declared").last.payload.to_json).not_to include("mental_health")
  end

  it "ciclo: declarar → evento gravado → consumidor → sugestão declared (linha própria com declared_condition)" do
    unit = care_unit!
    doctor = care_doctor!(unit)
    team = care_team!(unit, doctor)
    citizen = care_citizen!(age: 40, sex: "female", neighborhood: care_neighborhood!(unit))
    line = adopted_line!("diabetes_c4")
    sign_in_citizen(citizen.phone)
    json_post "/citizen/declared_conditions", citizen_id: citizen.id, condition: "diabetes"
    event = DomainEvent.where(name: "citizen_condition.declared").last
    expect(event.payload).to eq("citizen_declared_condition_id" => CitizenDeclaredCondition.find_by!(citizen: citizen).id, "citizen_id" => citizen.id)
    CareLines::ConditionDeclaredJob.new.perform(event_id: event.id, event_name: event.name, city_slug: Current.city.slug, payload: event.payload)
    expect(CareLineSuggestion.where(care_line: line, citizen: citizen).pluck(:team_id, :reason)).to eq([ [ team.id, "declared" ] ])
  end

  it "par declarado → 403 not_verified; par de outro celular → 404; care_lines desligado → 403" do
    declared = profiled_citizen!(age: 30, phone: "+5541990000123")
    sign_in_citizen(declared.phone)
    get "/citizen/declared_conditions", params: { citizen_id: declared.id }
    expect(json_body).to eq("error" => "not_verified")
    json_post "/citizen/declared_conditions", citizen_id: declared.id, condition: "diabetes"
    expect(response).to have_http_status(:forbidden)
    expect(CitizenDeclaredCondition.count).to eq(0)
    get "/citizen/declared_conditions", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:not_found)
    json_delete(citizen.id, { condition: "diabetes" })
    expect(response).to have_http_status(:not_found)
    Platform::Features.set!(city: Current.city, key: "care_lines", enabled: false, maintainer: ledi_maintainer!)
    get "/citizen/declared_conditions", params: { citizen_id: declared.id }
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "care_lines")
  end

  it "declarar: a condição só no corpo; na query string é ignorada (422) e nada é gravado" do
    sign_in_citizen(citizen.phone)
    post "/citizen/declared_conditions?condition=diabetes", params: { citizen_id: citizen.id }.to_json, headers: json_headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_condition")
    expect(CitizenDeclaredCondition.count).to eq(0)
  end
end

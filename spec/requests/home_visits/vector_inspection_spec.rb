require "rails_helper"

# Módulo 35a (ADR 0054; contrato §3, §9, §17; Q7(1), Q8, Q10; plano, A-3,
# A-10): o boletim do agente de endemias dentro do POST /home_visits do 24b. O
# controlador lê o gate fora da transação; os motivos 34–37 são derivados do
# boletim antes da conversão Q43 e das regras do 24b (recusa derivada aponta
# `subject`); o boletim exige domicílio; a ficha 8 lê os motivos gravados; o
# <home_visit> do 24b mostra o boletim (Q8) só quando há. 4xx só com error e path.
RSpec.describe "Visita domiciliar — boletim do agente de endemias", type: :request do
  let!(:city) { vector_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:agent) { endemic_agent!(team: team) }
  let(:area) { MicroAreaFieldAssignment.find_by!(professional: agent.professional).micro_area }
  let(:strategic_point) { registry_household!(micro_area: area, property_type: "4") }
  let(:product) do
    VectorProduct.create!(code: "BTI", name: "Larvicida biológico", unit: "g", charge_size: BigDecimal("0.15"), uses: %w[focal perifocal])
  end
  let(:uuid) { "3f2a9c1e-#{SecureRandom.uuid[9..]}" }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def earlier_today = [ 2.minutes.ago, Time.current.beginning_of_day ].max.change(usec: 0)

  def report(**over)
    { "activity" => "pe", "work_type" => "routine", "situation" => "worked", "educational_action" => false,
      "deposits" => [ { "group" => "A2", "existing" => 3, "with_water" => 2, "with_larvae" => 1, "eliminated" => 1, "treated" => 1 } ],
      "measures" => [ { "method" => "mechanical" }, { "method" => "focal", "vector_product_id" => product.id, "charges" => 1.25 } ],
      "samples" => [ { "number" => 1, "deposit_group" => "A2", "larvae_collected" => 8 } ] }.merge(over.stringify_keys)
  end

  def body(household = strategic_point, **over)
    { "client_uuid" => uuid, "team_id" => team.id, "occurred_at" => earlier_today.iso8601, "household_id" => household.id,
      "subject" => "none", "outcome" => 1, "reasons" => [], "shared" => false, "vector_inspection" => report }.merge(over.stringify_keys)
  end

  def inner(entry) =
    Ledi::Version.deserialize(Ledi::FichaTypes.klass("visita_domiciliar"), Ledi::Transport.read(entry.bytes).dadoSerializado)

  it "ACE em PE com boletim completo → 201, `reasons` gravados [35, 36, 37], `vector_inspection` na resposta com etiquetas" do
    sign_in_as(agent)
    json_post "/home_visits", body
    expect(response).to have_http_status(:created)
    visit = HomeVisit.sole
    expect(visit.reasons).to eq([ 35, 36, 37 ])
    expect(json_body["visit"]["reasons"]).to eq([ 35, 36, 37 ])
    inspection = VectorInspection.sole
    sample = VectorSample.sole
    expect(json_body["visit"]["vector_inspection"]).to eq(
      "id" => inspection.id, "activity" => "pe", "work_type" => "routine", "situation" => "worked", "educational_action" => false,
      "recovered" => false, "city_block" => nil,
      "deposits" => [ { "group" => "A2", "existing" => 3, "with_water" => 2, "with_larvae" => 1, "eliminated" => 1, "treated" => 1 } ],
      "measures" => [
        { "method" => "mechanical", "quantity" => nil, "product" => nil },
        { "method" => "focal", "vector_product_id" => product.id, "charges" => 1.25, "quantity" => "0.19",
          "product" => { "id" => product.id, "code" => "BTI", "name" => "Larvicida biológico", "unit" => "g" } }
      ],
      "samples" => [ { "id" => sample.id, "number" => 1, "deposit_group" => "A2", "larvae_collected" => 8,
                       "label" => "#{uuid[0, 8].upcase}-01", "result" => nil } ]
    )
    expect(VectorInspectionMeasure.find_by!(method: "focal")).to have_attributes(charges: BigDecimal("1.25"), quantity: BigDecimal("0.19"))
    expect(HouseholdVectorProfile.find_by!(household_id: strategic_point.id))
      .to have_attributes(last_inspection_id: inspection.id, last_situation: "worked", last_worked_on: visit.occurred_at.to_date)
    expect(DomainEvent.where(name: "home_visit.recorded").sole.payload.keys).to contain_exactly("home_visit_id", "home_visit_day_id", "user_id")
  end

  it "boletim em residencial com família ativa e `subject: none` → 422 reason_not_allowed path subject (A-3)" do
    home = registry_household!(micro_area: area)
    registry_family!(home)
    sign_in_as(agent)
    json_post "/home_visits", body(home, vector_inspection: report(activity: "li", measures: []))
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "reason_not_allowed", "path" => "subject" } ])
    json_post "/home_visits", body(home, client_uuid: SecureRandom.uuid, reasons: [ 11 ], vector_inspection: report(activity: "li", measures: []))
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "reason_not_allowed", "path" => "reasons[0]" } ])
    expect([ HomeVisit.count, VectorInspection.count, HouseholdVectorProfile.count ]).to eq([ 0, 0, 0 ])
  end

  it "o mesmo com `subject: resident` do cadastro da família → convertida para family_responsible (Q43) e aceita" do
    home = registry_household!(micro_area: area)
    responsible = registry_patient!
    family = registry_family!(home, responsible: responsible)
    resident = registry_registration!(household: home)
    resident.update_columns(family_id: family.id)
    sign_in_as(agent)
    json_post "/home_visits", body(home, subject: "resident", patient_id: resident.patient_id,
                                         vector_inspection: report(activity: "li", measures: [], educational_action: true))
    expect(response).to have_http_status(:created)
    expect(HomeVisit.sole).to have_attributes(subject: "family_responsible", family_id: family.id, patient_id: responsible.id,
                                              reasons: [ 34, 35, 36 ])
    expect(VectorInspection.sole.household_id).to eq(home.id)
  end

  it "`reasons` com 35 → 422 reason_derived path reasons" do
    sign_in_as(agent)
    json_post "/home_visits", body(reasons: [ 1, 35 ])
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "reason_derived", "path" => "reasons" } ])
    expect(HomeVisit.count).to eq(0)
  end

  it "ACS com boletim → 403 cbo_not_allowed path vector_inspection; gate desligado → 403 feature_disabled" do
    acs = field_agent!(team: team)
    acs_area = registry_micro_area!(code: "02", team: team, acs: acs)
    sign_in_as(acs)
    json_post "/home_visits", body(registry_household!(micro_area: acs_area))
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed", "path" => "vector_inspection" } ])

    Platform::Features.set!(city: city, key: VectorControl::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(agent)
    json_post "/home_visits", body
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "path" => "vector_inspection" } ])
    expect([ HomeVisit.count, VectorInspection.count ]).to eq([ 0, 0 ])
  end

  it "sem domicílio → 422 vector_inspection_invalid path household_id (A-10)" do
    sign_in_as(agent)
    json_post "/home_visits", body.except("household_id").merge("micro_area_id" => area.id, "property_type" => "4")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "vector_inspection_invalid", "path" => "household_id" } ])
    json_post "/home_visits", body(vector_inspection: report.merge("deposits" => [ report["deposits"].first.merge("existing" => 1000) ]))
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "vector_inspection_invalid", "path" => "vector_inspection.deposits[0].existing" } ])
    expect(HomeVisit.count).to eq(0)
  end

  it "visita do ACE sem boletim segue como no 24b; GET da visita sem inspeção não tem a chave" do
    sign_in_as(agent)
    json_post "/home_visits", body(reasons: [ 1 ]).except("vector_inspection")
    expect(response).to have_http_status(:created)
    expect(json_body["visit"]).not_to have_key("vector_inspection")
    expect(HomeVisit.sole.reasons).to eq([ 1 ])
    expect([ VectorInspection.count, HouseholdVectorProfile.count ]).to eq([ 0, 0 ])
    get "/home_visits/#{HomeVisit.sole.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body).not_to have_key("vector_inspection")
  end

  it "ficha 8 da folha fechada traz motivosVisita [35, 36, 37]" do
    sign_in_as(agent)
    json_post "/home_visits", body
    expect(response).to have_http_status(:created)
    day = HomeVisitDay.sole
    expect(HomeVisits::CloseDay.call(day, by: agent, closed_by: "user")).to be_ok
    entry = LediOutboxEntry.find_by!(source_type: "HomeVisitDay", source_id: day.id)
    expect(inner(entry).visitasDomiciliares.sole.motivosVisita).to eq([ 35, 36, 37 ])
  end

  it "quem lê a visita pelo 24b vê o boletim (GET /home_visits/:id e a lista da equipe)" do
    sign_in_as(agent)
    json_post "/home_visits", body
    created = json_body["visit"]["vector_inspection"]
    visit = HomeVisit.sole
    get "/home_visits/#{visit.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body["vector_inspection"]).to eq(created)
    nurse = registry_nurse!(unit, team: team)
    sign_in_as(nurse)
    get "/home_visits", params: { team_id: team.id }
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].sole["vector_inspection"]).to eq(created)
  end
end

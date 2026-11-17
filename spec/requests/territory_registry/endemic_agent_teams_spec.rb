require "rails_helper"

# Módulo 35a (ADR 0054; contrato §20 Q14(1)): GET /territory/teams é o
# contexto de cadastro do dashboard. Com vector_control utilizável, as
# microáreas atribuídas ao agente de endemias (515140) saem com
# can_register true e property_types não residenciais; para o resto
# property_types é null (= todos os tipos) e can_register segue a regra do 24a.
RSpec.describe "Território — contexto de cadastro do agente de endemias", type: :request do
  let!(:city) { vector_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let!(:mine) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:agent) { endemic_agent!(team: team) }
  let(:assigned) { MicroAreaFieldAssignment.active.find_by!(professional_id: agent.professional.id).micro_area }

  def areas_for(user)
    sign_in_as(user)
    get "/territory/teams"
    expect(response).to have_http_status(:ok)
    json_body["teams"].sole["micro_areas"].to_h { [ _1["id"], _1.slice("can_register", "property_types") ] }
  end

  it "ACE com gate: as microáreas atribuídas com can_register true e property_types não residenciais; a não atribuída com can_register false" do
    rows = areas_for(agent)
    expect(rows[assigned.id]).to eq("can_register" => true, "property_types" => %w[2 3 4 5 6 12 13])
    expect(rows[mine.id]).to eq("can_register" => false, "property_types" => nil)
  end

  it "gate desligado → can_register false e property_types null" do
    agent
    Platform::Features.set!(city: city, key: VectorControl::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    rows = areas_for(agent)
    expect(rows.values).to all(eq("can_register" => false, "property_types" => nil))
  end

  it "ACS e enfermeiro: property_types null e can_register como antes" do
    assigned
    expect(areas_for(acs)).to eq(mine.id => { "can_register" => true, "property_types" => nil },
                                 assigned.id => { "can_register" => false, "property_types" => nil })
    expect(areas_for(registry_nurse!(unit, team: team)).values).to all(eq("can_register" => true, "property_types" => nil))
  end
end

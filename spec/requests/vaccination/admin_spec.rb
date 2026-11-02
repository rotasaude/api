require "rails_helper"

# Módulo 29 (ADR 0047; §15 V2/V14, D4): salas de vacina, equipe da sala, rede
# de frio municipal e data do go-live. Só municipal_admin; escrita com step-up.
RSpec.describe "Sala de vacina — administração", type: :request do
  let!(:city) { vaccination_city! }
  let(:admin) { pharmacy_admin! }
  let(:unit) { create_unit("UBS Jardim das Flores") }

  def events(name) = DomainEvent.where(name: name).order(:occurred_at, :id).map(&:payload)

  describe "salas" do
    it "cria a sala com o local vaccine_room; devolve a sala inteira (D4); segunda sala na unidade → 409 unit_taken" do
      stepped_up!(admin)
      json_post "/vaccination/admin/rooms", health_unit_id: unit.id, name: "Sala de vacina"
      expect(response).to have_http_status(:created)
      location = StockLocation.find(json_body["stock_location_id"])
      expect(location.kind).to eq("vaccine_room")
      expect(location.health_unit_id).to eq(unit.id)
      room = VaccineRoom.find(json_body["id"])
      expect(json_body).to eq("id" => room.id, "name" => "Sala de vacina", "active" => true,
                              "health_unit" => { "id" => unit.id, "name" => "UBS Jardim das Flores" },
                              "stock_location_id" => location.id, "staff" => [])
      expect(events("vaccine_room.saved")).to eq([ { "vaccine_room_id" => room.id, "user_id" => admin.id } ])

      json_post "/vaccination/admin/rooms", health_unit_id: unit.id, name: "Outra sala"
      expect([ response.status, json_body["error"] ]).to eq([ 409, "unit_taken" ])
    end

    it "a sala convive com a farmácia da mesma unidade" do
      unit_location!(unit)
      stepped_up!(admin)
      json_post "/vaccination/admin/rooms", health_unit_id: unit.id, name: "Sala de vacina"
      expect(response).to have_http_status(:created)
    end

    it "nome de 3 a 120 caracteres (V14): recusado, nunca cortado" do
      stepped_up!(admin)
      [ "ab", "x" * 121, 7, nil ].each do |name|
        json_post "/vaccination/admin/rooms", health_unit_id: unit.id, name: name
        expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "name" ])
      end
      json_post "/vaccination/admin/rooms", health_unit_id: unit.id, name: "x" * 120
      expect(response).to have_http_status(:created)
      expect(json_body["name"]).to eq("x" * 120)
    end

    it "unidade inexistente ou inativa → 422 health_unit_id" do
      stepped_up!(admin)
      json_post "/vaccination/admin/rooms", health_unit_id: SecureRandom.uuid, name: "Sala de vacina"
      expect([ response.status, json_body["path"] ]).to eq([ 422, "health_unit_id" ])
    end

    it "renomeia e desativa; desativar com saldo ou frasco aberto → 409 location_has_stock; sem saldo desativa o local junto" do
      room = vaccine_room!(unit)
      lot = vaccine_lot!(room, doses: 5)
      stepped_up!(admin)
      json_patch "/vaccination/admin/rooms/#{room.id}", name: "Sala 1"
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => room.id, "name" => "Sala 1", "active" => true)

      json_patch "/vaccination/admin/rooms/#{room.id}", active: false
      expect([ response.status, json_body["error"] ]).to eq([ 409, "location_has_stock" ])
      expect(room.reload.active).to be(true)

      adjustment = StockAdjustment.create!(stock_location: room.stock_location, stock_lot: lot, kind: "loss", status: "applied", quantity: -5,
                                           balance_at_request: 5, reason: "Frascos quebrados no transporte", requested_by_user: admin)
      StockMovement.create!(stock_location: room.stock_location, stock_lot: lot, immunobiological_code: "42", kind: "loss", quantity: -5,
                            stock_adjustment: adjustment, reason: "Frascos quebrados no transporte", recorded_by_user: admin,
                            recorded_at: Time.current)
      VialOpening.create!(vaccine_room: room, stock_lot: lot, doses_per_vial: 1, opened_at: Time.current, expires_at: 6.hours.from_now,
                          opened_by_user: admin)
      json_patch "/vaccination/admin/rooms/#{room.id}", active: false
      expect([ response.status, json_body["error"] ]).to eq([ 409, "location_has_stock" ])

      VialOpening.where(vaccine_room_id: room.id).update_all(closed_at: Time.current, closed_by_user_id: admin.id,
                                                              close_reason: "Frasco descartado ao fim do dia", technical_loss_doses: 0)
      json_patch "/vaccination/admin/rooms/#{room.id}", active: false
      expect(response).to have_http_status(:ok)
      expect(json_body["active"]).to be(false)
      expect(room.stock_location.reload.active).to be(false)
    end

    it "sala inexistente → 404; id não uuid → 404" do
      stepped_up!(admin)
      json_patch "/vaccination/admin/rooms/#{SecureRandom.uuid}", name: "Sala 1"
      expect(response).to have_http_status(:not_found)
      json_patch "/vaccination/admin/rooms/xx", name: "Sala 1"
      expect(response).to have_http_status(:not_found)
    end

    it "lista as salas com a equipe (D4) e a rede de frio (nil enquanto não existe)" do
      room = vaccine_room!(unit)
      vaccinator = room_member!(room)
      sign_in_as(admin)
      get "/vaccination/admin/rooms"
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq(
        "rooms" => [ { "id" => room.id, "name" => room.name, "active" => true,
                       "health_unit" => { "id" => unit.id, "name" => unit.name }, "stock_location_id" => room.stock_location_id,
                       "staff" => [ { "user_id" => vaccinator.id, "name" => vaccinator.professional.professional_name,
                                      "role" => "vaccinator", "cbo" => "322205" } ] } ],
        "cold_chain_central" => nil
      )
      central = cold_chain_central!
      get "/vaccination/admin/rooms"
      expect(json_body["cold_chain_central"]).to eq("id" => central.id, "name" => central.name, "kind" => "cold_chain_central",
                                                    "health_unit" => nil, "active" => true, "staff" => [])
    end

    it "só o municipal_admin; escrita sem step-up → 401" do
      sign_in_as(staff_with("operador-#{SecureRandom.hex(3)}@cidade.gov.br", "health_professional"))
      get "/vaccination/admin/rooms"
      expect(response).to have_http_status(:forbidden)

      sign_in_as(admin)
      json_post "/vaccination/admin/rooms", health_unit_id: unit.id, name: "Sala de vacina"
      expect(response).to have_http_status(:unauthorized)
      expect(VaccineRoom.count).to eq(0)
    end
  end

  describe "equipe da sala" do
    let(:room) { vaccine_room!(unit) }

    it "técnico vira vaccinator; room_lead só enfermeiro; CBO fora da lista recusado; devolve a sala inteira" do
      tecnica = screener!(unit, cbo: "322205")
      farmaceutico = screener!(unit, cbo: "223405")
      enfermeira = screener!(unit, cbo: "223505")
      stepped_up!(admin)
      json_post "/vaccination/admin/rooms/#{room.id}/staff", user_id: tecnica.id, role: "room_lead"
      expect([ response.status, json_body["error"] ]).to eq([ 422, "room_lead_requires_nurse" ])
      json_post "/vaccination/admin/rooms/#{room.id}/staff", user_id: farmaceutico.id, role: "vaccinator"
      expect([ response.status, json_body["error"] ]).to eq([ 422, "cbo_not_allowed" ])
      json_post "/vaccination/admin/rooms/#{room.id}/staff", user_id: tecnica.id, role: "vaccinator"
      expect(response).to have_http_status(:created)
      expect(json_body["id"]).to eq(room.id)
      expect(json_body["staff"]).to eq([ { "user_id" => tecnica.id, "name" => tecnica.professional.professional_name,
                                           "role" => "vaccinator", "cbo" => "322205" } ])
      expect(events("vaccine_room_staff.linked")).to eq([ { "vaccine_room_id" => room.id, "staff_user_id" => tecnica.id, "user_id" => admin.id } ])
      expect(enfermeira).to be_present
    end

    it "enfermeira (2235) entra como room_lead e como vaccinator; repetir o vínculo → 409 already_linked" do
      enfermeira = screener!(unit, cbo: "223505")
      stepped_up!(admin)
      json_post "/vaccination/admin/rooms/#{room.id}/staff", user_id: enfermeira.id, role: "room_lead"
      expect(response).to have_http_status(:created)
      json_post "/vaccination/admin/rooms/#{room.id}/staff", user_id: enfermeira.id, role: "room_lead"
      expect([ response.status, json_body["error"] ]).to eq([ 409, "already_linked" ])
      json_post "/vaccination/admin/rooms/#{room.id}/staff", user_id: enfermeira.id, role: "vaccinator"
      expect(response).to have_http_status(:created)
    end

    it "sem vínculo profissional na unidade → 422 professional_link_missing; sem Membership → role_not_granted" do
      outra = create_unit("UBS Outra")
      sem_vinculo = screener!(outra, cbo: "322205")
      stepped_up!(admin)
      json_post "/vaccination/admin/rooms/#{room.id}/staff", user_id: sem_vinculo.id, role: "vaccinator"
      expect([ response.status, json_body["error"] ]).to eq([ 422, "professional_link_missing" ])

      sem_membership = screener!(unit, cbo: "322205")
      sem_membership.memberships.where(role: "health_professional").update_all(revoked_at: Time.current)
      json_post "/vaccination/admin/rooms/#{room.id}/staff", user_id: sem_membership.id, role: "vaccinator"
      expect([ response.status, json_body["error"] ]).to eq([ 422, "role_not_granted" ])
    end

    it "papel inválido, user_id que não é string ou usuário inexistente → 422/404" do
      stepped_up!(admin)
      json_post "/vaccination/admin/rooms/#{room.id}/staff", user_id: SecureRandom.uuid, role: "janitor"
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "role" ])
      json_post "/vaccination/admin/rooms/#{room.id}/staff", user_id: 42, role: "vaccinator"
      expect([ response.status, json_body["path"] ]).to eq([ 422, "user_id" ])
      json_post "/vaccination/admin/rooms/#{room.id}/staff", user_id: SecureRandom.uuid, role: "vaccinator"
      expect(response).to have_http_status(:not_found)
      json_post "/vaccination/admin/rooms/#{SecureRandom.uuid}/staff", user_id: SecureRandom.uuid, role: "vaccinator"
      expect(response).to have_http_status(:not_found)
    end

    it "DELETE revoga o vínculo (204, uma vez) e grava o evento; vínculo que não existe → 404; vincular de novo grava outra linha" do
      user = room_member!(room)
      stepped_up!(admin)
      json_delete "/vaccination/admin/rooms/#{room.id}/staff", user_id: user.id, role: "vaccinator"
      expect(response).to have_http_status(:no_content)
      expect(events("vaccine_room_staff.revoked")).to eq([ { "vaccine_room_id" => room.id, "staff_user_id" => user.id, "user_id" => admin.id } ])
      json_delete "/vaccination/admin/rooms/#{room.id}/staff", user_id: user.id, role: "vaccinator"
      expect(response).to have_http_status(:not_found)
      json_post "/vaccination/admin/rooms/#{room.id}/staff", user_id: user.id, role: "vaccinator"
      expect(response).to have_http_status(:created)
      expect(VaccineRoomStaff.where(vaccine_room_id: room.id, user_id: user.id).count).to eq(2)
    end
  end

  describe "rede de frio municipal" do
    it "cria uma só vez (201, AdminLocation); a segunda → 409 already_exists; nome de 3 a 120" do
      stepped_up!(admin)
      json_post "/vaccination/admin/cold_chain_central", name: "ab"
      expect([ response.status, json_body["path"] ]).to eq([ 422, "name" ])
      json_post "/vaccination/admin/cold_chain_central", name: "Rede de frio municipal"
      expect(response).to have_http_status(:created)
      central = StockLocation.find_by!(kind: "cold_chain_central")
      expect(json_body).to eq("id" => central.id, "name" => "Rede de frio municipal", "kind" => "cold_chain_central",
                              "health_unit" => nil, "active" => true, "staff" => [])
      json_post "/vaccination/admin/cold_chain_central", name: "De novo"
      expect([ response.status, json_body["error"] ]).to eq([ 409, "already_exists" ])
    end

    it "a equipe vai pelo /pharmacy/admin existente, só stock_keeper, mesmo sem pharmacy ligado" do
      expect(Pharmacy::Gate.usable?(city)).to be(false)
      central = cold_chain_central!
      keeper = staff_with("frio@cidade.gov.br", "stock_keeper")
      stepped_up!(admin)
      json_post "/pharmacy/admin/locations/#{central.id}/staff", user_id: keeper.id, role: "stock_keeper"
      expect(response).to have_http_status(:created)
      expect(json_body).to include("id" => central.id, "kind" => "cold_chain_central",
                                   "staff" => [ { "user_id" => keeper.id, "name" => nil, "role" => "stock_keeper" } ])

      pharmacist = screener!(create_unit("UBS Farmácia"), cbo: "223405")
      Membership.create!(user: pharmacist, role: "pharmacist", granted_at: Time.current)
      json_post "/pharmacy/admin/locations/#{central.id}/staff", user_id: pharmacist.id, role: "pharmacist"
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "role" ])

      json_delete "/pharmacy/admin/locations/#{central.id}/staff", user_id: keeper.id, role: "stock_keeper"
      expect(response).to have_http_status(:no_content)
    end

    it "com vaccination desligado, a equipe da rede de frio → 403 feature_disabled" do
      central = cold_chain_central!
      keeper = staff_with("frio@cidade.gov.br", "stock_keeper")
      Platform::Features.set!(city: city, key: "vaccination", enabled: false, maintainer: ledi_maintainer!)
      stepped_up!(admin)
      json_post "/pharmacy/admin/locations/#{central.id}/staff", user_id: keeper.id, role: "stock_keeper"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "vaccination" } ])
    end

    it "a equipe da sala NÃO passa pelo /pharmacy/admin: 404" do
      room = vaccine_room!(unit)
      keeper = staff_with("frio@cidade.gov.br", "stock_keeper")
      stepped_up!(admin)
      json_post "/pharmacy/admin/locations/#{room.stock_location_id}/staff", user_id: keeper.id, role: "stock_keeper"
      expect(response).to have_http_status(:not_found)
      json_delete "/pharmacy/admin/locations/#{room.stock_location_id}/staff", user_id: keeper.id, role: "stock_keeper"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "go-live" do
    it "lê e grava go_live_on (ISO) com step-up; nulo limpa; formato inválido → 422" do
      sign_in_as(admin)
      get "/vaccination/admin/settings"
      expect(json_body).to eq("go_live_on" => nil)

      stepped_up!(admin)
      json_patch "/vaccination/admin/settings", go_live_on: "2026-11-02"
      expect(json_body).to eq("go_live_on" => "2026-11-02")
      get "/vaccination/admin/settings"
      expect(json_body).to eq("go_live_on" => "2026-11-02")
      expect(VaccinationSetting.current.updated_by_user_id).to eq(admin.id)

      [ "02/11/2026", "2026-13-40", 20_261_102, "" ].each do |value|
        json_patch "/vaccination/admin/settings", go_live_on: value
        expect([ response.status, json_body["path"] ]).to eq([ 422, "go_live_on" ])
      end
      json_patch "/vaccination/admin/settings", other: 1
      expect([ response.status, json_body["path"] ]).to eq([ 422, "other" ])
      json_patch "/vaccination/admin/settings", go_live_on: nil
      expect(json_body).to eq("go_live_on" => nil)
    end

    it "escrita sem step-up → 401; vaccination desligado → 403 feature_disabled em todas as rotas" do
      sign_in_as(admin)
      json_patch "/vaccination/admin/settings", go_live_on: "2026-11-02"
      expect(response).to have_http_status(:unauthorized)

      Platform::Features.set!(city: city, key: "vaccination", enabled: false, maintainer: ledi_maintainer!)
      [ "/vaccination/admin/rooms", "/vaccination/admin/settings", "/vaccination/my_locations" ].each do |path|
        get path
        expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "vaccination" } ])
      end
    end
  end

  describe "GET /vaccination/my_locations (V2/D2)" do
    it "a pessoa da sala vê a sala com o papel; o almoxarife da rede de frio vê a central e as salas ativas com roles []" do
      room = vaccine_room!(unit)
      other_room = vaccine_room!
      closed = vaccine_room!
      closed.update!(active: false)
      lead = room_member!(room, role: "room_lead", cbo: "223505")

      sign_in_as(lead)
      get "/vaccination/my_locations"
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("locations" => [ { "id" => room.stock_location_id, "name" => room.stock_location.name, "kind" => "vaccine_room",
                                                 "health_unit" => { "id" => unit.id, "name" => unit.name }, "active" => true,
                                                 "roles" => [ "room_lead" ], "room_id" => room.id } ])

      central = cold_chain_central!
      keeper = staff_with("frio@cidade.gov.br", "stock_keeper")
      StockLocationStaff.create!(stock_location: central, user: keeper, role: "stock_keeper", granted_by_user: admin, granted_at: Time.current)
      sign_in_as(keeper)
      get "/vaccination/my_locations"
      rows = json_body.fetch("locations")
      expect(rows.map { |row| row["kind"] }.tally).to eq("cold_chain_central" => 1, "vaccine_room" => 2)
      expect(rows.find { |row| row["kind"] == "cold_chain_central" }).to eq(
        "id" => central.id, "name" => central.name, "kind" => "cold_chain_central", "health_unit" => nil, "active" => true,
        "roles" => [ "stock_keeper" ], "room_id" => nil
      )
      expect(rows.select { |row| row["kind"] == "vaccine_room" }.map { |row| [ row["room_id"], row["roles"] ] })
        .to contain_exactly([ room.id, [] ], [ other_room.id, [] ])
    end

    it "quem não tem papel nenhum recebe lista vazia" do
      vaccine_room!
      sign_in_as(staff_with("ninguem-#{SecureRandom.hex(3)}@cidade.gov.br", "health_professional"))
      get "/vaccination/my_locations"
      expect(json_body).to eq("locations" => [])
    end
  end
end

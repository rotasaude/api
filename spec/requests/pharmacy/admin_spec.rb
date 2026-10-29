require "rails_helper"

# Módulo 27a (ADR 0045; contrato §3): locais de estoque, equipe vinculada e
# parâmetros da farmácia. Leitura e escrita do municipal_admin; escrita com
# step-up. Escritas devolvem o objeto (sem envelope); DELETE da equipe → 204.
RSpec.describe "Farmácia — administração", type: :request do
  let!(:city) { pharmacy_city! }
  let(:admin) { pharmacy_admin! }
  let(:unit) { create_unit("UBS Jardim das Flores") }

  def json_delete(path, params = {}) = delete(path, params: params.to_json, headers: { "CONTENT_TYPE" => "application/json" })
  def events = DomainEvent.where(name: "pharmacy.settings_changed").order(:occurred_at, :id).map(&:payload)

  # Saldo zerado por perda crua (documento de ajuste + movimento), sem o livro.
  def zero_out!(location, lot)
    quantity = balance_of(location, lot)
    adjustment = StockAdjustment.create!(stock_location: location, stock_lot: lot, kind: "loss", status: "applied", quantity: -quantity,
                                         balance_at_request: quantity, reason: "Frascos quebrados no transporte", requested_by_user: admin)
    StockMovement.create!(stock_location: location, stock_lot: lot, catalog_item_id: lot.catalog_item_id, kind: "loss", quantity: -quantity,
                          stock_adjustment: adjustment, reason: "Frascos quebrados no transporte", recorded_by_user: admin, recorded_at: Time.current)
  end

  describe "locais" do
    it "o admin com step-up cria o central e a farmácia da UBS (201, objeto sem envelope); a unidade passa a dispensar" do
      stepped_up!(admin)
      json_post "/pharmacy/admin/locations", kind: "central", name: "Central de Abastecimento Farmacêutico", active: true
      expect(response).to have_http_status(:created)
      central = StockLocation.find_by!(kind: "central")
      expect(json_body).to eq("id" => central.id, "name" => "Central de Abastecimento Farmacêutico", "kind" => "central",
                              "health_unit" => nil, "active" => true, "staff" => [])

      expect(unit.dispenses).to be(false)
      json_post "/pharmacy/admin/locations", kind: "unit", health_unit_id: unit.id, name: "Farmácia da UBS Jardim das Flores", active: true
      expect(response).to have_http_status(:created)
      farmacia = StockLocation.find_by!(kind: "unit")
      expect(json_body).to eq("id" => farmacia.id, "name" => "Farmácia da UBS Jardim das Flores", "kind" => "unit",
                              "health_unit" => { "id" => unit.id, "name" => "UBS Jardim das Flores" }, "active" => true, "staff" => [])
      expect(unit.reload.dispenses).to be(true)
      expect(farmacia.updated_by_user).to eq(admin)
      expect(events).to eq([ { "subject" => "location", "stock_location_id" => central.id, "user_id" => admin.id },
                             { "subject" => "location", "stock_location_id" => farmacia.id, "user_id" => admin.id } ])
    end

    it "sem step-up → 401 mfa_required e nada é criado" do
      sign_in_as(step_up_enrolled!(admin))
      json_post "/pharmacy/admin/locations", kind: "central", name: "Central de Abastecimento Farmacêutico"
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      expect(StockLocation.count).to eq(0)
      expect(events).to be_empty
    end

    it "segundo almoxarifado central → 409 central_exists (mesmo com o primeiro desativado)" do
      stepped_up!(admin)
      json_post "/pharmacy/admin/locations", kind: "central", name: "Central de Abastecimento Farmacêutico"
      expect(response).to have_http_status(:created)
      json_post "/pharmacy/admin/locations", kind: "central", name: "Outro almoxarifado"
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "central_exists" } ])
      StockLocation.find_by!(kind: "central").update!(active: false)
      json_post "/pharmacy/admin/locations", kind: "central", name: "Outro almoxarifado"
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "central_exists" } ])
      expect(StockLocation.count).to eq(1)
    end

    it "unidade que já tem local → 409 unit_taken; a marca da unidade não é regravada à toa" do
      other = unit_location!(unit)
      stepped_up!(admin)
      json_post "/pharmacy/admin/locations", kind: "unit", health_unit_id: unit.id, name: "Segunda farmácia da unidade"
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "unit_taken" } ])
      expect(StockLocation.where(health_unit_id: unit.id)).to contain_exactly(other)
    end

    it "recusa com path: tipo, nome, unidade e ativo; nada é gravado" do
      stepped_up!(admin)
      inactive = create_unit("UBS Inativa", active: false)
      cases = {
        { kind: "warehouse", name: "Almoxarifado qualquer" } => "kind",
        { kind: "central", name: "Ab" } => "name",
        { kind: "central", name: "A" * 121 } => "name",
        { kind: "central", name: 123 } => "name",
        { kind: "central", name: "Almoxarifado central", active: "yes" } => "active",
        { kind: "central", name: "Almoxarifado central", health_unit_id: unit.id } => "health_unit_id",
        { kind: "unit", name: "Farmácia sem unidade" } => "health_unit_id",
        { kind: "unit", name: "Farmácia unidade inativa", health_unit_id: inactive.id } => "health_unit_id",
        { kind: "unit", name: "Farmácia unidade inexistente", health_unit_id: SecureRandom.uuid } => "health_unit_id",
        { kind: "unit", name: "Farmácia unidade lixo", health_unit_id: "x" } => "health_unit_id"
      }
      cases.each do |body, path|
        json_post "/pharmacy/admin/locations", body
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => path } ]), "esperava path #{path} para #{body}"
      end
      expect(StockLocation.count).to eq(0)
      expect(events).to be_empty
    end

    it "nome repetido (sem diferenciar caixa) → 422 invalid_request path name" do
      unit_location!(unit).update!(name: "Farmacia Jardim")
      other_unit = create_unit("UBS Boa Vista")
      stepped_up!(admin)
      json_post "/pharmacy/admin/locations", kind: "unit", health_unit_id: other_unit.id, name: "FARMACIA JARDIM"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "name" } ])
      expect(other_unit.reload.dispenses).to be(false)
    end

    it "PATCH renomeia (200, objeto); tipo e unidade não mudam; sem mudança não gera evento" do
      location = unit_location!(unit)
      stepped_up!(admin)
      json_patch "/pharmacy/admin/locations/#{location.id}", name: "Farmácia Jardim das Flores"
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => location.id, "name" => "Farmácia Jardim das Flores", "kind" => "unit", "active" => true)
      expect(events.size).to eq(1)

      json_patch "/pharmacy/admin/locations/#{location.id}", name: "Farmácia Jardim das Flores"
      expect(response).to have_http_status(:ok)
      expect(events.size).to eq(1)

      json_patch "/pharmacy/admin/locations/#{location.id}", kind: "central"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "kind" } ])
      json_patch "/pharmacy/admin/locations/#{location.id}", health_unit_id: create_unit("UBS Outra").id
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "health_unit_id" } ])
      json_patch "/pharmacy/admin/locations/#{location.id}", name: "x"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "name" } ])
      expect(location.reload.name).to eq("Farmácia Jardim das Flores")
    end

    it "PATCH de id inexistente ou fora do formato → 404" do
      stepped_up!(admin)
      json_patch "/pharmacy/admin/locations/#{SecureRandom.uuid}", name: "Farmácia fantasma"
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      json_patch "/pharmacy/admin/locations/nao-e-uuid", name: "Farmácia fantasma"
      expect(response).to have_http_status(:not_found)
    end

    it "desativar com saldo em algum lote → 409 location_has_stock; zerado, desativa (200) e a unidade deixa de dispensar" do
      location = unit_location!(unit)
      lot = stocked_lot!(location, item: losartana, quantity: "30")
      stepped_up!(admin)
      json_patch "/pharmacy/admin/locations/#{location.id}", active: false
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "location_has_stock" } ])
      expect(location.reload.active).to be(true)
      expect(unit.reload.dispenses).to be(true)
      expect(events).to be_empty

      zero_out!(location, lot)
      json_patch "/pharmacy/admin/locations/#{location.id}", active: false
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => location.id, "active" => false)
      expect(location.reload.active).to be(false)
      expect(unit.reload.dispenses).to be(false)
      expect(events).to eq([ { "subject" => "location", "stock_location_id" => location.id, "user_id" => admin.id } ])

      json_patch "/pharmacy/admin/locations/#{location.id}", active: true
      expect(response).to have_http_status(:ok)
      expect(location.reload.active).to be(true)
      expect(unit.reload.dispenses).to be(true)
    end

    # Pendência além do saldo: transferência enviada e ajuste por decidir.
    def sent_transfer!(from:, to:, lot:)
      transfer = StockTransfer.create!(from_location: from, to_location: to, sent_by_user: admin, status: "sent", sent_at: Time.current)
      StockTransferItem.create!(stock_transfer: transfer, stock_lot: lot, quantity_sent: 5)
      transfer
    end

    it "transferência enviada PARA o local (em trânsito) → 409 location_has_stock; recebida, desativa" do
      location = unit_location!(unit)
      lot = stocked_lot!(central_location!, item: losartana, quantity: "30")
      transfer = sent_transfer!(from: central_location!, to: location, lot: lot)
      stepped_up!(admin)
      json_patch "/pharmacy/admin/locations/#{location.id}", active: false
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "location_has_stock" } ])
      expect(location.reload.active).to be(true)
      expect(unit.reload.dispenses).to be(true)
      expect(events).to be_empty

      transfer.update!(status: "received", received_at: Time.current, received_by_user: admin)
      json_patch "/pharmacy/admin/locations/#{location.id}", active: false
      expect(response).to have_http_status(:ok)
      expect(unit.reload.dispenses).to be(false)
    end

    it "transferência enviada DO local (origem) → 409 location_has_stock; o central só desativa sem saída em trânsito" do
      central = central_location!
      lot = stocked_lot!(central, item: losartana, quantity: "30")
      zero_out!(central, lot)
      transfer = sent_transfer!(from: central, to: unit_location!(unit), lot: lot)
      stepped_up!(admin)
      json_patch "/pharmacy/admin/locations/#{central.id}", active: false
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "location_has_stock" } ])
      expect(central.reload.active).to be(true)

      transfer.update!(status: "received", received_at: Time.current, received_by_user: admin)
      json_patch "/pharmacy/admin/locations/#{central.id}", active: false
      expect(response).to have_http_status(:ok)
    end

    it "transferência já recebida, ou entre outros locais, não impede" do
      location = unit_location!(unit)
      lot = stocked_lot!(central_location!, item: losartana, quantity: "30")
      other = sent_transfer!(from: central_location!, to: unit_location!, lot: lot)
      done = sent_transfer!(from: central_location!, to: location, lot: lot)
      done.update!(status: "received", received_at: Time.current, received_by_user: admin)
      stepped_up!(admin)
      json_patch "/pharmacy/admin/locations/#{location.id}", active: false
      expect(response).to have_http_status(:ok)
      expect(other.reload.status).to eq("sent")
    end

    it "ajuste pendente em lote do local → 409 location_has_stock; decidido, desativa" do
      location = unit_location!(unit)
      lot = stocked_lot!(location, item: losartana, quantity: "30")
      zero_out!(location, lot)
      adjustment = StockAdjustment.create!(stock_location: location, stock_lot: lot, kind: "adjustment", status: "pending", quantity: 5,
                                           counted_quantity: 5, balance_at_request: 0, reason: "Contagem do inventário de outubro",
                                           requested_by_user: admin)
      stepped_up!(admin)
      json_patch "/pharmacy/admin/locations/#{location.id}", active: false
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "location_has_stock" } ])
      expect(location.reload.active).to be(true)
      expect(events).to be_empty

      adjustment.update!(status: "rejected", decided_by_user: pharmacy_staff!(location, "stock_keeper"), decided_at: Time.current, decision_reason: "Contagem errada")
      json_patch "/pharmacy/admin/locations/#{location.id}", active: false
      expect(response).to have_http_status(:ok)
    end

    it "saldo em lote de outro local não impede a desativação" do
      location = unit_location!(unit)
      stocked_lot!(unit_location!, item: losartana, quantity: "30")
      stepped_up!(admin)
      json_patch "/pharmacy/admin/locations/#{location.id}", active: false
      expect(response).to have_http_status(:ok)
    end

    it "reativar um local cuja unidade foi desativada → 422 invalid_request path active" do
      location = unit_location!(unit)
      location.update!(active: false)
      unit.update!(active: false, dispenses: false)
      stepped_up!(admin)
      json_patch "/pharmacy/admin/locations/#{location.id}", active: true
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "active" } ])
      expect(location.reload.active).to be(false)
    end

    it "ordem de travas: os lotes antes do local (lote → local), para não travar contra a dispensação" do
      location = unit_location!(unit)
      lot = stocked_lot!(location, item: losartana, quantity: "30")
      zero_out!(location, lot)
      stepped_up!(admin)
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
      begin
        json_patch "/pharmacy/admin/locations/#{location.id}", active: false
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
      expect(response).to have_http_status(:ok)
      lots_lock = statements.index { |sql| sql.include?('FROM "stock_lots"') && sql.include?("FOR UPDATE") }
      location_lock = statements.index { |sql| sql.include?('FROM "stock_locations"') && sql.include?("FOR UPDATE") }
      expect(lots_lock).to be_present
      expect(location_lock).to be_present
      expect(lots_lock).to be < location_lock
    end

    it "GET lista todos os locais (inclusive inativos) com a equipe ativa, sem e-mail; o admin lê sem step-up" do
      central = central_location!
      location = unit_location!(unit)
      inactive = unit_location!
      inactive.update!(active: false)
      pharmacist = pharmacy_staff!(location, "pharmacist")
      keeper = pharmacy_staff!(location, "stock_keeper")
      gone = pharmacy_staff!(location, "pharmacy_assistant")
      StockLocationStaff.active.find_by!(user: gone).update!(revoked_at: Time.current, revoked_by_user: admin)

      sign_in_as(admin)
      get "/pharmacy/admin/locations"
      expect(response).to have_http_status(:ok)
      locations = json_body.fetch("locations")
      expect(locations.map { |row| row["id"] }).to match_array([ central.id, location.id, inactive.id ])
      expect(locations.find { |row| row["id"] == inactive.id }).to include("active" => false)
      staff = locations.find { |row| row["id"] == location.id }.fetch("staff")
      expect(staff).to contain_exactly({ "user_id" => pharmacist.id, "name" => pharmacist.professional.professional_name, "role" => "pharmacist" },
                                       { "user_id" => keeper.id, "name" => nil, "role" => "stock_keeper" })
      expect(locations.find { |row| row["id"] == central.id }.fetch("staff")).to eq([])
      expect(response.body).not_to include("@")
    end
  end

  describe "equipe" do
    let!(:location) { unit_location!(unit) }

    def pharmacist_candidate!(cbo: "223405")
      user = screener!(unit, cbo: cbo)
      Membership.create!(user: user, role: "pharmacist", granted_at: Time.current)
      user
    end

    it "vincula o farmacêutico com CBO 2234* e Membership ativa (201, o local com a equipe); evento só com ids" do
      user = pharmacist_candidate!
      stepped_up!(admin)
      json_post "/pharmacy/admin/locations/#{location.id}/staff", user_id: user.id, role: "pharmacist"
      expect(response).to have_http_status(:created)
      expect(json_body).to include("id" => location.id, "staff" => [ { "user_id" => user.id, "name" => user.professional.professional_name, "role" => "pharmacist" } ])
      link = StockLocationStaff.active.find_by!(user: user)
      expect([ link.stock_location_id, link.role, link.granted_by_user_id ]).to eq([ location.id, "pharmacist", admin.id ])
      expect(Pharmacy::Access.roles_at(user: user, location: location)).to eq(Set["pharmacist"])
      expect(events).to eq([ { "subject" => "staff", "stock_location_id" => location.id, "staff_user_id" => user.id, "user_id" => admin.id } ])
    end

    it "Review Focus 4: farmacêutico sem CBO 2234* não se vincula → 422 cbo_not_allowed" do
      user = pharmacist_candidate!(cbo: "225125")
      stepped_up!(admin)
      json_post "/pharmacy/admin/locations/#{location.id}/staff", user_id: user.id, role: "pharmacist"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "cbo_not_allowed" } ])
      expect(StockLocationStaff.where(user: user)).to be_empty
    end

    it "vínculo profissional encerrado não vale como CBO 2234*" do
      user = pharmacist_candidate!
      ProfessionalLink.where(professional: user.professional).update_all(ended_at: Time.current, ended_by_user_id: admin.id)
      stepped_up!(admin)
      json_post "/pharmacy/admin/locations/#{location.id}/staff", user_id: user.id, role: "pharmacist"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "cbo_not_allowed" } ])
    end

    it "sem a Membership do papel → 422 role_not_granted; Membership revogada também" do
      user = screener!(unit, cbo: "223405")
      stepped_up!(admin)
      json_post "/pharmacy/admin/locations/#{location.id}/staff", user_id: user.id, role: "pharmacist"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "role_not_granted" } ])
      json_post "/pharmacy/admin/locations/#{location.id}/staff", user_id: user.id, role: "stock_keeper"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "role_not_granted" } ])

      Membership.create!(user: user, role: "stock_keeper", granted_at: Time.current).revoke!
      json_post "/pharmacy/admin/locations/#{location.id}/staff", user_id: user.id, role: "stock_keeper"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "role_not_granted" } ])
      expect(StockLocationStaff.count).to eq(0)
    end

    it "o almoxarife não precisa de CBO: basta a Membership stock_keeper" do
      user = staff_with("almoxarife-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper")
      stepped_up!(admin)
      json_post "/pharmacy/admin/locations/#{location.id}/staff", user_id: user.id, role: "stock_keeper"
      expect(response).to have_http_status(:created)
      expect(json_body.fetch("staff")).to eq([ { "user_id" => user.id, "name" => nil, "role" => "stock_keeper" } ])
    end

    it "mesmo papel no mesmo local, duas vezes → 409 already_linked; outro papel ou outro local passa" do
      user = staff_with("almoxarife-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper")
      other = unit_location!
      stepped_up!(admin)
      json_post "/pharmacy/admin/locations/#{location.id}/staff", user_id: user.id, role: "stock_keeper"
      expect(response).to have_http_status(:created)
      json_post "/pharmacy/admin/locations/#{location.id}/staff", user_id: user.id, role: "stock_keeper"
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_linked" } ])
      json_post "/pharmacy/admin/locations/#{other.id}/staff", user_id: user.id, role: "stock_keeper"
      expect(response).to have_http_status(:created)
      expect(StockLocationStaff.active.where(user: user).count).to eq(2)
    end

    it "recusas de corpo: papel desconhecido e usuário mal formado → 422 com path; usuário inexistente ou local inexistente → 404" do
      stepped_up!(admin)
      json_post "/pharmacy/admin/locations/#{location.id}/staff", user_id: SecureRandom.uuid, role: "janitor"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "role" } ])
      json_post "/pharmacy/admin/locations/#{location.id}/staff", user_id: 42, role: "stock_keeper"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "user_id" } ])
      json_post "/pharmacy/admin/locations/#{location.id}/staff", user_id: SecureRandom.uuid, role: "stock_keeper"
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      user = staff_with("almoxarife-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper")
      json_post "/pharmacy/admin/locations/#{SecureRandom.uuid}/staff", user_id: user.id, role: "stock_keeper"
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    end

    it "desvincula (204 sem corpo; o vínculo é revogado, não apagado); a segunda vez → 404; vincular de novo vale" do
      user = staff_with("almoxarife-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper")
      stepped_up!(admin)
      json_post "/pharmacy/admin/locations/#{location.id}/staff", user_id: user.id, role: "stock_keeper"
      json_delete "/pharmacy/admin/locations/#{location.id}/staff", user_id: user.id, role: "stock_keeper"
      expect(response).to have_http_status(:no_content)
      expect(response.body).to be_empty
      link = StockLocationStaff.find_by!(user: user)
      expect([ link.revoked_at.present?, link.revoked_by_user_id ]).to eq([ true, admin.id ])
      expect(Pharmacy::Access.roles_at(user: user, location: location)).to be_empty
      expect(events.last).to eq({ "subject" => "staff", "stock_location_id" => location.id, "staff_user_id" => user.id, "user_id" => admin.id })

      json_delete "/pharmacy/admin/locations/#{location.id}/staff", user_id: user.id, role: "stock_keeper"
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      expect(events.size).to eq(2)

      json_post "/pharmacy/admin/locations/#{location.id}/staff", user_id: user.id, role: "stock_keeper"
      expect(response).to have_http_status(:created)
      expect(StockLocationStaff.where(user: user).count).to eq(2)
    end

    it "sem step-up → 401 mfa_required (vincular e desvincular)" do
      user = staff_with("almoxarife-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper")
      sign_in_as(step_up_enrolled!(admin))
      json_post "/pharmacy/admin/locations/#{location.id}/staff", user_id: user.id, role: "stock_keeper"
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      json_delete "/pharmacy/admin/locations/#{location.id}/staff", user_id: user.id, role: "stock_keeper"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "parâmetros" do
    let(:full) do
      { common_validity_days: 45, continuous_validity_days: 200, continuous_interval_days: 28, expiry_alert_days: 60, adjustment_approval_percent: 15 }
    end

    it "GET devolve as cinco chaves (os padrões da migração)" do
      sign_in_as(admin)
      get "/pharmacy/admin/settings"
      expect([ response.status, json_body ]).to eq([ 200, { "common_validity_days" => 30, "continuous_validity_days" => 180, "continuous_interval_days" => 25,
                                                           "expiry_alert_days" => 90, "adjustment_approval_percent" => 10 } ])
    end

    it "PATCH com step-up grava as cinco (200, objeto) e gera o evento só com subject e user_id" do
      stepped_up!(admin)
      json_patch "/pharmacy/admin/settings", full
      expect([ response.status, json_body ]).to eq([ 200, full.stringify_keys ])
      setting = PharmacySetting.find(1)
      expect([ setting.common_validity_days, setting.adjustment_approval_percent, setting.updated_by_user_id ]).to eq([ 45, 15, admin.id ])
      get "/pharmacy/admin/settings"
      expect(json_body).to eq(full.stringify_keys)
      expect(events).to eq([ { "subject" => "settings", "user_id" => admin.id } ])
    end

    it "PATCH igual ao gravado: 200 e nenhum evento novo" do
      stepped_up!(admin)
      json_patch "/pharmacy/admin/settings", full
      json_patch "/pharmacy/admin/settings", full
      expect(response).to have_http_status(:ok)
      expect(events.size).to eq(1)
    end

    it "adjustment_approval_percent: 101 → 422 invalid_request path adjustment_approval_percent; nada muda" do
      stepped_up!(admin)
      json_patch "/pharmacy/admin/settings", full.merge(adjustment_approval_percent: 101)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "adjustment_approval_percent" } ])
      expect(PharmacySetting.find(1).common_validity_days).to eq(30)
      expect(events).to be_empty
    end

    it "faixas, tipos, chave faltando e chave desconhecida → 422 com path" do
      stepped_up!(admin)
      {
        full.merge(common_validity_days: 0) => "common_validity_days",
        full.merge(continuous_validity_days: 366) => "continuous_validity_days",
        full.merge(continuous_interval_days: 91) => "continuous_interval_days",
        full.merge(expiry_alert_days: -1) => "expiry_alert_days",
        full.merge(adjustment_approval_percent: "10") => "adjustment_approval_percent",
        full.merge(adjustment_approval_percent: 10.5) => "adjustment_approval_percent",
        full.merge(expiry_alert_days: true) => "expiry_alert_days",
        full.except(:expiry_alert_days) => "expiry_alert_days",
        full.merge(extra: 1) => "extra",
        {} => "common_validity_days"
      }.each do |body, path|
        json_patch "/pharmacy/admin/settings", body
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => path } ]), "esperava path #{path} para #{body}"
      end
      expect(PharmacySetting.find(1).expiry_alert_days).to eq(90)
    end

    it "os limites das faixas valem (0 e 100 no percentual; 1 e 365 nos prazos)" do
      stepped_up!(admin)
      json_patch "/pharmacy/admin/settings", full.merge(adjustment_approval_percent: 0, common_validity_days: 1, expiry_alert_days: 365)
      expect(response).to have_http_status(:ok)
      json_patch "/pharmacy/admin/settings", full.merge(adjustment_approval_percent: 100, continuous_interval_days: 90)
      expect(response).to have_http_status(:ok)
    end

    it "sem step-up → 401 mfa_required" do
      sign_in_as(step_up_enrolled!(admin))
      json_patch "/pharmacy/admin/settings", full
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
    end
  end

  describe "acesso" do
    it "profissional → 403 missing_role em todas as rotas do admin; sem sessão → 401" do
      location = unit_location!(unit)
      get "/pharmacy/admin/locations"
      expect(response).to have_http_status(:unauthorized)

      sign_in_as(doctor!(unit))
      get "/pharmacy/admin/locations"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      get "/pharmacy/admin/settings"
      expect(response).to have_http_status(:forbidden)
      json_patch "/pharmacy/admin/settings", { common_validity_days: 30 }
      expect(response).to have_http_status(:forbidden)
      json_post "/pharmacy/admin/locations", kind: "central", name: "Central de Abastecimento"
      expect(response).to have_http_status(:forbidden)
      json_patch "/pharmacy/admin/locations/#{location.id}", name: "Outro nome para a farmácia"
      expect(response).to have_http_status(:forbidden)
      json_post "/pharmacy/admin/locations/#{location.id}/staff", user_id: SecureRandom.uuid, role: "stock_keeper"
      expect(response).to have_http_status(:forbidden)
      expect(location.reload.name).not_to eq("Outro nome para a farmácia")
    end

    it "o farmacêutico e o almoxarife também não administram (403, mesmo com step-up)" do
      location = unit_location!(unit)
      pharmacist = pharmacy_staff!(location, "pharmacist")
      stepped_up!(pharmacist)
      get "/pharmacy/admin/locations"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      json_post "/pharmacy/admin/locations", kind: "central", name: "Central de Abastecimento"
      expect(response).to have_http_status(:forbidden)
    end

    it "interruptor desligado → 403 feature_disabled em leitura e escrita" do
      Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)
      stepped_up!(admin)
      get "/pharmacy/admin/locations"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "pharmacy" } ])
      get "/pharmacy/admin/settings"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "pharmacy" } ])
      json_patch "/pharmacy/admin/settings", { common_validity_days: 30 }
      expect(response).to have_http_status(:forbidden)
      json_post "/pharmacy/admin/locations", kind: "central", name: "Central de Abastecimento"
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "pharmacy")
      expect(StockLocation.count).to eq(0)
    end
  end
end

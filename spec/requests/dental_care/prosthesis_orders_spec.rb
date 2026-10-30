require "rails_helper"

# Módulo 28 (ADR 0046; Desvio 12; contrato §16 O10, O27; Task 11): pedido de
# prótese e laboratório. Criação pelo dentista autor, etapas por quem tem vínculo
# odontológico na unidade, instalação só pela finalização da consulta.
RSpec.describe "Saúde bucal — prótese e laboratório", type: :request do
  let!(:city) { dental_city! }
  let(:unit) { create_unit }
  let(:dentist) { dentist!(unit) }
  let(:citizen) { verified_citizen!(1, social_name: "Mariana") }
  let(:sigtap) { "0701070145" }
  let(:lab) { { name: "Laboratório Sorriso Ltda" } }

  def events(name) = DomainEvent.where(name: name).order(:occurred_at, :id).map(&:payload)
  def viewed = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at)

  # Consulta que molda: finalizada (o atendimento fecha para a próxima).
  let!(:moulding) { finalized_dental!(unit: unit, by: dentist, citizen: citizen) }
  let(:patient_id) { moulding.patient_id }

  def create_order(laboratory: lab, by: dentist, **over)
    sign_in_as(by)
    json_post "/dental/prosthesis_orders", { patient_id: patient_id, consultation_id: moulding.id, sigtap: sigtap, laboratory: laboratory }.merge(over)
  end

  def order! = create_order.then { DentalProsthesisOrder.find(json_body.fetch("id")) }

  def advance!(order, *stages)
    stages.each { |stage| json_post "/dental/prosthesis_orders/#{order.id}/stages", stage: stage }
  end

  def install_attempt(order, code: sigtap, location: { "kind" => "tooth", "tooth" => 21 })
    body = dental_body(dental: { "procedures" => [ { "sigtap" => code, "location" => location,
                                                        "prosthesis_order_id" => order.id } ] })
    consultation = dental_consultation!(unit: unit, by: dentist, citizen: citizen)
    saved = Consultations::SaveDraft.call(consultation: consultation, params: body, by: dentist)
    raise "rascunho recusado: #{saved.reason}" if saved.failure?

    [ consultation, Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: dentist) ]
  end

  describe "POST /dental/prosthesis_orders" do
    it "dentista autor cria com prestador do 26a: 201, etapa impression, evento só com ids" do
      provider = own_provider!(unit, name: "Lab da Rede")
      create_order(laboratory: { care_provider_id: provider.id })
      expect(response).to have_http_status(:created)
      expect(json_body).to include("sigtap" => sigtap, "stage" => "impression", "installed_in_consultation_id" => nil,
                                   "name" => "PROTESES CORONARIAS / INTRA-RADICULARES FIXAS / ADESIVAS (POR ELEMENTO)",
                                   "laboratory" => { "care_provider_id" => provider.id, "name" => "Lab da Rede" },
                                   "health_unit" => { "id" => unit.id, "name" => unit.name })
      expect(json_body["patient"]).to eq("id" => patient_id, "display_name" => "Mariana", "has_cpf" => true, "cns_masked" => json_body.dig("patient", "cns_masked"))
      expect(json_body["stages"]).to match([ { "stage" => "impression", "at" => be_a(String), "by" => { "name" => dentist.professional.professional_name } } ])
      expect(json_body).not_to have_key("created_at")
      expect(events("prosthesis_order.created")).to eq([ { "order_id" => json_body["id"], "user_id" => dentist.id } ])
    end

    it "com laboratório por nome: guarda o nome e não o publica em evento" do
      create_order
      expect(response).to have_http_status(:created)
      expect(json_body["laboratory"]).to eq("care_provider_id" => nil, "name" => "Laboratório Sorriso Ltda")
      expect(DomainEvent.where("name LIKE 'prosthesis_order.%'").map(&:payload).to_s).not_to include("Sorriso")
    end

    it "ASB: 403 missing_role; outro dentista sem a consulta: 403 not_author; sem login de profissional: 403" do
      create_order(by: auxiliary!(unit))
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
      create_order(by: dentist!(unit))
      expect([ response.status, json_body["error"] ]).to eq([ 403, "not_author" ])
      create_order(by: reception!)
      expect(response).to have_http_status(:forbidden)
      expect(DentalProsthesisOrder.count).to eq(0)
    end

    it "SIGTAP fora de PROSTHESIS_CODES: 422 sigtap" do
      create_order(sigtap: "0307010031")
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "sigtap" ])
    end

    it "laboratório inválido: os dois juntos, nenhum, nome curto ou prestador inativo/inexistente: 422 laboratory" do
      provider = own_provider!(unit)
      [ { care_provider_id: provider.id, name: "Laboratório Sorriso" }, {}, { name: "ab" }, { name: "x" * 121 },
        { care_provider_id: SecureRandom.uuid } ].each do |laboratory|
        create_order(laboratory: laboratory)
        expect([ response.status, json_body["path"] ]).to eq([ 422, "laboratory" ])
      end
      provider.update!(active: false)
      create_order(laboratory: { care_provider_id: provider.id })
      expect([ response.status, json_body["path"] ]).to eq([ 422, "laboratory" ])
    end

    it "paciente diferente da consulta: 422 patient_id; consulta inexistente: 404" do
      create_order(patient_id: SecureRandom.uuid)
      expect([ response.status, json_body["path"] ]).to eq([ 422, "patient_id" ])
      create_order(consultation_id: SecureRandom.uuid)
      expect(response).to have_http_status(:not_found)
    end

    it "interruptor desligado: 403 feature_disabled" do
      sign_in_as(dentist)
      Platform::Features.set!(city: city, key: "dental_care", enabled: false, maintainer: ledi_maintainer!)
      json_post "/dental/prosthesis_orders", { patient_id: patient_id, consultation_id: moulding.id, sigtap: sigtap, laboratory: lab }
      expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])
    end
  end

  describe "POST /dental/prosthesis_orders/:id/stages" do
    let!(:order) { order! }

    it "sent → received: 200 com o pedido, sem created_at nem reason; evento só com ids e etapa" do
      json_post "/dental/prosthesis_orders/#{order.id}/stages", stage: "sent"
      expect(response).to have_http_status(:ok)
      json_post "/dental/prosthesis_orders/#{order.id}/stages", stage: "received"
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => order.id, "stage" => "received")
      expect(json_body["stages"].map { |s| s["stage"] }).to eq(%w[impression sent received])
      expect(json_body).not_to have_key("created_at")
      expect(json_body["stages"].flat_map(&:keys).uniq).to match_array(%w[stage at by])
      expect(events("prosthesis_order.stage_changed")).to eq([ { "order_id" => order.id, "stage" => "sent", "user_id" => dentist.id },
                                                              { "order_id" => order.id, "stage" => "received", "user_id" => dentist.id } ])
    end

    it "fora de ordem: 409 invalid_transition" do
      json_post "/dental/prosthesis_orders/#{order.id}/stages", stage: "received"
      expect([ response.status, json_body["error"] ]).to eq([ 409, "invalid_transition" ])
      expect(order.reload.stage).to eq("impression")
    end

    it "installed por aqui: 422 installation_through_consultation; etapa desconhecida: 422 stage" do
      advance!(order, "sent", "received")
      json_post "/dental/prosthesis_orders/#{order.id}/stages", stage: "installed"
      expect([ response.status, json_body["error"] ]).to eq([ 422, "installation_through_consultation" ])
      json_post "/dental/prosthesis_orders/#{order.id}/stages", stage: "flying"
      expect([ response.status, json_body["path"] ]).to eq([ 422, "stage" ])
    end

    it "cancelar exige motivo de 10 a 500; com motivo cancela e o motivo fica cifrado, fora da resposta" do
      [ nil, "", "curto", "x" * 501 ].each do |reason|
        json_post "/dental/prosthesis_orders/#{order.id}/stages", { stage: "cancelled", reason: reason }
        expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "reason_required", "reason" ])
      end
      json_post "/dental/prosthesis_orders/#{order.id}/stages", stage: "cancelled", reason: "Paciente desistiu do tratamento"
      expect(response).to have_http_status(:ok)
      expect(json_body["stage"]).to eq("cancelled")
      expect(response.body).not_to include("desistiu")
      expect(DentalProsthesisStage.where(dental_prosthesis_order_id: order.id, stage: "cancelled").first.reason).to eq("Paciente desistiu do tratamento")
      expect(DentalProsthesisStage.connection.select_value("SELECT reason FROM dental_prosthesis_stages WHERE stage = 'cancelled'")).not_to include("desistiu")
    end

    it "cancelar pedido instalado ou cancelado: 409" do
      json_post "/dental/prosthesis_orders/#{order.id}/stages", stage: "cancelled", reason: "Paciente desistiu do tratamento"
      json_post "/dental/prosthesis_orders/#{order.id}/stages", stage: "cancelled", reason: "Paciente desistiu do tratamento"
      expect(response).to have_http_status(:conflict)
      advance!(other = order!, "sent", "received")
      _, result = install_attempt(other)
      expect(result).to be_ok
      sign_in_as(dentist)
      json_post "/dental/prosthesis_orders/#{other.id}/stages", stage: "cancelled", reason: "Paciente desistiu do tratamento"
      expect([ response.status, json_body["error"] ]).to eq([ 409, "invalid_transition" ])
    end

    it "quem não tem vínculo odontológico na unidade: 403; ASB da unidade e municipal_admin: 200; pedido inexistente: 404" do
      sign_in_as(dentist!(create_unit("UBS Norte")))
      json_post "/dental/prosthesis_orders/#{order.id}/stages", stage: "sent"
      expect(response).to have_http_status(:forbidden)
      sign_in_as(reception!)
      json_post "/dental/prosthesis_orders/#{order.id}/stages", stage: "sent"
      expect(response).to have_http_status(:forbidden)
      sign_in_as(auxiliary!(unit))
      json_post "/dental/prosthesis_orders/#{order.id}/stages", stage: "sent"
      expect(response).to have_http_status(:ok)
      sign_in_as(dental_admin!)
      json_post "/dental/prosthesis_orders/#{order.id}/stages", stage: "received"
      expect(response).to have_http_status(:ok)
      json_post "/dental/prosthesis_orders/#{SecureRandom.uuid}/stages", stage: "sent"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "instalação na finalização" do
    let!(:order) { order! }

    it "pedido received: a consulta instala; o pedido fica installed com a consulta e a etapa installed" do
      advance!(order, "sent", "received")
      consultation, result = install_attempt(order)
      expect(result).to be_ok
      order.reload
      expect([ order.stage, order.installed_in_consultation_id ]).to eq([ "installed", consultation.id ])
      expect(order.stages.order(:created_at, :id).map(&:stage)).to eq(%w[impression sent received installed])
      expect(order.stages.find_by(stage: "installed").by_user_id).to eq(dentist.id)
      expect(DentalProcedure.find_by!(consultation_id: consultation.id).dental_prosthesis_order_id).to eq(order.id)
    end

    it "pedido em outra etapa: prosthesis_order_not_received, nada gravado" do
      advance!(order, "sent")
      consultation, result = install_attempt(order)
      expect(result.reason).to eq(:prosthesis_order_not_received)
      expect(result.details[:problems]).to include({ path: "dental.procedures[0].prosthesis_order_id", error: "prosthesis_order_not_received" })
      expect(order.reload.stage).to eq("sent")
      expect(consultation.reload).to be_draft
    end

    it "SIGTAP diferente do pedido: prosthesis_order_mismatch" do
      advance!(order, "sent", "received")
      _, result = install_attempt(order, code: "0701070099", location: { "kind" => "arch", "arch" => "lower" })
      expect(result.reason).to eq(:prosthesis_order_mismatch)
      expect(result.details[:problems]).to include({ path: "dental.procedures[0].prosthesis_order_id", error: "prosthesis_order_mismatch" })
      expect(order.reload.stage).to eq("received")
    end

    it "dois procedimentos com o mesmo pedido: o segundo é recusado, o pedido instala uma vez só" do
      advance!(order, "sent", "received")
      proc_for = ->(tooth) { { "sigtap" => sigtap, "location" => { "kind" => "tooth", "tooth" => tooth }, "prosthesis_order_id" => order.id } }
      consultation = dental_consultation!(unit: unit, by: dentist, citizen: citizen)
      Consultations::SaveDraft.call(consultation: consultation, params: dental_body(dental: { "procedures" => [ proc_for.(21), proc_for.(22) ] }), by: dentist)
      result = Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: dentist)
      expect(result.reason).to eq(:prosthesis_order_mismatch)
      expect(order.reload.stage).to eq("received")
    end
  end

  describe "GET /dental/prosthesis_orders" do
    it "sem health_unit_id nem patient_id: 422 invalid_request em health_unit_id" do
      sign_in_as(dentist)
      get "/dental/prosthesis_orders"
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "health_unit_id" ])
    end

    it "por unidade: nominal, mais novos primeiro, filtro de etapa, next_before e uma trilha por paciente mostrado" do
      first = order!
      second = order!
      advance!(second, "sent")
      sign_in_as(dentist)
      viewed.delete_all
      get "/dental/prosthesis_orders", params: { health_unit_id: unit.id, limit: 1 }
      expect(response).to have_http_status(:ok)
      expect(json_body["orders"].map { |o| o["id"] }).to eq([ second.id ])
      cursor = json_body["next_before"]
      expect(cursor).to be_a(String)
      get "/dental/prosthesis_orders", params: { health_unit_id: unit.id, limit: 1, before: cursor }
      expect(json_body["orders"].map { |o| o["id"] }).to eq([ first.id ])
      expect(json_body["next_before"]).to be_nil
      get "/dental/prosthesis_orders", params: { health_unit_id: unit.id, stage: "sent" }
      expect(json_body["orders"].map { |o| o["id"] }).to eq([ second.id ])
      expect(json_body["orders"].first["patient"]).to include("id" => patient_id, "display_name" => "Mariana")
      expect(viewed.count).to eq(3)
      expect(viewed.last.payload).to include("patient_id" => patient_id, "user_id" => dentist.id, "access_scope" => "dental")
      expect(viewed.last.payload.to_s).not_to match(/Sorriso|0701070145|impression/)
    end

    it "por unidade sem vínculo odontológico nela: 403; cursor, etapa, limite e id inválidos: 422" do
      sign_in_as(dentist!(create_unit("UBS Norte")))
      get "/dental/prosthesis_orders", params: { health_unit_id: unit.id }
      expect(response).to have_http_status(:forbidden)
      sign_in_as(dentist)
      { { health_unit_id: unit.id, before: "xx" } => "before", { health_unit_id: unit.id, stage: "flying" } => "stage",
        { health_unit_id: unit.id, limit: 0 } => "limit", { health_unit_id: "x" } => "health_unit_id" }.each do |params, path|
        get "/dental/prosthesis_orders", params: params
        expect([ response.status, json_body["path"] ]).to eq([ 422, path ])
      end
    end

    it "por paciente: acesso do prontuário (em contexto), com trilha; fora de contexto: 403; sem vínculo: 403" do
      order!
      sign_in_as(dentist)
      get "/dental/prosthesis_orders", params: { patient_id: patient_id }
      expect([ response.status, json_body["error"] ]).to eq([ 403, "out_of_context" ])
      consulting_attendance!(unit, citizen: citizen.reload, doctor: dentist)
      viewed.delete_all
      get "/dental/prosthesis_orders", params: { patient_id: patient_id }
      expect(response).to have_http_status(:ok)
      expect(json_body["orders"].size).to eq(1)
      expect(viewed.last.payload).to include("patient_id" => patient_id, "access" => "in_context", "access_scope" => "dental")
      sign_in_as(reception!)
      get "/dental/prosthesis_orders", params: { patient_id: patient_id }
      expect(response).to have_http_status(:forbidden)
      sign_in_as(dentist)
      get "/dental/prosthesis_orders", params: { patient_id: SecureRandom.uuid }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /dental/laboratories" do
    it "prestadores ativos do 26a, por nome, para quem tem vínculo odontológico; outros: 403" do
      b = external_provider!(name: "Beta Prótese")
      a = own_provider!(unit, name: "Alfa Rede")
      external_provider!(name: "Inativo").update!(active: false)
      sign_in_as(auxiliary!(unit))
      get "/dental/laboratories"
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("laboratories" => [ { "id" => a.id, "name" => "Alfa Rede" }, { "id" => b.id, "name" => "Beta Prótese" } ])
      sign_in_as(reception!)
      get "/dental/laboratories"
      expect(response).to have_http_status(:forbidden)
    end
  end
end

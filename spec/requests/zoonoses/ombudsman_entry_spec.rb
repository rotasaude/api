require "rails_helper"

# Módulo 35b, Task 9 (ADR 0054; contrato §4; Q6, Q10, Q13–Q15): a entrada das
# demandas de zoonoses pelos três canais do 33 (wpda identificada ou
# preservada, denúncia anônima e balcão da equipe). As chaves novas
# `zoonoses_subtype` e `place_address` só valem com o zoonoses E a ouvidoria
# utilizáveis (Q10); com subtipo, `kind` só request ou report (Q14) e o
# `place_address` é obrigatório nos três modos (Q15). O cidadão nunca vê de
# volta o `place_address`; a equipe da ouvidoria o vê no detalhe do 33, para
# reencaminhar a manifestação que ficou in_analysis (Q33), mas o ponto de
# resposta (o inbox do respondente) e a lista da caixa não. O
# encaminhamento manual do 33 à UVZ, com o gate, também cria a demanda.
RSpec.describe "Zoonoses — demandas pela ouvidoria", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:phone) { "+5541998765432" }
  let(:text) { "Morcego caído no chão da sala de aula, ainda vivo e se mexendo." }
  let(:address) { "Escola Municipal Rio Branco, Rua XV, 300" }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    travel_to Time.zone.local(2026, 11, 23, 9, 0)
  end
  after { travel_back }

  def zoonoses_ombudsman!
    zoonoses_city!
    ombudsman_city!(anonymous: true)
  end

  def web_post(**over)
    citizen = Citizen.find_by(phone: phone) || web_citizen!(phone: phone)
    json_post "/citizen/ombudsman/manifestations",
              { citizen_id: citizen.id, kind: "request", identification_mode: "identified", body: text, zoonoses_subtype: "bat",
                place_address: address }.merge(over)
  end

  def anon_post(**over)
    json_post "/citizen/ombudsman/anonymous_reports", { body: text, zoonoses_subtype: "bat", place_address: address }.merge(over)
  end

  def staff_post(**over)
    json_post "/ombudsman/manifestations", { kind: "report", identification_mode: "anonymous", channel: "phone", body: text,
                                             zoonoses_subtype: "bat", place_address: address }.merge(over)
  end

  def refused!(path, status: :unprocessable_content)
    expect(response).to have_http_status(status)
    expect(json_body).to include("error" => "invalid_request", "path" => path)
  end

  it "wpda com zoonoses desligado e subtipo → 422 path zoonoses_subtype; com zoonoses ligado e ouvidoria desligada → 403 feature_disabled do 33" do
    city = ombudsman_city!(anonymous: true)
    sign_in_citizen(phone)
    web_post
    refused!("zoonoses_subtype")
    anon_post
    refused!("zoonoses_subtype")
    expect(OmbudsmanManifestation.count).to eq(0)

    zoonoses_city!
    Platform::Features.set!(city: city, key: Ombudsman::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    web_post
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "ombudsman")
    expect(OmbudsmanManifestation.count).to eq(0)
  end

  it "identificada ou anônima sem place_address → 422 path place_address (Q15); place_address sem subtipo e subtipo fora da lista também" do
    zoonoses_ombudsman!
    uvz_unit!
    zoonoses_team!
    sign_in_citizen(phone)

    web_post(place_address: nil)
    refused!("place_address")
    web_post(place_address: "curto")
    refused!("place_address")
    web_post(place_address: "R" * 301)
    refused!("place_address")
    anon_post(place_address: nil)
    refused!("place_address")
    web_post(zoonoses_subtype: nil, kind: "complaint")
    refused!("place_address")
    web_post(zoonoses_subtype: "snake")
    refused!("zoonoses_subtype")
    expect(OmbudsmanManifestation.count).to eq(0)

    sign_in_as(ombudsman_staff!)
    staff_post(place_address: nil)
    refused!("place_address")
    expect(OmbudsmanManifestation.count).to eq(0)
  end

  it "complaint com subtipo → 422 path kind; no balcão também (e a anônima do balcão só report)" do
    zoonoses_ombudsman!
    sign_in_citizen(phone)
    web_post(kind: "complaint")
    refused!("kind")
    web_post(kind: "praise", identification_mode: "preserved")
    refused!("kind")

    sign_in_as(ombudsman_staff!)
    staff_post(kind: "complaint", identification_mode: "identified", manifestant_name: "Joana Ribeiro")
    refused!("kind")
    staff_post(kind: "request")
    refused!("kind")
    expect(OmbudsmanManifestation.count).to eq(0)
  end

  it "balcão com subtipo → encaminhado à UVZ com a demanda; o detalhe da equipe traz o place_address, a lista e o inbox não (Q33)" do
    zoonoses_ombudsman!
    uvz = uvz_unit!
    zoonoses_team!
    technician = ombudsman_staff!
    sign_in_as(technician)
    staff_post(kind: "request", identification_mode: "identified", manifestant_name: "Joana Ribeiro", channel: "in_person")
    expect(response).to have_http_status(:created)
    m = OmbudsmanManifestation.find(json_body["id"])
    expect(m).to have_attributes(state: "forwarded", channel: "in_person", created_by_user_id: technician.id, place_address: address)
    forwarding = OmbudsmanForwarding.where(ombudsman_manifestation_id: m.id).sole
    expect(forwarding).to have_attributes(health_unit_id: uvz.id, extract: text, created_by_system: true)
    expect(ZoonosesDemand.find_by!(ombudsman_forwarding_id: forwarding.id)).to have_attributes(subtype: "bat", state: "open")
    expect(m.events.order(:created_at, :id).map { |e| [ e.kind, e.actor, e.actor_user_id ] })
      .to eq([ [ "received", "staff", technician.id ], [ "classified", "system", nil ], [ "forwarded", "system", nil ] ])

    get "/ombudsman/manifestations/#{m.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("place_address" => address, "state" => "forwarded")
    expect(json_body["subject"]).to include("name" => "Morcego")
    expect(json_body["events"].map { |e| [ e["kind"], e["actor"], e["actor_name"] ] })
      .to include([ "classified", "system", nil ], [ "forwarded", "system", nil ])

    staff_post(kind: "report", channel: "phone")
    expect(response).to have_http_status(:created)
    expect(OmbudsmanManifestation.find(json_body["id"])).to have_attributes(state: "forwarded", identification_mode: "anonymous")
    expect(ZoonosesDemand.count).to eq(2)

    # A lista da caixa não traz.
    get "/ombudsman/manifestations"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(address)
    expect(json_body["items"].flat_map(&:keys)).not_to include("place_address")

    # Sem subtipo, o detalhe da manifestação comum traz place_address nulo.
    plain = raw_manifestation!
    get "/ombudsman/manifestations/#{plain.id}"
    expect(json_body["place_address"]).to be_nil

    # O ponto de resposta do 33 (o respondente da UVZ, sem ombudsman_staff):
    # o inbox não traz, e o detalhe da manifestação é 403.
    uvz_responder = responder!(uvz)
    sign_in_as(uvz_responder)
    get "/ombudsman/inbox"
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].map { |item| item["id"] }).to include(forwarding.id)
    expect(json_body["items"].flat_map(&:keys)).not_to include("place_address")
    expect(response.body).not_to include(address)
    get "/ombudsman/manifestations/#{m.id}"
    expect(response).to have_http_status(:forbidden)
  end

  it "wpda identificada e anônima com subtipo → 201 e encaminhadas" do
    zoonoses_ombudsman!
    uvz_unit!
    zoonoses_team!
    sign_in_citizen(phone)
    web_post
    expect(response).to have_http_status(:created)
    expect(json_body.keys).to match_array(%w[id protocol due_on])
    expect(OmbudsmanManifestation.find(json_body["id"]).state).to eq("forwarded")

    anon_post
    expect(response).to have_http_status(:created)
    expect(json_body).to eq("ok" => true)
    anonymous = OmbudsmanManifestation.find_by!(identification_mode: "anonymous")
    expect(anonymous).to have_attributes(kind: "report", state: "forwarded", place_address: address)
    expect(ZoonosesDemand.count).to eq(2)
  end

  it "public_config traz zoonoses true só com as duas utilizáveis" do
    city = ombudsman_city!(anonymous: true)
    get "/citizen/ombudsman/public_config"
    expect(response).to have_http_status(:ok)
    expect(json_body["zoonoses"]).to be(false)

    zoonoses_city!
    get "/citizen/ombudsman/public_config"
    expect(json_body["zoonoses"]).to be(true)

    Platform::Features.set!(city: city, key: Zoonoses::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    get "/citizen/ombudsman/public_config"
    expect(json_body["zoonoses"]).to be(false)

    Platform::Features.set!(city: city, key: Zoonoses::Gate::KEY, enabled: true, maintainer: ledi_maintainer!)
    Platform::Features.set!(city: city, key: Ombudsman::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    get "/citizen/ombudsman/public_config"
    expect(response).to have_http_status(:forbidden)
  end

  it "Minhas manifestações não traz place_address (nem na lista nem no detalhe)" do
    zoonoses_ombudsman!
    uvz_unit!
    zoonoses_team!
    sign_in_citizen(phone)
    web_post
    id = json_body.fetch("id")

    get "/citizen/ombudsman/manifestations"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(address)
    expect(json_body["manifestations"].sole.keys).not_to include("place_address")
    get "/citizen/ombudsman/manifestations/#{id}"
    expect(response).to have_http_status(:ok)
    expect(json_body["state"]).to eq("in_analysis")
    expect(response.body).not_to include(address)
    expect(json_body.keys).not_to include("place_address")
  end

  describe "encaminhamento manual do 33 à UVZ" do
    let(:extract) { "Cidadão relata ratos no terreno baldio ao lado da unidade." }

    def forward!(m, unit) = json_post("/ombudsman/manifestations/#{m.id}/forward",
                                      expected_state: "in_analysis", health_unit_id: unit.id, extract: extract)

    it "com o gate e a equipe, cria a demanda other; a UVZ conta como destino com respondente nas opções" do
      zoonoses_ombudsman!
      uvz = uvz_unit!
      zoonoses_team!
      sign_in_as(ombudsman_staff!)
      Ombudsman::Subjects.ensure_zoonoses! # sob demanda (Q14): o registro com subtipo ou a lista de assuntos

      get "/ombudsman/options"
      expect(json_body["health_units"].find { |u| u["id"] == uvz.id }).to include("has_active_responder" => true)
      zoonoses = json_body["subjects"].find { |s| s["code"] == "zoonoses" }
      expect(zoonoses).to be_present
      expect(zoonoses["children"].map { |c| c["code"] }).to eq(Zoonoses::Catalog::SUBTYPES.map { |s| "zoonoses.#{s}" })
      expect(json_body["subjects"].find { |s| s["name"] == "Atendimento" }).to include("code" => nil)

      m = raw_manifestation!(state: "in_analysis", subject: subject_leaf!)
      forward!(m, uvz)
      expect(response).to have_http_status(:ok)
      forwarding = OmbudsmanForwarding.where(ombudsman_manifestation_id: m.id).sole
      expect(forwarding).to have_attributes(created_by_system: false, extract: extract)
      demand = ZoonosesDemand.find_by!(ombudsman_forwarding_id: forwarding.id)
      expect(demand).to have_attributes(subtype: "other", state: "open")
      expect(DomainEvent.where(name: "zoonoses_demand.opened").sole.payload).to eq("zoonoses_demand_id" => demand.id)
      expect(m.events.find_by!(kind: "forwarded").actor).to eq("staff")

      # O subtipo vem do code do assunto reservado.
      tick = Ombudsman::Subjects.ensure_zoonoses![:children].fetch("tick")
      other = raw_manifestation!(state: "in_analysis", subject: tick)
      forward!(other, uvz)
      expect(response).to have_http_status(:ok)
      expect(ZoonosesDemand.joins(:ombudsman_forwarding)
                           .find_by!(ombudsman_forwardings: { ombudsman_manifestation_id: other.id }).subtype).to eq("tick")
    end

    # Q34: um segundo encaminhamento à mesma unidade com outro pending → 409
    # forwarding_already_pending (path destination); respondido ou recusado
    # o primeiro, o novo passa e cria outra demanda.
    it "segundo encaminhamento à UVZ com outro pending → 409 forwarding_already_pending; respondido o primeiro, aceito com nova demanda" do
      zoonoses_ombudsman!
      uvz = uvz_unit!
      zoonoses_team!
      uvz_responder = responder!(uvz)
      sign_in_as(ombudsman_staff!)
      m = raw_manifestation!(state: "in_analysis", subject: subject_leaf!)
      forward!(m, uvz)
      expect(response).to have_http_status(:ok)

      json_post("/ombudsman/manifestations/#{m.id}/forward", expected_state: "forwarded", health_unit_id: uvz.id, extract: extract)
      expect(response).to have_http_status(:conflict)
      expect(json_body).to include("error" => "forwarding_already_pending", "path" => "destination")
      expect(OmbudsmanForwarding.where(ombudsman_manifestation_id: m.id).count).to eq(1)
      expect(ZoonosesDemand.count).to eq(1)

      first = OmbudsmanForwarding.where(ombudsman_manifestation_id: m.id).sole
      replied = Ombudsman::ReplyForwarding.call(forwarding_id: first.id, expected_state: "pending",
                                                body: "Vistoria feita e terreno notificado para limpeza.", by: uvz_responder)
      expect(replied).to be_ok
      expect(m.reload.state).to eq("in_analysis")
      forward!(m, uvz)
      expect(response).to have_http_status(:ok)
      expect(OmbudsmanForwarding.where(ombudsman_manifestation_id: m.id).count).to eq(2)
      expect(ZoonosesDemand.count).to eq(2)
    end

    it "sem o gate, a UVZ sem respondente do 33 → 422 destination_without_responder e nenhuma demanda" do
      ombudsman_city!
      uvz = uvz_unit!
      zoonoses_team!
      sign_in_as(ombudsman_staff!)
      m = raw_manifestation!(state: "in_analysis", subject: subject_leaf!)
      forward!(m, uvz)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]).to eq("destination_without_responder")

      responder!(uvz)
      forward!(m, uvz)
      expect(response).to have_http_status(:ok)
      expect(ZoonosesDemand.count).to eq(0)
    end
  end
end

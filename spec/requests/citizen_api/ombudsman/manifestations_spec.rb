require "rails_helper"

# Módulo 33, Task 8 (ADR 0051; contrato §3; §16 U1, Q2, Q4, Q8, Q19, Q40, Q42,
# Q43, Q45, Q46): a manifestação pelo canal do cidadão — criar (com citizen_id
# da sessão ou com o par declarado { cpf, full_name }), listar e detalhar. O
# cidadão nunca vê o encaminhamento, o extrato, o assunto, o nome de quem
# respondeu nem o nome do arquivo (os anexos são "Anexo N").
RSpec.describe "Ouvidoria — manifestações pelo canal do cidadão", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { ombudsman_city! }
  let!(:citizen) { web_citizen!(cpf: "52998224725", phone: "+5541998765432") }
  let(:text) { "Esperei quatro horas na recepção da UBS sem atendimento." }

  before { travel_to Time.zone.local(2026, 11, 11, 10, 0) }
  after { travel_back }

  def memory_cache! = allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

  def create_manifestation(**over)
    json_post "/citizen/ombudsman/manifestations",
              { citizen_id: citizen.id, kind: "complaint", identification_mode: "identified", body: text }.merge(over)
  end

  def upload(filename: "anexo-1.png")
    json_post "/citizen/ombudsman/attachments", filename: filename, content_type: "image/png", data: png_base64
    json_body.fetch("id")
  end

  describe "POST /citizen/ombudsman/manifestations" do
    before { sign_in_citizen("+5541998765432") }

    it "identificada com anexo: protocolo, prazo de 30 dias e linha do tempo com 'recebida'" do
      attachment_id = upload
      expect { create_manifestation(attachment_ids: [ attachment_id ]) }
        .to change { DomainEvent.where(name: "ombudsman.manifestation_received").count }.by(1)
      expect(response).to have_http_status(:created)
      expect(json_body.keys).to match_array(%w[id protocol due_on])
      expect(json_body["protocol"]).to match(/\A2026-\d{6}\z/)
      expect(json_body["due_on"]).to eq((Time.zone.today + 30).iso8601)

      manifestation = OmbudsmanManifestation.find(json_body["id"])
      expect(manifestation).to have_attributes(citizen_id: citizen.id, channel: "web", kind: "complaint", identification_mode: "identified",
                                               state: "received", cycle: 1, cycle_started_on: Time.zone.today, body: text,
                                               created_by_user_id: nil, manifestant_name: nil, received_at: Time.current)
      expect(OmbudsmanAttachment.find(attachment_id)).to have_attributes(ombudsman_manifestation_id: manifestation.id, event_id: nil)
      expect(OmbudsmanAttachment.find(attachment_id).exam_file.consumed_at).to be_present
      expect(manifestation.events.map { |e| [ e.kind, e.actor, e.actor_user_id, e.visible_to_citizen ] })
        .to eq([ [ "received", "citizen", nil, true ] ])
      expect(OmbudsmanNotice.count).to eq(0)
      expect(DomainEvent.where(name: "ombudsman.manifestation_received").sole.payload)
        .to eq("manifestation_id" => manifestation.id)

      get "/citizen/ombudsman/manifestations/#{manifestation.id}"
      expect(response).to have_http_status(:ok)
      expect(json_body["timeline"]).to eq([ { "kind" => "received", "at" => Time.current.iso8601 } ])
      expect(json_body["attachments"]).to eq([ { "id" => attachment_id } ])
    end

    it "preservada, com a unidade ativa: a unidade vai ao detalhe" do
      unit = create_unit("UBS Ouvidoria")
      create_manifestation(identification_mode: "preserved", kind: "suggestion", health_unit_id: unit.id)
      expect(response).to have_http_status(:created)
      expect(OmbudsmanManifestation.find(json_body["id"])).to have_attributes(identification_mode: "preserved",
                                                                               referred_health_unit_id: unit.id)
    end

    it "anônimo pela sessão é recusado; cidadão de outro telefone → 403 not_own_citizen" do
      create_manifestation(kind: "report", identification_mode: "anonymous")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "identification_mode")

      other = web_citizen!(cpf: "11144477735", phone: "+5541911112222")
      create_manifestation(citizen_id: other.id, kind: "praise")
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "not_own_citizen")

      create_manifestation(citizen_id: SecureRandom.uuid)
      expect(json_body).to eq("error" => "not_own_citizen")
      create_manifestation(citizen_id: "não-é-uuid")
      expect(json_body).to eq("error" => "not_own_citizen")
      expect(OmbudsmanManifestation.count).to eq(0)
    end

    it "chave desconhecida, tipo, corpo e unidade inválidos → 422 com o path; nada gravado" do
      create_manifestation(subject_id: SecureRandom.uuid)
      expect(json_body).to include("error" => "invalid_request", "path" => "subject_id")
      create_manifestation(kind: "elogio")
      expect(json_body).to include("error" => "invalid_request", "path" => "kind")
      create_manifestation(body: "  #{'x' * 19}  ")
      expect(json_body).to include("error" => "invalid_request", "path" => "body")
      create_manifestation(health_unit_id: SecureRandom.uuid)
      expect(json_body).to include("error" => "invalid_request", "path" => "health_unit_id")
      create_manifestation(attachment_ids: [ SecureRandom.uuid ])
      expect(json_body).to include("error" => "invalid_request", "path" => "attachment_ids")
      expect(response).to have_http_status(:unprocessable_content)
      expect(OmbudsmanManifestation.count).to eq(0)
      expect(DomainEvent.where(name: "ombudsman.manifestation_received").count).to eq(0)
    end

    it "query na URL → 422 com o path; formulário → 415; sem sessão → 401; sem o interruptor → 403" do
      post "/citizen/ombudsman/manifestations?body=x", params: { citizen_id: citizen.id }.to_json,
                                                       headers: { "CONTENT_TYPE" => "application/json" }
      expect(json_body).to include("error" => "invalid_request", "path" => "body")
      post "/citizen/ombudsman/manifestations", params: { citizen_id: citizen.id }
      expect(response).to have_http_status(:unsupported_media_type)

      Platform::Features.set!(city: city, key: Ombudsman::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      create_manifestation
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("feature_disabled")

      CitizenSession.find_each(&:revoke!)
      create_manifestation
      expect(response).to have_http_status(:unauthorized)
      expect(OmbudsmanManifestation.count).to eq(0)
    end

    it "o 11º registro do dia → 429 too_many_requests; o limite é da sessão" do
      memory_cache!
      10.times do
        create_manifestation
        expect(response).to have_http_status(:created)
      end
      create_manifestation
      expect(response).to have_http_status(:too_many_requests)
      expect(json_body).to eq("error" => "too_many_requests")
      expect(OmbudsmanManifestation.count).to eq(10)

      other = web_citizen!(cpf: "11144477735", phone: "+5541911112222")
      sign_in_citizen(other.phone)
      create_manifestation(citizen_id: other.id)
      expect(response).to have_http_status(:created)
    end

    it "o texto, o CPF, o nome declarado e o nome do arquivo não vão ao log" do
      log = capture_log do
        upload(filename: "arquivo-sigiloso.png")
        create_manifestation(identification_mode: "preserved", body: "Texto sigiloso de teste com mais de vinte")
        sign_in_citizen("+5541977776666")
        json_post "/citizen/ombudsman/manifestations", cpf: "111.444.777-35", full_name: "Maria Declarada Sigilosa",
                                                       kind: "complaint", identification_mode: "identified", body: text
      end
      expect(response).to have_http_status(:created)
      # Controle positivo: a captura viu as requisições e o filtro agiu.
      expect(log).to include("CitizenApi::Ombudsman::ManifestationsController#create")
      expect(log).to include("CitizenApi::Ombudsman::AttachmentsController#create")
      expect(log).to include("[FILTERED]")
      expect(log).not_to include("sigiloso")
      expect(log).not_to include("Sigilosa")
      expect(log).not_to include("111.444.777-35")
      expect(log).not_to include("11144477735")
      expect(log).not_to include("Esperei quatro horas")
    end
  end

  describe "par declarado { cpf, full_name } (U1/Q46)" do
    let(:phone) { "+5541977776666" }

    before { sign_in_citizen(phone) }

    def declared(**over)
      json_post "/citizen/ombudsman/manifestations",
                { cpf: "111.444.777-35", full_name: "  Maria Declarada  ", kind: "complaint", identification_mode: "identified",
                  body: text }.merge(over)
    end

    it "cria o par sem consentimento, guarda o nome na manifestação e a lista o mostra" do
      expect { declared }.to change(Citizen, :count).by(1)
      expect(response).to have_http_status(:created)
      pair = Citizen.find_by!(cpf: "11144477735", phone: phone)
      expect(pair).to have_attributes(full_name: nil, verification_level: "declared", profile_source: nil)
      expect(Consent.count).to eq(0)
      expect(Conversation.where(citizen_id: pair.id)).to be_empty
      manifestation = OmbudsmanManifestation.find(json_body["id"])
      expect(manifestation).to have_attributes(citizen_id: pair.id, manifestant_name: "Maria Declarada")

      get "/citizen/ombudsman/manifestations"
      expect(json_body["manifestations"].map { |m| m["id"] }).to eq([ manifestation.id ])

      expect { declared(cpf: "11144477735", full_name: "Maria D.") }.not_to change(Citizen, :count)
      expect(response).to have_http_status(:created)
      expect(OmbudsmanManifestation.find(json_body["id"])).to have_attributes(citizen_id: pair.id, manifestant_name: "Maria D.")
    end

    # U1/Q39 (carry T20): nenhum fluxo supõe termo para todo Citizen — o termo
    # mora na conversa, não no cidadão. O par sem termo convive com as rotas da
    # sessão, e a triagem continua exigindo o termo vigente (e o perfil) na
    # própria entrada.
    it "o par sem termo: /citizen/people o lista sem perfil e os avisos abrem; a conversa ainda exige o termo vigente e o perfil" do
      declared
      expect(response).to have_http_status(:created)
      pair = Citizen.find_by!(cpf: "11144477735", phone: phone)

      get "/citizen/people"
      expect(response).to have_http_status(:ok)
      expect(json_body["people"].sole).to include("id" => pair.id, "profile" => nil)
      get "/citizen/notices"
      expect(response).to have_http_status(:ok)

      json_post "/citizen/conversations", citizen_id: pair.id, protocol_name: StartTriage::DEFAULT_PROTOCOL_NAME
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "consent_outdated")
      json_post "/citizen/conversations", citizen_id: pair.id, consent_version: Consents.current_version,
                                          protocol_name: StartTriage::DEFAULT_PROTOCOL_NAME
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "profile_required")
      expect(Consent.count).to eq(0)
      expect(Conversation.where(citizen_id: pair.id)).to be_empty
    end

    it "CPF inválido → 422 invalid_cpf; o 11º CPF no telefone → 422 too_many_people; nada gravado" do
      declared(cpf: "111.111.111-11")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_cpf", "path" => "cpf")
      declared(cpf: 11_144_477_735)
      expect(json_body).to include("error" => "invalid_cpf", "path" => "cpf")

      10.times { web_citizen!(phone: phone) }
      expect { declared }.not_to change(Citizen, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]).to eq("too_many_people")
      expect(OmbudsmanManifestation.count).to eq(0)
    end

    it "as formas da identificação: as duas → path cpf; nenhuma → path citizen_id; full_name sem cpf ou fora de 2..120 → path full_name" do
      own = web_citizen!(phone: phone)
      declared(citizen_id: own.id)
      expect(json_body).to include("error" => "invalid_request", "path" => "cpf")
      # As duas formas ao mesmo tempo é erro de forma, antes da posse (override T8.1):
      # o citizen_id de outro telefone com cpf também é 422 path cpf, não 403.
      foreign = web_citizen!(phone: "+5541911112222")
      declared(citizen_id: foreign.id)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "cpf")
      declared(citizen_id: SecureRandom.uuid)
      expect(json_body).to include("error" => "invalid_request", "path" => "cpf")
      declared(cpf: nil, full_name: nil)
      expect(json_body).to include("error" => "invalid_request", "path" => "citizen_id")
      declared(cpf: nil)
      expect(json_body).to include("error" => "invalid_request", "path" => "full_name")
      declared(cpf: nil, full_name: nil, citizen_id: own.id, full_name_extra: nil)
      expect(json_body).to include("error" => "invalid_request", "path" => "full_name_extra")
      declared(full_name: nil)
      expect(json_body).to include("error" => "invalid_request", "path" => "full_name")
      declared(full_name: " M ")
      expect(json_body).to include("error" => "invalid_request", "path" => "full_name")
      declared(full_name: "M" * 121)
      expect(json_body).to include("error" => "invalid_request", "path" => "full_name")
      expect(response).to have_http_status(:unprocessable_content)
      expect(OmbudsmanManifestation.count).to eq(0)
      expect(Citizen.where(phone: phone).count).to eq(1)
    end
  end

  describe "GET /citizen/ombudsman/manifestations" do
    it "traz os cidadãos da sessão, mais novo primeiro, com cpf_masked quando há mais de um; nada do anônimo nem de outro telefone" do
      sibling = web_citizen!(phone: citizen.phone)
      older = manifestation!(citizen: citizen, received_at: 2.days.ago)
      newer = manifestation!(citizen: sibling, received_at: 1.day.ago, kind: "praise", identification_mode: "preserved")
      ::Ombudsman::Register.call(attrs: { "kind" => "report", "identification_mode" => "anonymous", "body" => text },
                                 channel: "web", anonymous_web: true)
      manifestation!(citizen: web_citizen!(phone: "+5541911112222"))
      sign_in_citizen(citizen.phone)

      get "/citizen/ombudsman/manifestations"
      expect(response).to have_http_status(:ok)
      items = json_body["manifestations"]
      expect(items.map { |m| m["id"] }).to eq([ newer.id, older.id ])
      expect(items.first.keys).to match_array(%w[id protocol kind identification_mode state received_at due_on color cpf_masked has_unread])
      expect(items.first).to include("protocol" => newer.protocol, "kind" => "praise", "identification_mode" => "preserved",
                                     "state" => "received", "received_at" => newer.received_at.iso8601, "color" => "green",
                                     "due_on" => (newer.cycle_started_on + 30).iso8601, "cpf_masked" => sibling.cpf_masked,
                                     "has_unread" => false)
      expect(items.last["cpf_masked"]).to eq(citizen.cpf_masked)
    end

    it "com um só cidadão, cpf_masked é nulo; forwarded aparece como in_analysis; o aviso não lido acende has_unread" do
      forwarded = manifestation!(citizen: citizen, state: "forwarded", received_at: 1.day.ago)
      answered = manifestation!(citizen: citizen, state: "answered", concluded_at: 1.hour.ago, resolution: "resolved")
      ::Ombudsman::Notify.call(manifestation: answered, kind: "final_response")
      sign_in_citizen(citizen.phone)

      get "/citizen/ombudsman/manifestations"
      by_id = json_body["manifestations"].index_by { |m| m["id"] }
      expect(by_id[forwarded.id]).to include("state" => "in_analysis", "cpf_masked" => nil, "has_unread" => false)
      expect(by_id[answered.id]).to include("state" => "answered", "color" => nil, "has_unread" => true)
    end

    it "query na URL → 422 com o path" do
      sign_in_citizen(citizen.phone)
      get "/citizen/ombudsman/manifestations?cpf=52998224725"
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "cpf")
    end
  end

  describe "GET /citizen/ombudsman/manifestations/:id" do
    let(:unit) { create_unit("UBS Ouvidoria") }
    let(:staff) { ombudsman_staff! }

    def event!(manifestation, kind, visible:, text: nil, data: {}, actor: "staff", at: Time.current)
      OmbudsmanEvent.create!(ombudsman_manifestation: manifestation, kind: kind, actor: actor,
                             actor_user: (staff if actor == "staff"), text: text, data: data, visible_to_citizen: visible, created_at: at)
    end

    it "o formato do §3 com cor; a linha do tempo só com o visível e o texto pronto; nada da equipe" do
      manifestation = manifestation!(citizen: citizen, referred_health_unit: unit, received_at: 3.days.ago)
      first = raw_attachment!(manifestation: manifestation, filename: "anexo-1.png")
      # Sob travel_to os dois nasceriam no mesmo instante e a ordem (created_at,
      # id) cairia no uuid: um segundo entre eles fixa "Anexo 1", "Anexo 2".
      travel 1.second
      second = raw_attachment!(manifestation: manifestation, filename: "anexo-2.png")
      event!(manifestation, "received", visible: true, actor: "citizen", at: 3.days.ago)
      event!(manifestation, "classified", visible: false, data: { "subject_id" => SecureRandom.uuid }, at: 2.days.ago)
      event!(manifestation, "forwarded", visible: false, text: "Extrato interno da equipe", at: 2.days.ago + 1.minute)
      event!(manifestation, "forwarding_replied", visible: false, text: "Resposta do setor", at: 2.days.ago + 2.minutes)
      event!(manifestation, "complement_requested", visible: true, text: "Qual foi o dia?", at: 2.days.ago + 3.minutes)
      event!(manifestation, "complement_received", visible: true, actor: "citizen", text: "Foi na terça.", at: 2.days.ago + 4.minutes)
      event!(manifestation, "extended", visible: true, text: "Precisamos ouvir a unidade.", at: 1.day.ago)
      event!(manifestation, "interim_response", visible: true, text: "Estamos apurando.", at: 1.day.ago + 1.minute)
      sign_in_citizen(citizen.phone)

      get "/citizen/ombudsman/manifestations/#{manifestation.id}"
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to match_array(%w[id protocol kind identification_mode state received_at due_on color body health_unit
                                               attachments timeline can_complement can_request_reopen can_answer_satisfaction])
      expect(json_body).to include("id" => manifestation.id, "protocol" => manifestation.protocol, "kind" => "complaint",
                                   "identification_mode" => "identified", "state" => "received", "body" => OmbudsmanHelpers::BODY,
                                   "received_at" => manifestation.received_at.iso8601, "color" => "green",
                                   "due_on" => (manifestation.cycle_started_on + 30).iso8601,
                                   "health_unit" => { "id" => unit.id, "name" => unit.name },
                                   "can_complement" => false, "can_request_reopen" => false, "can_answer_satisfaction" => false)
      expect(json_body["attachments"]).to eq([ { "id" => first.id }, { "id" => second.id } ])
      expect(json_body["timeline"]).to eq([
        { "kind" => "received", "at" => 3.days.ago.iso8601 },
        { "kind" => "complement_requested", "at" => (2.days.ago + 3.minutes).iso8601, "text" => "Qual foi o dia?" },
        { "kind" => "complement_received", "at" => (2.days.ago + 4.minutes).iso8601 },
        { "kind" => "extended", "at" => 1.day.ago.iso8601, "text" => "Precisamos ouvir a unidade." },
        { "kind" => "interim_response", "at" => (1.day.ago + 1.minute).iso8601, "text" => "Estamos apurando." }
      ])
      expect(response.body).not_to include("Extrato interno", "Resposta do setor", "anexo-1", "actor", staff.email_address)
    end

    it "arquivada: o motivo em palavras do cidadão; recusa da reabertura com o texto; cor nula" do
      manifestation = manifestation!(citizen: citizen, state: "archived", archive_reason: "lack_of_clarity", concluded_at: 1.day.ago)
      event!(manifestation, "archived", visible: true, data: { "reason" => "lack_of_clarity" }, at: 1.day.ago)
      event!(manifestation, "reopen_requested", visible: true, actor: "citizen", at: 1.hour.ago)
      event!(manifestation, "reopen_rejected", visible: true, text: "Sem fato novo.", at: 30.minutes.ago)
      sign_in_citizen(citizen.phone)

      get "/citizen/ombudsman/manifestations/#{manifestation.id}"
      expect(json_body).to include("state" => "archived", "color" => nil)
      expect(json_body["timeline"].map { |e| [ e["kind"], e["text"] ] }).to eq([
        [ "archived", "Faltaram informações para entender o pedido." ], [ "reopen_requested", nil ], [ "reopen_rejected", "Sem fato novo." ]
      ])
    end

    it "forwarded aparece como in_analysis; awaiting_complement tem cor paused e pode complementar" do
      forwarded = manifestation!(citizen: citizen, state: "forwarded")
      waiting = manifestation!(citizen: citizen, state: "awaiting_complement", complement_requested_at: 2.days.ago, complement_used: true)
      sign_in_citizen(citizen.phone)

      get "/citizen/ombudsman/manifestations/#{forwarded.id}"
      expect(json_body).to include("state" => "in_analysis", "color" => "green", "can_complement" => false)
      get "/citizen/ombudsman/manifestations/#{waiting.id}"
      expect(json_body).to include("state" => "awaiting_complement", "color" => "paused", "can_complement" => true,
                                   "due_on" => (waiting.cycle_started_on + 32).iso8601)
    end

    it "can_request_reopen e can_answer_satisfaction até 30 dias da conclusão, uma vez" do
      fresh = manifestation!(citizen: citizen, state: "answered", resolution: "resolved", concluded_at: 30.days.ago)
      old = manifestation!(citizen: citizen, state: "answered", resolution: "resolved", concluded_at: 31.days.ago)
      used = manifestation!(citizen: citizen, state: "answered", resolution: "resolved", concluded_at: 2.days.ago)
      OmbudsmanReopenRequest.create!(ombudsman_manifestation: used, cycle: 1, reason: "Não resolveram nada.", state: "rejected",
                                     decision_text: "Sem fato novo.", decided_by_user: ombudsman!, decided_at: 1.day.ago)
      OmbudsmanSatisfactionResponse.create!(ombudsman_manifestation: used, met: "no", clear: true, score: 2)
      archived = manifestation!(citizen: citizen, state: "archived", archive_reason: "improper", concluded_at: 1.day.ago)
      sign_in_citizen(citizen.phone)

      flags = lambda do |m|
        get "/citizen/ombudsman/manifestations/#{m.id}"
        json_body.values_at("can_request_reopen", "can_answer_satisfaction")
      end
      expect(flags.call(fresh)).to eq([ true, true ])
      expect(flags.call(old)).to eq([ false, false ])
      expect(flags.call(used)).to eq([ false, false ])
      expect(flags.call(archived)).to eq([ true, false ])
    end

    it "marca como lidos os avisos daquela manifestação: has_unread e unread_count caem; os de outra ficam" do
      seen = manifestation!(citizen: citizen, state: "answered", resolution: "resolved", concluded_at: 1.hour.ago)
      other = manifestation!(citizen: citizen, state: "awaiting_complement", complement_requested_at: 1.hour.ago, complement_used: true)
      ::Ombudsman::Notify.call(manifestation: seen, kind: "interim_response")
      ::Ombudsman::Notify.call(manifestation: seen, kind: "final_response")
      ::Ombudsman::Notify.call(manifestation: other, kind: "complement_requested")
      sign_in_citizen(citizen.phone)

      get "/citizen/notices"
      expect(json_body["unread_count"]).to eq(3)
      get "/citizen/ombudsman/manifestations/#{seen.id}"
      expect(response).to have_http_status(:ok)
      expect(OmbudsmanNotice.where(ombudsman_manifestation_id: seen.id).pluck(:read_at)).to all(eq(Time.current))
      expect(OmbudsmanNotice.where(ombudsman_manifestation_id: other.id).pluck(:read_at)).to eq([ nil ])

      get "/citizen/ombudsman/manifestations"
      expect(json_body["manifestations"].to_h { |m| [ m["id"], m["has_unread"] ] }).to eq(seen.id => false, other.id => true)
      get "/citizen/notices"
      expect(json_body["unread_count"]).to eq(1)
    end

    it "de outro telefone, anônima, inexistente ou id que não é uuid → 404; query → 422" do
      foreign = manifestation!(citizen: web_citizen!(phone: "+5541911112222"))
      anonymous = manifestation!(citizen: nil, kind: "report", identification_mode: "anonymous")
      ::Ombudsman::Notify.call(manifestation: foreign, kind: "final_response")
      sign_in_citizen(citizen.phone)

      [ foreign.id, anonymous.id, SecureRandom.uuid, "nao-e-uuid" ].each do |id|
        get "/citizen/ombudsman/manifestations/#{id}"
        expect(response).to have_http_status(:not_found), "esperava 404 para #{id}"
        expect(json_body).to eq("error" => "not_found")
      end
      expect(OmbudsmanNotice.sole.read_at).to be_nil

      own = manifestation!(citizen: citizen)
      get "/citizen/ombudsman/manifestations/#{own.id}?citizen_id=#{citizen.id}"
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "citizen_id")
    end
  end
end

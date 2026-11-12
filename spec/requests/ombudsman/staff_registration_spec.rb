require "rails_helper"

# Módulo 33, Task 10 (ADR 0051; contrato §5; §16 Q6, Q22, Q43): registro pela
# equipe (presencial, telefone, OuvidorSUS), a busca do cidadão pelo CPF e o
# comprovante. A busca devolve o cidadão (nunca nada de manifestação).
RSpec.describe "Ouvidoria — registro pela equipe", type: :request do
  let!(:city) { ombudsman_city! }
  let(:technician) { ombudsman_staff! }
  let(:text) { "O paciente relatou demora de quatro horas na recepção da UBS." }
  let(:cpf) { ombudsman_cpf! }

  def memory_cache! = allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

  def capture_log
    log = StringIO.new
    capture = ActiveSupport::Logger.new(log).tap { |l| l.level = Logger::DEBUG }
    Rails.logger.broadcast_to(capture)
    yield
    log.string
  ensure
    Rails.logger.stop_broadcasting_to(capture)
  end

  def formatted(digits) = "#{digits[0, 3]}.#{digits[3, 3]}.#{digits[6, 3]}-#{digits[9, 2]}"

  def register(**over)
    json_post "/ombudsman/manifestations", { kind: "complaint", identification_mode: "identified", channel: "in_person", body: text }.merge(over)
  end

  describe "POST /ombudsman/person_lookup" do
    it "acha o cidadão pelo CPF: { citizen_id, name, cpf_masked }, sem criar paciente nem exigir par validado" do
      citizen = web_citizen!(cpf: cpf)
      citizen.update!(full_name: "Maria da Silva")
      sign_in_as(technician)
      patients = Patient.count
      json_post "/ombudsman/person_lookup", cpf: formatted(cpf)
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("citizen_id" => citizen.id, "name" => "Maria da Silva", "cpf_masked" => citizen.cpf_masked)
      expect(Patient.count).to eq(patients)
    end

    it "par nunca conferido → name nulo; ninguém → null" do
      citizen = web_citizen!(cpf: cpf)
      sign_in_as(technician)
      json_post "/ombudsman/person_lookup", cpf: cpf
      expect(json_body).to eq("citizen_id" => citizen.id, "name" => nil, "cpf_masked" => citizen.cpf_masked)

      json_post "/ombudsman/person_lookup", cpf: ombudsman_cpf!
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("null")
    end

    it "vários pares do mesmo CPF: o verificado primeiro; entre iguais, o mais antigo" do
      old = web_citizen!(cpf: cpf, phone: "+5541990000001")
      Citizen.where(id: old.id).update_all(created_at: 3.days.ago)
      newer = web_citizen!(cpf: cpf, phone: "+5541990000002")
      Citizen.where(id: newer.id).update_all(created_at: 2.days.ago)
      sign_in_as(technician)
      json_post "/ombudsman/person_lookup", cpf: cpf
      expect(json_body["citizen_id"]).to eq(old.id)

      newest = web_citizen!(cpf: cpf, phone: "+5541990000003")
      Citizen.where(id: newest.id).update_all(verification_level: "verified", created_at: 1.day.ago)
      json_post "/ombudsman/person_lookup", cpf: cpf
      expect(json_body["citizen_id"]).to eq(newest.id)
    end

    it "ignora o cadastro excluído (lápide)" do
      citizen = web_citizen!(cpf: cpf)
      Citizen.where(id: citizen.id).update_all(erased_at: Time.current)
      sign_in_as(technician)
      json_post "/ombudsman/person_lookup", cpf: cpf
      expect(response.body).to eq("null")
    end

    it "CPF malformado → 422 invalid_cpf path cpf; chave fora de cpf → 422; CPF na query → 422; sem cpf → 422" do
      sign_in_as(technician)
      json_post "/ombudsman/person_lookup", cpf: "123"
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_cpf", "path" => "cpf")
      json_post "/ombudsman/person_lookup", cpf: 12_345_678_909
      expect(json_body).to include("error" => "invalid_cpf", "path" => "cpf")
      json_post "/ombudsman/person_lookup", {}
      expect(json_body).to include("error" => "invalid_cpf", "path" => "cpf")
      json_post "/ombudsman/person_lookup", cpf: cpf, name: "x"
      expect(json_body).to include("error" => "invalid_request", "path" => "name")
      post "/ombudsman/person_lookup?cpf=#{cpf}", params: { cpf: cpf }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
      expect(json_body).to include("error" => "invalid_request", "path" => "cpf")
    end

    it "a 31ª busca no minuto → 429 too_many_requests; é por usuário" do
      memory_cache!
      sign_in_as(technician)
      30.times { json_post "/ombudsman/person_lookup", cpf: cpf }
      expect(response).to have_http_status(:ok)
      json_post "/ombudsman/person_lookup", cpf: cpf
      expect(response).to have_http_status(:too_many_requests)
      expect(json_body).to eq("error" => "too_many_requests")

      sign_in_as(ombudsman!)
      json_post "/ombudsman/person_lookup", cpf: cpf
      expect(response).to have_http_status(:ok)
    end

    it "o CPF não vai ao log" do
      web_citizen!(cpf: cpf)
      sign_in_as(technician)
      log = capture_log { json_post "/ombudsman/person_lookup", cpf: cpf }
      expect(log).not_to include(cpf)
    end

    it "depois do registro preservado, a busca devolve só o cidadão (nada da manifestação)" do
      citizen = web_citizen!(cpf: cpf)
      sign_in_as(technician)
      register(identification_mode: "preserved", citizen_id: citizen.id)
      expect(response).to have_http_status(:created)
      json_post "/ombudsman/person_lookup", cpf: cpf
      expect(json_body.keys).to eq(%w[citizen_id name cpf_masked])
      expect(response.body).not_to include(OmbudsmanManifestation.sole.protocol)
    end
  end

  describe "POST /ombudsman/manifestations" do
    it "presencial identificado com o cidadão achado pelo CPF → 201 { id, protocol, due_on }; evento da equipe e o criador" do
      citizen = web_citizen!(cpf: cpf)
      sign_in_as(technician)
      json_post "/ombudsman/person_lookup", cpf: cpf
      register(citizen_id: json_body["citizen_id"])
      expect(response).to have_http_status(:created)
      expect(json_body.keys).to match_array(%w[id protocol due_on])
      manifestation = OmbudsmanManifestation.find(json_body["id"])
      expect(manifestation).to have_attributes(channel: "in_person", citizen_id: citizen.id, identification_mode: "identified",
                                               created_by_user_id: technician.id, state: "received", ouvidorsus_number: nil,
                                               manifestant_name: nil, body: text)
      expect(json_body["due_on"]).to eq((Time.zone.today + OmbudsmanSetting.current.response_days).iso8601)
      expect(manifestation.events.sole).to have_attributes(kind: "received", actor: "staff", actor_user_id: technician.id)
      expect(DomainEvent.where(name: "ombudsman.manifestation_received").count).to eq(1)
    end

    it "por telefone sem cidadão: nome, contato e CPF cifrados" do
      sign_in_as(technician)
      register(channel: "phone", manifestant_name: "João Souza", manifestant_contact: "(41) 99999-0000", manifestant_cpf: formatted(cpf))
      expect(response).to have_http_status(:created)
      manifestation = OmbudsmanManifestation.find(json_body["id"])
      expect(manifestation).to have_attributes(channel: "phone", citizen_id: nil, manifestant_name: "João Souza",
                                               manifestant_contact: "(41) 99999-0000", manifestant_cpf: cpf)
      raw = OmbudsmanManifestation.connection.select_one("SELECT manifestant_name, manifestant_cpf FROM ombudsman_manifestations WHERE id = '#{manifestation.id}'")
      expect(raw.values.join).not_to include("João")
      expect(raw.values.join).not_to include(cpf)
    end

    it "OuvidorSUS grava o número; sem número → 422 path ouvidorsus_number; número em outro canal → 422" do
      sign_in_as(technician)
      register(channel: "ouvidorsus", ouvidorsus_number: " OUV-123 ", manifestant_name: "Ana Lima")
      expect(response).to have_http_status(:created)
      expect(OmbudsmanManifestation.find(json_body["id"]).ouvidorsus_number).to eq("OUV-123")

      count = OmbudsmanManifestation.count
      register(channel: "ouvidorsus", manifestant_name: "Ana Lima")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "ouvidorsus_number")
      register(channel: "ouvidorsus", ouvidorsus_number: "x" * 41, manifestant_name: "Ana Lima")
      expect(json_body["path"]).to eq("ouvidorsus_number")
      register(channel: "phone", ouvidorsus_number: "OUV-1", manifestant_name: "Ana Lima")
      expect(json_body["path"]).to eq("ouvidorsus_number")
      expect(OmbudsmanManifestation.count).to eq(count)
    end

    it "canal web ou desconhecido → 422 path channel" do
      sign_in_as(technician)
      register(channel: "web", manifestant_name: "Ana Lima")
      expect(json_body).to include("error" => "invalid_request", "path" => "channel")
      register(channel: "fax", manifestant_name: "Ana Lima")
      expect(json_body["path"]).to eq("channel")
      register(channel: nil, manifestant_name: "Ana Lima")
      expect(json_body["path"]).to eq("channel")
    end

    it "identificada ou preservada sem citizen_id nem nome → 422 (Q22)" do
      sign_in_as(technician)
      register
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "manifestant_name")
      register(identification_mode: "preserved", manifestant_contact: "x@y.z")
      expect(json_body["path"]).to eq("manifestant_name")
      expect(OmbudsmanManifestation.count).to eq(0)
    end

    it "citizen_id: uuid inexistente, excluído ou com manifestant_* junto → 422" do
      citizen = web_citizen!(cpf: cpf)
      erased = web_citizen!(cpf: ombudsman_cpf!)
      Citizen.where(id: erased.id).update_all(erased_at: Time.current)
      sign_in_as(technician)
      register(citizen_id: SecureRandom.uuid)
      expect(json_body).to include("error" => "invalid_request", "path" => "citizen_id")
      register(citizen_id: erased.id)
      expect(json_body["path"]).to eq("citizen_id")
      register(citizen_id: "abc")
      expect(json_body["path"]).to eq("citizen_id")
      register(citizen_id: citizen.id, manifestant_name: "Outro Nome")
      expect(json_body["path"]).to eq("manifestant_name")
      expect(OmbudsmanManifestation.count).to eq(0)
    end

    it "anônima: só denúncia e sem dado de pessoa (422 com o path do primeiro campo)" do
      sign_in_as(technician)
      register(kind: "report", identification_mode: "anonymous", manifestant_name: "Fulano")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "manifestant_name")
      register(kind: "report", identification_mode: "anonymous", citizen_id: SecureRandom.uuid)
      expect(json_body["path"]).to eq("citizen_id")
      register(kind: "report", identification_mode: "anonymous", manifestant_cpf: cpf)
      expect(json_body["path"]).to eq("manifestant_cpf")
      register(kind: "praise", identification_mode: "anonymous")
      expect(json_body["path"]).to eq("kind")
      expect(OmbudsmanManifestation.count).to eq(0)

      register(kind: "report", identification_mode: "anonymous", channel: "phone")
      expect(response).to have_http_status(:created)
      expect(OmbudsmanManifestation.find(json_body["id"])).to have_attributes(identification_mode: "anonymous", citizen_id: nil, channel: "phone")
    end

    it "CPF do manifestante inválido → 422 invalid_cpf path manifestant_cpf; texto fora de 20..4000 → path body" do
      sign_in_as(technician)
      register(manifestant_name: "Ana Lima", manifestant_cpf: "111.111.111-11")
      expect(json_body).to include("error" => "invalid_cpf", "path" => "manifestant_cpf")
      register(manifestant_name: "Ana Lima", body: "curto")
      expect(json_body).to include("error" => "invalid_request", "path" => "body")
      register(manifestant_name: " a ")
      expect(json_body["path"]).to eq("manifestant_name")
      register(manifestant_name: "Ana Lima", manifestant_contact: "x" * 121)
      expect(json_body["path"]).to eq("manifestant_contact")
    end

    it "chave desconhecida no corpo ou qualquer chave na query → 422 com o nome da chave" do
      sign_in_as(technician)
      register(manifestant_name: "Ana Lima", urgent: true)
      expect(json_body).to include("error" => "invalid_request", "path" => "urgent")
      post "/ombudsman/manifestations?body=x", params: {}.to_json, headers: { "CONTENT_TYPE" => "application/json" }
      expect(json_body).to include("error" => "invalid_request", "path" => "body")
    end

    it "anexos do usuário: liga na transação e consome o arquivo; de outro usuário → 422 e nada é gravado" do
      sign_in_as(technician)
      json_post "/ombudsman/attachments", filename: "a.png", content_type: "image/png", data: png_base64
      id = json_body["id"]
      register(manifestant_name: "Ana Lima", attachment_ids: [ id ])
      expect(response).to have_http_status(:created)
      attachment = OmbudsmanAttachment.find(id)
      expect(attachment.ombudsman_manifestation_id).to eq(json_body["id"])
      expect(attachment.exam_file.consumed_at).not_to be_nil

      other = raw_attachment!(uploaded_by: "staff")
      count = OmbudsmanManifestation.count
      register(manifestant_name: "Ana Lima", attachment_ids: [ other.id ])
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["path"]).to eq("attachment_ids")
      expect(OmbudsmanManifestation.count).to eq(count)
      expect(other.reload.ombudsman_manifestation_id).to be_nil
    end

    it "o ouvidor também registra; nome, CPF e texto não vão ao log" do
      sign_in_as(ombudsman!)
      log = capture_log { register(manifestant_name: "Zoroastro Pereira", manifestant_cpf: cpf) }
      expect(response).to have_http_status(:created)
      expect(log).not_to include("Zoroastro")
      expect(log).not_to include(cpf)
      expect(log).not_to include(text)
    end
  end

  describe "GET /ombudsman/manifestations/:id/receipt" do
    it "devolve { protocol, kind, received_at, due_on, channel }" do
      sign_in_as(technician)
      register(channel: "phone", manifestant_name: "Ana Lima")
      manifestation = OmbudsmanManifestation.find(json_body["id"])
      get "/ombudsman/manifestations/#{manifestation.id}/receipt"
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("protocol" => manifestation.protocol, "kind" => "complaint", "received_at" => manifestation.received_at.iso8601,
                              "due_on" => (Time.zone.today + OmbudsmanSetting.current.response_days).iso8601, "channel" => "phone")
    end

    it "anônima → 404; inexistente e uuid inválido → 404; query → 422" do
      sign_in_as(technician)
      register(kind: "report", identification_mode: "anonymous")
      id = json_body["id"]
      get "/ombudsman/manifestations/#{id}/receipt"
      expect(response).to have_http_status(:not_found)
      expect(json_body).to eq("error" => "not_found")
      get "/ombudsman/manifestations/#{SecureRandom.uuid}/receipt"
      expect(response).to have_http_status(:not_found)
      get "/ombudsman/manifestations/abc/receipt"
      expect(response).to have_http_status(:not_found)
      get "/ombudsman/manifestations/#{id}/receipt?x=1"
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "papéis e portão" do
    it "sem ombudsman_staff (respondente, administrador) → 403 em todas" do
      manifestation = manifestation!
      responder = responder!(department!)
      [ responder, ombudsman_admin! ].each do |user|
        sign_in_as(user)
        json_post "/ombudsman/person_lookup", cpf: cpf
        expect(response).to have_http_status(:forbidden)
        register(manifestant_name: "Ana Lima")
        expect(response).to have_http_status(:forbidden)
        get "/ombudsman/manifestations/#{manifestation.id}/receipt"
        expect(response).to have_http_status(:forbidden)
      end
      expect(OmbudsmanManifestation.count).to eq(1)
    end

    it "sem sessão → 401" do
      json_post "/ombudsman/person_lookup", cpf: cpf
      expect(response).to have_http_status(:unauthorized)
      register(manifestant_name: "Ana Lima")
      expect(response).to have_http_status(:unauthorized)
    end

    it "interruptor desligado → 403 feature_disabled" do
      Platform::Features.set!(city: city, key: Ombudsman::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      sign_in_as(technician)
      json_post "/ombudsman/person_lookup", cpf: cpf
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("feature_disabled")
    end
  end
end

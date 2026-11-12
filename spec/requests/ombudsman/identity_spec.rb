require "rails_helper"

# Módulo 33, Task 11 (ADR 0051; contrato §5, §8; §16 Q24, U4, Q32; Review
# Focus 5): a identidade preservada. Em `preserved` e `anonymous`, nenhuma
# resposta da equipe (lista, detalhe, comprovante) traz nome, CPF ou telefone,
# nem para o ouvidor, fora de POST …/identity. Cada abertura: só o ouvidor,
# com justificativa (sem step-up, U4), uma linha em
# ombudsman_identity_accesses (scope identity) e um ombudsman.identity_viewed
# só com ids; a anônima sem dado → 422 no_identity, nada gravado (A26).
RSpec.describe "Ouvidoria — identidade preservada e consentimento", type: :request do
  let!(:city) { ombudsman_city! }
  let(:technician) { ombudsman_staff! }
  let(:ouvidor) { ombudsman! }
  let(:marker) { "sigiloso-#{SecureRandom.hex(4)}" }
  let(:justification) { "Necessário para contato com o manifestante sobre o caso." }
  let(:citizen) do
    web_citizen!(phone: "+5541991234567").tap { |c| c.update!(full_name: "Joana Preservada Souza") }
  end
  let(:preserved) { raw_manifestation!(citizen: citizen, identification_mode: "preserved", state: "in_analysis") }
  let(:anonymous) { raw_manifestation!(kind: "report", identification_mode: "anonymous") }

  def capture_log
    log = StringIO.new
    capture = ActiveSupport::Logger.new(log).tap { |l| l.level = Logger::DEBUG }
    Rails.logger.broadcast_to(capture)
    yield
    log.string
  ensure
    Rails.logger.stop_broadcasting_to(capture)
  end

  def open_identity(m, params = { justification: justification }) = json_post("/ombudsman/manifestations/#{m.id}/identity", params)
  def consent(m, params) = json_post("/ombudsman/manifestations/#{m.id}/identity_consent", params)

  def secrets(c = citizen)
    [ c.cpf, c.cpf_masked, c.full_name, c.phone, CitizenIdentity::Phone.mask(c.phone), c.phone.delete_prefix("+55") ]
  end

  describe "§8: preserved não sai em nenhuma leitura da equipe" do
    it "lista, detalhe e comprovante, pelo técnico e pelo ouvidor: identity 'preserved' e nenhum nome, CPF ou telefone" do
      preserved
      staff_preserved = raw_manifestation!(channel: "phone", identification_mode: "preserved", manifestant_name: "Nome #{marker}",
                                           manifestant_contact: "contato #{marker}", manifestant_cpf: ombudsman_cpf!)
      [ technician, ouvidor ].each do |user|
        sign_in_as(user)
        get "/ombudsman/manifestations"
        expect(response).to have_http_status(:ok)
        items = json_body["items"].index_by { |item| item["id"] }
        expect(items.fetch(preserved.id)).to include("identification_mode" => "preserved")
        expect(items.fetch(staff_preserved.id)).to include("identification_mode" => "preserved")
        expect(response.body).not_to include(*secrets, marker, staff_preserved.manifestant_cpf)

        [ preserved, staff_preserved ].each do |m|
          get "/ombudsman/manifestations/#{m.id}"
          expect(response).to have_http_status(:ok)
          expect(json_body).to include("identity" => "preserved", "identity_available" => true)
          expect(response.body).not_to include(*secrets, marker, m.manifestant_cpf.to_s.presence || "sem-cpf", "*****-")

          get "/ombudsman/manifestations/#{m.id}/receipt"
          expect(response).to have_http_status(:ok)
          expect(response.body).not_to include(*secrets, marker)
        end
      end
    end

    it "identified com cidadão: { name, cpf_masked, phone_masked }; sem cidadão: com contact (Q24); anônima: 'preserved' e identity_available falso" do
      identified = raw_manifestation!(citizen: citizen)
      by_staff = raw_manifestation!(channel: "in_person", manifestant_name: "Carlos Declarado", manifestant_contact: "(41) 3333-4444",
                                    manifestant_cpf: "52998224725")
      sign_in_as(technician)
      get "/ombudsman/manifestations/#{identified.id}"
      expect(json_body).to include("identity_available" => true,
                                   "identity" => { "name" => "Joana Preservada Souza", "cpf_masked" => citizen.cpf_masked,
                                                   "phone_masked" => CitizenIdentity::Phone.mask(citizen.phone) })
      expect(response.body).not_to include(citizen.cpf, citizen.phone)

      get "/ombudsman/manifestations/#{by_staff.id}"
      expect(json_body["identity"]).to eq("name" => "Carlos Declarado", "cpf_masked" => "***.982.247-**", "phone_masked" => nil,
                                          "contact" => "(41) 3333-4444")
      expect(response.body).not_to include("52998224725")

      get "/ombudsman/manifestations/#{anonymous.id}"
      expect(json_body).to include("identity" => "preserved", "identity_available" => false)
    end
  end

  describe "POST /ombudsman/manifestations/:id/identity" do
    it "o técnico → 403 missing_role; o respondente → 403; nada gravado" do
      [ technician, responder!(department!) ].each do |user|
        sign_in_as(user)
        open_identity(preserved)
        expect(response).to have_http_status(:forbidden)
        expect(json_body).to eq("error" => "missing_role")
      end
      expect(OmbudsmanIdentityAccess.count).to eq(0)
      expect(DomainEvent.where(name: "ombudsman.identity_viewed")).to be_empty
    end

    it "o ouvidor sem justificativa válida → 422 path justification, nada gravado" do
      sign_in_as(ouvidor)
      [ {}, { justification: "curta" }, { justification: "x" * 501 }, { justification: 12 }, { justification: "         " } ].each do |body|
        open_identity(preserved, body)
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to eq("error" => "invalid_request", "path" => "justification",
                                "problems" => [ { "error" => "invalid_request", "path" => "justification" } ])
      end
      expect(OmbudsmanIdentityAccess.count).to eq(0)
      expect(DomainEvent.where(name: "ombudsman.identity_viewed")).to be_empty
    end

    it "com justificativa → a identidade completa, no-store, uma linha e um evento só com ids por abertura; nada no log (sem step-up, U4)" do
      sign_in_as(ouvidor)
      text = "Contato com #{marker} para retorno do caso."
      log = capture_log { open_identity(preserved, justification: "  #{text}  ") }
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(json_body).to eq("name" => "Joana Preservada Souza", "full_name" => "Joana Preservada Souza", "cpf" => citizen.cpf,
                              "phone" => citizen.phone, "manifestant_name" => nil, "manifestant_contact" => nil, "manifestant_cpf" => nil)
      access = OmbudsmanIdentityAccess.sole
      expect(access).to have_attributes(scope: "identity", exam_file_id: nil, user_id: ouvidor.id,
                                        ombudsman_manifestation_id: preserved.id, justification: text)
      event = DomainEvent.where(name: "ombudsman.identity_viewed").sole
      expect(event.payload).to eq("manifestation_id" => preserved.id, "access_id" => access.id)
      expect(log).not_to include(marker)
      expect(log).not_to include(*secrets)

      open_identity(preserved)
      expect(response).to have_http_status(:ok)
      expect(OmbudsmanIdentityAccess.where(ombudsman_manifestation_id: preserved.id, scope: "identity").count).to eq(2)
      expect(DomainEvent.where(name: "ombudsman.identity_viewed").count).to eq(2)
      expect(DomainEvent.pluck(:payload).to_json).not_to include(marker, citizen.cpf, citizen.full_name)

      # Abrir não muda o detalhe: segue "preserved".
      get "/ombudsman/manifestations/#{preserved.id}"
      expect(json_body["identity"]).to eq("preserved")
      expect(response.body).not_to include(*secrets)
    end

    it "registro preservado da equipe sem cidadão: name = manifestant_name e os três manifestant_* (U1)" do
      cpf = ombudsman_cpf!
      m = raw_manifestation!(channel: "phone", identification_mode: "preserved", manifestant_name: "Pedro Telefone",
                             manifestant_contact: "pedro@exemplo.com", manifestant_cpf: cpf)
      sign_in_as(ouvidor)
      open_identity(m)
      expect(json_body).to eq("name" => "Pedro Telefone", "full_name" => nil, "cpf" => nil, "phone" => nil, "manifestant_name" => "Pedro Telefone",
                              "manifestant_contact" => "pedro@exemplo.com", "manifestant_cpf" => cpf)
    end

    it "full_name é o nome civil do cidadão (Q50): com nome social, difere de name; par declarado sem nome civil, nulo" do
      social = web_citizen!(phone: "+5541992223333").tap { |c| c.update!(full_name: "Roberto Civil Lima", social_name: "Renata Lima") }
      by_social = raw_manifestation!(citizen: social, identification_mode: "preserved")
      declared = web_citizen!(phone: "+5541993334444")
      by_declared = raw_manifestation!(citizen: declared, identification_mode: "preserved", manifestant_name: "Ana Declarada")
      sign_in_as(ouvidor)

      open_identity(by_social)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("name" => "Renata Lima", "full_name" => "Roberto Civil Lima", "cpf" => social.cpf)

      open_identity(by_declared)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("name" => "Ana Declarada", "full_name" => nil, "manifestant_name" => "Ana Declarada", "cpf" => declared.cpf)
    end

    it "anônima sem dado de pessoa → 422 no_identity, sem linha nem evento (A26)" do
      sign_in_as(ouvidor)
      open_identity(anonymous)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "no_identity")
      expect(OmbudsmanIdentityAccess.count).to eq(0)
      expect(DomainEvent.where(name: "ombudsman.identity_viewed")).to be_empty
    end

    it "chave a mais no corpo ou na query → 422 com o nome; id malformado ou inexistente → 404" do
      sign_in_as(ouvidor)
      open_identity(preserved, justification: justification, cpf: "52998224725")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "cpf")
      json_post "/ombudsman/manifestations/#{preserved.id}/identity?justification=#{marker}", justification: justification
      expect(json_body).to include("error" => "invalid_request", "path" => "justification")
      expect(response.body).not_to include(marker, "52998224725")
      [ "x", SecureRandom.uuid ].each do |id|
        json_post "/ombudsman/manifestations/#{id}/identity", justification: justification
        expect(response).to have_http_status(:not_found)
        expect(json_body).to eq("error" => "not_found")
      end
      expect(OmbudsmanIdentityAccess.count).to eq(0)
    end

    it "ouvidoria desligada → 403 feature_disabled" do
      Platform::Features.set!(city: city, key: "ombudsman", enabled: false, maintainer: ledi_maintainer!)
      sign_in_as(ouvidor)
      open_identity(preserved)
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "ombudsman")
      expect(OmbudsmanIdentityAccess.count).to eq(0)
    end
  end

  describe "POST /ombudsman/manifestations/:id/identity_consent" do
    it "o ouvidor registra → 201 com o detalhe (Q32); evento interno com { granted } e o texto cifrado; nada revelado" do
      sign_in_as(ouvidor)
      text = "A manifestante autorizou por telefone #{marker}."
      log = capture_log { consent(preserved, granted: true, text: "  #{text}  ") }
      expect(response).to have_http_status(:created)
      expect(json_body).to include("id" => preserved.id, "identity" => "preserved")
      expect(response.body).not_to include(*secrets)
      event = OmbudsmanEvent.where(ombudsman_manifestation_id: preserved.id, kind: "identity_consent_recorded").sole
      expect(event).to have_attributes(actor: "staff", actor_user_id: ouvidor.id, data: { "granted" => true }, visible_to_citizen: false, text: text)
      raw = OmbudsmanEvent.connection.select_value(OmbudsmanEvent.sanitize_sql_array([ "SELECT text FROM ombudsman_events WHERE id = ?", event.id ]))
      expect(raw).not_to include(marker)
      expect(json_body["events"].map { |e| e["kind"] }).to include("identity_consent_recorded")
      expect(log).not_to include(marker)
      expect(OmbudsmanIdentityAccess.count).to eq(0)
      expect(DomainEvent.where(name: "ombudsman.identity_viewed")).to be_empty

      consent(preserved, granted: false, text: "Revogou a autorização dada antes.")
      expect(response).to have_http_status(:created)
      expect(OmbudsmanEvent.where(kind: "identity_consent_recorded").order(:created_at, :id).last.data).to eq("granted" => false)
    end

    it "o técnico → 403; granted não-booleano → 422 path granted; texto curto → 422 path text; chave a mais → 422; anônima → 422 no_identity" do
      sign_in_as(technician)
      consent(preserved, granted: true, text: "Autorizou o contato pelo setor.")
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "missing_role")

      sign_in_as(ouvidor)
      [ [ { text: "Autorizou o contato pelo setor." }, "granted" ], [ { granted: "true", text: "Autorizou o contato pelo setor." }, "granted" ],
        [ { granted: nil, text: "Autorizou o contato pelo setor." }, "granted" ], [ { granted: true, text: "curto" }, "text" ],
        [ { granted: true }, "text" ], [ { granted: true, text: "Autorizou o contato pelo setor.", cpf: "1" }, "cpf" ] ].each do |body, path|
        consent(preserved, body)
        expect(response).to have_http_status(:unprocessable_content), body.inspect
        expect(json_body).to include("error" => "invalid_request", "path" => path)
      end
      consent(anonymous, granted: true, text: "Autorizou o contato pelo setor.")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "no_identity")
      expect(OmbudsmanEvent.where(kind: "identity_consent_recorded")).to be_empty
    end
  end
end

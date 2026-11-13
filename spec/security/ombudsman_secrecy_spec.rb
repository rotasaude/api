require "rails_helper"

# Módulo 33 (ADR 0051; contrato §1, §5, §6, §8, §9, §13 e §16 U1, Q2, Q18,
# Q24, Q41, Q43, Q57; plano, Task 20): o sigilo da ouvidoria de ponta a ponta.
# Um cenário completo pelas rotas reais:
# - canal web: o par declarado (U1) registra uma manifestação identificada com
#   anexo; outro cidadão registra uma preservada com anexo;
# - pública: a denúncia anônima (com o cookie de uma sessão válida, Q41) e o
#   teto da cidade;
# - equipe: a busca pelo CPF, o registro presencial identificado e o registro
#   por telefone preservado com nome, CPF e contato digitados;
# - a preservada: classificação com assunto, unidade e profissional;
#   encaminhamento com extrato; prorrogação e resposta do ponto; pedido de
#   complemento e o complemento do cidadão; prorrogação do prazo; resposta
#   conclusiva; identidade e anexo abertos pelo ouvidor; satisfação;
# - a presencial: arquivamento e reabertura;
# - as leituras da equipe (caixa, detalhe, comprovante, inbox, painel, por
#   profissional) e do cidadão (avisos);
# - cinco recusas forçadas: texto curto, CPF malformado, chave a mais,
#   justificativa curta e o teto da cidade.
# Depois, as provas de ausência: eventos (só ids), log, recusas, respostas
# (identidade da preservada, CPF e nome do U1, nome do arquivo), aviso e SMS.
# Fora do cenário: a query de toda rota do módulo, a varredura de fonte de
# DomainEvents.publish e a de Platform.audit.
#
# Constantes do cenário num módulo próprio: dentro de um bloco do RSpec
# elas cairiam em Object e colidiriam com as de outros specs na suíte.
module OmbudsmanSecrecy
  NAMES = {
    preserved: "Valdirene Aparecida Sigilosa",  # o cidadão da preservada (canal web)
    declared: "Maria Declarada Reservada",      # o full_name do par declarado (U1)
    in_person: "Josué Conferido Presencial",    # o cidadão da presencial
    phone: "Teodora Ligação Reservada"          # o manifestant_name digitado pela equipe
  }.freeze
  PHONES = { preserved: "+5541988017391", declared: "+5541977028462", in_person: "+5541966039573" }.freeze
  CONTACT = "(41) 3029-8173 ramal 44".freeze
  FILENAMES = %w[laudo-valdirene-sigiloso.png print-maria-reservado.png].freeze
  TEXTS = {
    declared_body: "Reservado U1: a recepção da UBS recusou o meu atendimento sem explicação.",
    preserved_body: "Reservado P1: o médico da unidade gritou comigo durante a consulta de ontem.",
    anonymous_body: "Reservado A1: o vigia da unidade cobra para furar a fila do acolhimento.",
    in_person_body: "Reservado D1: a farmácia da unidade nunca tem o remédio da pressão.",
    phone_body: "Reservado E1: a ambulância demorou seis horas para buscar a minha mãe.",
    extract: "Extrato reservado: relato de conduta inadequada em consulta na unidade.",
    forwarding_extension: "Prorrogação reservada do ponto: aguardando a escala do médico.",
    reply: "Resposta reservada do setor: o profissional foi ouvido e orientado.",
    request_complement: "Pedido reservado: informe o horário aproximado da consulta.",
    complement: "Complemento reservado do cidadão: foi por volta das nove horas da manhã.",
    extension: "Prorrogação reservada do prazo: a apuração depende de outra escuta.",
    final: "Resposta conclusiva reservada: o caso foi apurado e o profissional advertido.",
    identity_justification: "Justificativa reservada: retorno pedido pela promotoria.",
    attachment_justification: "Justificativa reservada do anexo: conferência do laudo.",
    reopen: "Reabertura reservada: o cidadão trouxe fato novo ao balcão."
  }.freeze
  SHORT_BODY = "Curto reservado".freeze
  BAD_CPF = "529.982.247-00".freeze
  EXTRA_VALUE = "Nome Intruso Reservado".freeze
  SHORT_JUSTIFICATION = "Curta".freeze
  OVER_CAP_BODY = "Reservado A2: segunda denúncia do dia, acima do teto da cidade.".freeze
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  # As chaves do corpo que o "Parameters:" do log mostra como [FILTERED].
  LOGGED_KEYS = %w[body extract reason text justification full_name cpf manifestant_name manifestant_cpf manifestant_contact filename].freeze
  # §1, §13 e Q18: as únicas chaves de payload dos eventos do módulo.
  PAYLOAD_KEYS = %w[manifestation_id forwarding_id access_id outcome].freeze
  CONTRACT_EVENTS = %w[
    ombudsman.manifestation_received ombudsman.forwarded ombudsman.forwarding_replied ombudsman.concluded
    ombudsman.reopened ombudsman.identity_viewed ombudsman.anonymous_cap_reached
  ].freeze
  MODULE_GLOBS = %w[
    app/**/ombudsman/**/*.{rb,erb} app/**/*ombudsman*.{rb,erb} app/views/ombudsman_mailer/*.erb lib/ombudsman_crew.rb
    app/models/department.rb app/controllers/departments_controller.rb
  ].freeze

  def self.formatted(cpf) = "#{cpf[0, 3]}.#{cpf[3, 3]}.#{cpf[6, 3]}-#{cpf[9, 2]}"
  def self.cpf_forms(cpf) = [ cpf, formatted(cpf) ]
  def self.phone_forms(phone) = [ phone, phone.delete_prefix("+55") ]
end

RSpec.describe "Sigilo da ouvidoria (33)", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  # Método, e não let: o cenário roda no seed_once (before(:context)).
  def secrecy = OmbudsmanSecrecy

  before { SmsGateway::Test.reset! }
  after do
    SmsGateway::Test.reset!
    travel_back
  end

  def body = JSON.parse(response.body)

  # Cenário completo pelas rotas, com o log capturado, toda resposta guardada
  # (rota, corpo e cabeçalhos) e as recusas forçadas (corpo e valor enviado).
  def secrecy_scenario!
    texts = secrecy::TEXTS
    travel_to Time.zone.local(2026, 11, 11, 10, 0) # janela do SMS (8h–20h)
    city = ombudsman_city!(anonymous: true)
    OmbudsmanSetting.current.update!(anonymous_daily_cap: 1)
    (CityProfile.current || CityProfile.create!(name: "Curitiba")).update!(campaigns_sms_enabled: true)

    cpfs = { preserved: ombudsman_cpf!, declared: ombudsman_cpf!, in_person: ombudsman_cpf!, phone: ombudsman_cpf! }
    preserved_citizen = Citizen.create!(cpf: cpfs[:preserved], phone: secrecy::PHONES[:preserved], full_name: secrecy::NAMES[:preserved],
                                        verification_level: "verified")
    CitizenContactPreference.create!(citizen_id: preserved_citizen.id, sms_opt_in: true)
    in_person_citizen = Citizen.create!(cpf: cpfs[:in_person], phone: secrecy::PHONES[:in_person], full_name: secrecy::NAMES[:in_person],
                                        verification_level: "verified")
    unit = HealthUnit.create!(name: "UBS Sigilo Bairro Alto", kind: "ubs")
    department = department!("Setor Reservado de Atenção Primária")
    leaf = subject_leaf!
    doctor = staff_with("medico-sigilo-#{SecureRandom.hex(3)}@cidade.gov.br", "health_professional")
    link_professional!(doctor, unit)
    responder = responder!(department)
    tech = ombudsman_staff!
    chief = ombudsman!

    responses = []
    refusals = []
    started_at = Time.current
    send_request = lambda do |verb, path, payload|
      case verb
      when :get then get(path)
      else post(path, params: payload.to_json, headers: { "CONTENT_TYPE" => "application/json" })
      end
      # O download é binário: o texto procurado é UTF-8.
      responses << { verb: verb, path: request.path, status: response.status, raw: response.body.dup.force_encoding(Encoding::UTF_8).scrub,
                     headers: response.headers.to_h.slice("Set-Cookie", "Content-Disposition") }
    end
    req = lambda do |verb, path, payload = {}|
      send_request.(verb, path, payload)
      raise "#{verb} #{path} → #{response.status} #{response.body}" unless response.successful?

      response.body.empty? || response.media_type != "application/json" ? {} : JSON.parse(response.body)
    end
    refuse = lambda do |label, path, payload, status:, sent:|
      send_request.(:post, path, payload)
      raise "#{label}: #{path} → #{response.status} #{response.body}" unless response.status == status

      refusals << { label: label, status: response.status, raw: response.body, json: JSON.parse(response.body), sent: sent }
    end
    act = ->(m, action, payload) { req.(:post, "/ombudsman/manifestations/#{m}/#{action}", payload) }
    upload = ->(path, filename) { req.(:post, path, { filename: filename, content_type: "image/png", data: png_base64 })["id"] }

    ids = {}
    public_route = {}
    log = capture_log do
      # Canal web, par declarado (U1): o telefone ainda não tem cidadão; a
      # recusa do texto curto antes do registro identificado com anexo; a
      # lista e o detalhe do cidadão.
      sign_in_citizen(secrecy::PHONES[:declared])
      ids[:declared_attachment] = upload.("/citizen/ombudsman/attachments", secrecy::FILENAMES[1])
      declared = { cpf: secrecy.formatted(cpfs[:declared]), full_name: secrecy::NAMES[:declared], kind: "complaint",
                   identification_mode: "identified" }
      refuse.(:short_body, "/citizen/ombudsman/manifestations", declared.merge(body: secrecy::SHORT_BODY), status: 422, sent: secrecy::SHORT_BODY)
      ids[:declared] = req.(:post, "/citizen/ombudsman/manifestations",
                            declared.merge(body: texts[:declared_body], attachment_ids: [ ids[:declared_attachment] ]))["id"]
      req.(:get, "/citizen/ombudsman/manifestations")
      req.(:get, "/citizen/ombudsman/manifestations/#{ids[:declared]}")

      # Canal web, a preservada com anexo.
      citizen_session = sign_in_citizen(secrecy::PHONES[:preserved])
      ids[:preserved_attachment] = upload.("/citizen/ombudsman/attachments", secrecy::FILENAMES[0])
      ids[:preserved] = req.(:post, "/citizen/ombudsman/manifestations",
                             { citizen_id: preserved_citizen.id, kind: "complaint", identification_mode: "preserved",
                               body: texts[:preserved_body], health_unit_id: unit.id,
                               attachment_ids: [ ids[:preserved_attachment] ] })["id"]

      # Rotas públicas com o cookie de uma sessão válida (Q41): passado o
      # prazo deslizante, uma rota com sessão regravaria o cookie.
      travel 2.hours
      public_route[:session_before] = citizen_session.reload.attributes.slice("updated_at", "last_seen_at", "expires_at")
      public_route[:config] = req.(:get, "/citizen/ombudsman/public_config")
      public_route[:cookies] = [ response.headers["Set-Cookie"] ]
      req.(:post, "/citizen/ombudsman/anonymous_reports", { body: texts[:anonymous_body], health_unit_id: unit.id })
      public_route[:cookies] << response.headers["Set-Cookie"]
      refuse.(:daily_cap, "/citizen/ombudsman/anonymous_reports", { body: secrecy::OVER_CAP_BODY }, status: 429,
              sent: secrecy::OVER_CAP_BODY)
      public_route[:cookies] << response.headers["Set-Cookie"]
      public_route[:session_after] = citizen_session.reload.attributes.slice("updated_at", "last_seen_at", "expires_at")
      ids[:anonymous] = OmbudsmanManifestation.find_by!(identification_mode: "anonymous").id

      # Equipe: busca pelo CPF (a malformada antes), registro presencial
      # identificado e por telefone preservado com os dados digitados.
      sign_in_as(tech)
      refuse.(:malformed_cpf, "/ombudsman/person_lookup", { cpf: secrecy::BAD_CPF }, status: 422, sent: secrecy::BAD_CPF)
      found = req.(:post, "/ombudsman/person_lookup", { cpf: secrecy.formatted(cpfs[:in_person]) })
      ids[:preserved_lookup] = req.(:post, "/ombudsman/person_lookup", { cpf: cpfs[:preserved] })
      ids[:in_person] = req.(:post, "/ombudsman/manifestations",
                             { channel: "in_person", kind: "praise", identification_mode: "identified", citizen_id: found["citizen_id"],
                               body: texts[:in_person_body] })["id"]
      ids[:phone] = req.(:post, "/ombudsman/manifestations",
                         { channel: "phone", kind: "request", identification_mode: "preserved", manifestant_name: secrecy::NAMES[:phone],
                           manifestant_cpf: secrecy.formatted(cpfs[:phone]), manifestant_contact: secrecy::CONTACT,
                           body: texts[:phone_body] })["id"]
      req.(:get, "/ombudsman/manifestations/#{ids[:phone]}/receipt")

      # A preservada: classificação (a chave a mais antes) e encaminhamento.
      classify = { expected_state: "received", subject_id: leaf.id, health_unit_id: unit.id, professional_id: doctor.professional.id }
      refuse.(:extra_key, "/ombudsman/manifestations/#{ids[:preserved]}/classify", classify.merge(manifestant_name: secrecy::EXTRA_VALUE),
              status: 422, sent: secrecy::EXTRA_VALUE)
      act.(ids[:preserved], "classify", classify)
      ids[:forwarding] = act.(ids[:preserved], "forward",
                              { expected_state: "in_analysis", department_id: department.id, extract: texts[:extract] })
                         .fetch("forwardings").sole.fetch("id")

      # Ponto de resposta: o inbox, a prorrogação e a resposta.
      sign_in_as(responder)
      req.(:get, "/ombudsman/inbox")
      req.(:post, "/ombudsman/inbox/#{ids[:forwarding]}/extend", { expected_state: "pending", reason: texts[:forwarding_extension] })
      req.(:post, "/ombudsman/inbox/#{ids[:forwarding]}/reply", { expected_state: "pending", body: texts[:reply] })
      req.(:get, "/ombudsman/inbox")

      # Complemento: o pedido da equipe e o envio do cidadão.
      sign_in_as(tech)
      act.(ids[:preserved], "request_complement", { expected_state: "in_analysis", text: texts[:request_complement] })
      req.(:post, "/citizen/ombudsman/manifestations/#{ids[:preserved]}/complement", { body: texts[:complement] })

      # Ouvidor: prorrogação do prazo; técnico: a conclusiva.
      sign_in_as(chief)
      act.(ids[:preserved], "extend", { expected_state: "in_analysis", text: texts[:extension] })
      sign_in_as(tech)
      act.(ids[:preserved], "final_response", { expected_state: "in_analysis", text: texts[:final], resolution: "resolved" })

      # Ouvidor: a identidade (a justificativa curta antes) e o anexo da
      # preservada; a presencial arquivada e reaberta.
      sign_in_as(chief)
      identity_path = "/ombudsman/manifestations/#{ids[:preserved]}/identity"
      refuse.(:short_justification, identity_path, { justification: secrecy::SHORT_JUSTIFICATION }, status: 422,
              sent: secrecy::SHORT_JUSTIFICATION)
      ids[:identity] = req.(:post, identity_path, { justification: texts[:identity_justification] })
      link = req.(:post, "/ombudsman/attachments/#{ids[:preserved_attachment]}/link", { justification: texts[:attachment_justification] })
      ids[:token] = link.fetch("url").delete_prefix("/ombudsman/files/")
      req.(:get, link.fetch("url"))
      act.(ids[:in_person], "archive", { expected_state: "received", reason: "lack_of_clarity" })
      act.(ids[:in_person], "reopen", { expected_state: "archived", text: texts[:reopen] })

      # O cidadão: a satisfação, os avisos, a lista e o detalhe.
      sign_in_citizen(secrecy::PHONES[:preserved])
      req.(:post, "/citizen/ombudsman/manifestations/#{ids[:preserved]}/satisfaction", { met: "yes", clear: true, score: 5 })
      ids[:notices] = req.(:get, "/citizen/notices")
      req.(:get, "/citizen/ombudsman/manifestations")
      req.(:get, "/citizen/ombudsman/manifestations/#{ids[:preserved]}")

      # As leituras da equipe: caixa, detalhes, comprovante, painel e por profissional.
      sign_in_as(tech)
      req.(:get, "/ombudsman/manifestations")
      ids.values_at(:declared, :preserved, :anonymous, :in_person, :phone).each { |id| req.(:get, "/ombudsman/manifestations/#{id}") }
      req.(:get, "/ombudsman/manifestations/#{ids[:preserved]}/receipt")
      req.(:get, "/ombudsman/dashboard")
      sign_in_as(chief)
      req.(:get, "/ombudsman/manifestations/#{ids[:preserved]}")
      req.(:get, "/ombudsman/dashboard/professionals")
    end

    { city: city, cpfs: cpfs, ids: ids, unit: unit, department: department, leaf: leaf, doctor: doctor, log: log,
      responses: responses, refusals: refusals, public_route: public_route, started_at: started_at,
      preserved: OmbudsmanManifestation.find(ids[:preserved]) }
  end

  describe "cenário" do
    # O cenário roda uma vez por arquivo (api#159); cada exemplo parte do
    # estado que ele deixou e abre a sua própria sessão de requisição. O
    # before(type: :request) do harness não roda aqui: o host vem à mão. O
    # cenário termina com o relógio parado na hora dele, e cada exemplo volta
    # para essa hora; os SMS (em memória, zerados a cada exemplo) ficam no
    # cenário.
    seed_once do
      SmsGateway::Test.reset!
      use_test_city_host!
      @scenario = secrecy_scenario!.merge(sms: SmsGateway::Test.deliveries.dup)
      @scenario_now = Time.current
    ensure
      travel_back
      SmsGateway::Test.reset!
    end
    let(:scenario) { @scenario }
    before { travel_to(@scenario_now) }
    let(:ids) { scenario[:ids] }
    let(:cpfs) { scenario[:cpfs] }
    let(:texts) { secrecy::TEXTS.values + [ secrecy::SHORT_BODY, secrecy::OVER_CAP_BODY ] }
    let(:names) { secrecy::NAMES.values }
    let(:cpf_forms) { cpfs.values.flat_map { |cpf| secrecy.cpf_forms(cpf) } }
    let(:phone_forms) { secrecy::PHONES.values.flat_map { |phone| secrecy.phone_forms(phone) } }
    let(:people) { names + cpf_forms + phone_forms + [ secrecy::CONTACT ] }
    # O que é da identidade preservada: a do cidadão do canal web e a digitada pela equipe.
    let(:preserved_identity) do
      [ secrecy::NAMES[:preserved], *secrecy.cpf_forms(cpfs[:preserved]), CitizenIdentity::Cpf.mask(cpfs[:preserved]),
        *secrecy.phone_forms(secrecy::PHONES[:preserved]), CitizenIdentity::Phone.mask(secrecy::PHONES[:preserved]),
        secrecy::NAMES[:phone], *secrecy.cpf_forms(cpfs[:phone]), CitizenIdentity::Cpf.mask(cpfs[:phone]), secrecy::CONTACT ]
    end
    let(:responses) { scenario[:responses] }
    let(:staff_reads) { responses.select { |r| r[:path].start_with?("/ombudsman/") } }
    let(:identity_path) { "/ombudsman/manifestations/#{ids[:preserved]}/identity" }

    it "percorreu o cenário inteiro (controle positivo)" do
      manifestations = OmbudsmanManifestation.where(id: ids.values_at(:declared, :preserved, :anonymous, :in_person, :phone)).index_by(&:id)
      expect(manifestations.size).to eq(5)
      expect(manifestations[ids[:declared]]).to have_attributes(identification_mode: "identified", channel: "web",
                                                                manifestant_name: secrecy::NAMES[:declared])
      expect(Citizen.find(manifestations[ids[:declared]].citizen_id)).to have_attributes(full_name: nil, cpf: cpfs[:declared])
      expect(manifestations[ids[:preserved]]).to have_attributes(identification_mode: "preserved", state: "answered", extended: true,
                                                                 complement_used: true, subject_id: scenario[:leaf].id,
                                                                 referred_health_unit_id: scenario[:unit].id,
                                                                 referred_professional_id: scenario[:doctor].professional.id)
      expect(manifestations[ids[:anonymous]]).to have_attributes(citizen_id: nil, kind: "report")
      expect(manifestations[ids[:in_person]]).to have_attributes(channel: "in_person", state: "in_analysis", cycle: 2)
      expect(manifestations[ids[:phone]]).to have_attributes(channel: "phone", identification_mode: "preserved", citizen_id: nil,
                                                             manifestant_cpf: cpfs[:phone], manifestant_contact: secrecy::CONTACT)
      expect(OmbudsmanForwarding.find(ids[:forwarding])).to have_attributes(state: "replied", extended: true)
      expect(OmbudsmanAttachment.where(id: ids.values_at(:declared_attachment, :preserved_attachment)).pluck(:filename))
        .to match_array(secrecy::FILENAMES)
      expect(OmbudsmanSatisfactionResponse.where(ombudsman_manifestation_id: ids[:preserved]).count).to eq(1)
      expect(OmbudsmanIdentityAccess.where(ombudsman_manifestation_id: ids[:preserved]).pluck(:scope)).to contain_exactly("identity", "attachment")
      expect(scenario[:refusals].map { |r| r[:label] }).to eq(%i[short_body daily_cap malformed_cpf extra_key short_justification])
      expect(ids[:identity]).to include("name" => secrecy::NAMES[:preserved], "cpf" => cpfs[:preserved])
      download = responses.find { |r| r[:path].start_with?("/ombudsman/files/") }
      expect(download[:status]).to eq(200)
    end

    # §1, §13, Q18, Q21: os eventos do módulo são só os sete do contrato, e o
    # payload só leva os ids do domínio e o `outcome`.
    it "os ombudsman.* publicados ⊂ DOMAIN_EVENTS (os sete do contrato), cada payload só com ids e outcome" do
      expect(Ombudsman::Catalog::DOMAIN_EVENTS).to eq(secrecy::CONTRACT_EVENTS)
      events = DomainEvent.where(occurred_at: scenario[:started_at]..).select { |e| e.name.start_with?("ombudsman.") }
      expect(events.map(&:name).uniq - Ombudsman::Catalog::DOMAIN_EVENTS).to be_empty
      expect(events.map(&:name).uniq).to match_array(secrecy::CONTRACT_EVENTS) # controle: o cenário publicou os sete
      expect(events.select { |e| e.name == "ombudsman.anonymous_cap_reached" }.map(&:payload)).to eq([ {} ])

      forbidden_ids = [ scenario[:leaf].id, scenario[:leaf].parent_id, scenario[:unit].id, scenario[:department].id,
                        scenario[:doctor].professional.id, scenario[:doctor].id ]
      events.each do |event|
        expect(event.payload.keys - secrecy::PAYLOAD_KEYS).to be_empty, "#{event.name} publica #{event.payload.keys}"
        event.payload.each do |key, value|
          if key == "outcome"
            expect(value).to be_in(%w[answered archived]), "#{event.name}.outcome"
          else
            expect(value.to_s).to match(secrecy::UUID), "#{event.name}.#{key}"
            expect(forbidden_ids).not_to include(value), "#{event.name}.#{key} é id de assunto, unidade ou profissional"
          end
        end
      end
      expect(events.select { |e| e.name == "ombudsman.concluded" }.map { |e| e.payload["outcome"] }).to contain_exactly("answered", "archived")

      payloads = DomainEvent.where(occurred_at: scenario[:started_at]..).pluck(:name, :payload).to_json
      subject_names = [ scenario[:leaf].name, scenario[:leaf].parent&.name ].compact
      (texts + people + secrecy::FILENAMES + subject_names + [ scenario[:unit].name, scenario[:department].name, ids[:token] ])
        .each { |secret| expect(payloads).not_to include(secret), "evento contém #{secret.inspect}" }
    end

    it "o log do cenário não tem texto, extrato, resposta, justificativa, nome, CPF, telefone, contato, nome do arquivo nem o token do link" do
      log = scenario[:log]
      # Controle: a captura viu as requisições e o filtro agiu.
      expect(log).to include("/citizen/ombudsman/manifestations", "/ombudsman/inbox", "/ombudsman/files/[FILTERED]", "[FILTERED]")
      (texts + people + secrecy::FILENAMES + [ ids[:token] ]).each { |secret| expect(log).not_to include(secret), "log contém #{secret.inspect}" }
      logged = log.scan(/"(#{secrecy::LOGGED_KEYS.join('|')})"\s*=>\s*([^,}]+)/)
      expect(logged.map(&:first).uniq)
        .to include("body", "extract", "reason", "text", "justification", "full_name", "cpf", "manifestant_name", "filename")
      expect(logged.map(&:last)).to all(include("[FILTERED]"))
    end

    it "toda recusa 4xx forçada traz só error, path e problems, sem o valor enviado" do
      expected = { short_body: %w[invalid_request body], daily_cap: [ "daily_cap_reached", nil ], malformed_cpf: %w[invalid_cpf cpf],
                   extra_key: %w[invalid_request manifestant_name], short_justification: %w[invalid_request justification] }
      scenario[:refusals].each do |refusal|
        json = refusal[:json]
        expect(json.keys - %w[error path problems]).to be_empty, "#{refusal[:label]}: #{json.keys}"
        expect(json.values_at("error", "path")).to eq(expected.fetch(refusal[:label])), "#{refusal[:label]}: #{json}"
        Array(json["problems"]).each { |problem| expect(problem.keys - %w[path error]).to be_empty }
        expect(refusal[:raw]).not_to include(refusal[:sent])
        (texts + people).each { |secret| expect(refusal[:raw]).not_to include(secret), "#{refusal[:label]} contém #{secret.inspect}" }
      end
      expect(scenario[:refusals].find { |r| r[:label] == :daily_cap }[:status]).to eq(429) # Q43: o teto da cidade
    end

    # Review focus 5 (§5, §6, §8; Q24): fora do POST …/identity, nenhuma
    # resposta da equipe traz a identidade da preservada — nem o nome, nem o
    # CPF (cru ou mascarado), nem o telefone (cru ou mascarado), nem o contato.
    # A busca pelo CPF devolve só o cidadão do CPF digitado: nada da manifestação.
    it "na preservada, nenhuma leitura da equipe (caixa, detalhe, comprovante, inbox, painel, por profissional) traz a identidade" do
      lookups = staff_reads.select { |r| r[:path] == "/ombudsman/person_lookup" && r[:status] == 200 }
      reads = staff_reads - lookups - staff_reads.select { |r| r[:path] == identity_path }
      read_paths = reads.map { |r| r[:path] }
      expect(read_paths).to include("/ombudsman/manifestations", "/ombudsman/manifestations/#{ids[:preserved]}",
                                    "/ombudsman/manifestations/#{ids[:preserved]}/receipt", "/ombudsman/manifestations/#{ids[:phone]}/receipt",
                                    "/ombudsman/inbox", "/ombudsman/dashboard", "/ombudsman/dashboard/professionals")
      reads.each do |read|
        preserved_identity.each do |secret|
          expect(read[:raw]).not_to include(secret), "#{read[:verb]} #{read[:path]} contém #{secret.inspect}"
        end
      end

      details = reads.select { |r| r[:path].in?([ "/ombudsman/manifestations/#{ids[:preserved]}", "/ombudsman/manifestations/#{ids[:phone]}" ]) }
      expect(details.size).to eq(3)
      details.each { |d| expect(JSON.parse(d[:raw])).to include("identity" => "preserved", "identity_available" => true) }

      # A busca pelo CPF do cidadão da preservada: só o cidadão, nada da manifestação.
      expect(ids[:preserved_lookup].keys).to contain_exactly("citizen_id", "name", "cpf_masked")
      lookups.each do |lookup|
        expect(lookup[:raw]).not_to include(ids[:preserved], scenario[:preserved].protocol, ids[:phone], secrecy::TEXTS[:preserved_body])
        expect(lookup[:raw]).not_to include(cpfs[:preserved], cpfs[:in_person])
      end
    end

    it "o inbox e as ações do respondente nunca trazem o protocolo, o texto, o assunto, a identidade nem os anexos" do
      inbox = staff_reads.select { |r| r[:path].start_with?("/ombudsman/inbox") }
      expect(inbox.size).to eq(4)
      items = inbox.flat_map { |r| json = JSON.parse(r[:raw]); json["items"] || [ json ] }
      expect(items.map { |i| i["id"] }.uniq).to eq([ ids[:forwarding] ])
      items.each do |item|
        expect(item.keys - %w[id destination extract due_on color state created_at extended reply]).to be_empty
      end
      manifestation = scenario[:preserved]
      forbidden = [ manifestation.id, manifestation.protocol, secrecy::TEXTS[:preserved_body], secrecy::TEXTS[:complement],
                    scenario[:leaf].name, ids[:preserved_attachment] ] + preserved_identity
      inbox.each { |r| forbidden.each { |secret| expect(r[:raw]).not_to include(secret), "#{r[:path]} contém #{secret.inspect}" } }
    end

    # U1 e Q2: o nome e o CPF do par declarado só voltam na identidade da
    # identificada (o nome e o CPF mascarado); o nome gravado do anexo nunca volta.
    it "o full_name e o CPF do U1 só no detalhe identificado (CPF mascarado); nenhum CPF cru fora do /identity; nenhum nome de arquivo" do
      declared_detail = "/ombudsman/manifestations/#{ids[:declared]}"
      shown = staff_reads.select { |r| r[:path] == declared_detail }
      expect(shown).not_to be_empty
      shown.each do |read|
        expect(JSON.parse(read[:raw])["identity"]).to include("name" => secrecy::NAMES[:declared],
                                                              "cpf_masked" => CitizenIdentity::Cpf.mask(cpfs[:declared]))
      end
      (responses - shown).each do |read|
        expect(read[:raw]).not_to include(secrecy::NAMES[:declared]), "#{read[:verb]} #{read[:path]} contém o nome do U1"
      end

      outside_identity = responses.reject { |r| r[:path] == identity_path }
      outside_identity.each do |read|
        (cpf_forms + phone_forms).each { |secret| expect(read[:raw]).not_to include(secret), "#{read[:verb]} #{read[:path]} contém #{secret}" }
      end

      responses.select { |r| r[:path].start_with?("/ombudsman/", "/citizen/ombudsman/") }.each do |read|
        secrecy::FILENAMES.each do |filename|
          expect(read[:raw]).not_to include(filename), "#{read[:path]} contém o nome do arquivo"
          expect(read[:headers].values.join).not_to include(filename), "#{read[:path]} (cabeçalho) contém o nome do arquivo"
        end
      end
    end

    # Q41: as rotas públicas não gravam cookie e não leem nem deslizam a sessão
    # que a requisição carrega; a denúncia não ganha cidadão.
    it "as rotas públicas, com o cookie de uma sessão válida, não gravam cookie nem tocam a sessão" do
      route = scenario[:public_route]
      expect(route[:cookies]).to eq([ nil, nil, nil ])
      expect(route[:session_after]).to eq(route[:session_before])
      expect(route[:config]["anonymous_web"]).to be(true)
      expect(OmbudsmanManifestation.find(ids[:anonymous]).citizen_id).to be_nil
    end

    # §9 e Q15, Q16: o aviso é só o tipo e o protocolo; o SMS, só o texto fixo.
    it "o aviso ao cidadão só tem tipo e protocolo, e todo SMS é o SMS_TEXT" do
      ombudsman = ids[:notices]["notices"].select { |n| n["kind"] == "ombudsman" }
      expect(ombudsman.map { |n| n["event"] }).to contain_exactly("complement_requested", "interim_response", "final_response")
      ombudsman.each do |notice|
        expect(notice.keys).to contain_exactly("kind", "id", "event", "protocol", "created_at", "read", "cpf_masked")
        expect(notice["protocol"]).to eq(scenario[:preserved].protocol)
      end
      notices = JSON.generate(ids[:notices])
      texts.each { |secret| expect(notices).not_to include(secret), "aviso contém #{secret.inspect}" }

      deliveries = scenario[:sms]
      expect(deliveries.size).to eq(3) # os três avisos do cidadão com opt-in
      expect(deliveries.map { |d| d[:body] }.uniq).to eq([ Ombudsman::Catalog::SMS_TEXT ])
      expect(deliveries.map { |d| d[:phone] }.uniq).to eq([ secrecy::PHONES[:preserved] ])
      expect(Ombudsman::Catalog::SMS_TEXT).not_to include(scenario[:preserved].protocol)
      expect(OmbudsmanNotice.column_names).not_to include("body", "text")
    end
  end
end

# §13 (nunca em URL; preflight F-14): toda rota de /ombudsman e de
# /citizen/ombudsman recusa texto e CPF na query com o NOME da chave, sem ecoar
# o valor — inclusive as que só leem e as que gravam.
RSpec.describe "Sigilo da ouvidoria (33) — query de toda rota", type: :request do
  let!(:city) { ombudsman_city!(anonymous: true) }
  let(:reader) do
    step_up_enrolled!(staff_with("leitura-ouv-#{SecureRandom.hex(3)}@cidade.gov.br", "ombudsman", "ombudsman_responder"))
  end

  def module_routes
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      [ route.verb, path ] if path.match?(%r{\A/(citizen/)?ombudsman/})
    end.uniq
  end

  it "o módulo tem as 50 rotas do plano (41 da equipe e 9 do cidadão)" do
    routes = module_routes
    expect(routes.count { |_, path| path.start_with?("/ombudsman/") }).to eq(41)
    expect(routes.count { |_, path| path.start_with?("/citizen/ombudsman/") }).to eq(9)
  end

  it "GET /ombudsman/manifestations?cpf=… → 422 path cpf" do
    cpf = "52998224725"
    sign_in_as(reader)
    get "/ombudsman/manifestations?cpf=#{cpf}"
    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)).to eq("error" => "invalid_request", "path" => "cpf",
                                            "problems" => [ { "path" => "cpf", "error" => "invalid_request" } ])
    expect(response.body).not_to include(cpf)
  end

  it "toda rota de /ombudsman e de /citizen/ombudsman recusa cpf e body na query (422 com o nome da chave, sem o valor)" do
    values = { "cpf" => "52998224725", "body" => "Texto reservado na query da rota" }
    sign_in_as(reader)
    sign_in_citizen("+5541998765432")
    failures = []
    module_routes.each do |verb, route|
      path = route.gsub(":year", "2026").gsub(/:\w+/) { SecureRandom.uuid }
      values.each do |key, value|
        url = "#{path}?#{key}=#{CGI.escape(value)}"
        headers = { "CONTENT_TYPE" => "application/json" }
        case verb
        when "GET" then get(url)
        when "PATCH" then patch(url, params: "{}", headers: headers)
        else post(url, params: "{}", headers: headers)
        end
        json = JSON.parse(response.body) rescue {}
        got = [ response.status, json["error"], json["path"] ]
        failures << "#{verb} #{route}?#{key} → #{response.status} #{response.body[0, 120]}" unless got == [ 422, "invalid_request", key ]
        failures << "#{verb} #{route}?#{key} ecoa o valor" if response.body.include?(value)
      end
    end
    expect(failures).to be_empty, failures.join("\n")
  end
end

# §1 e §13: a varredura de fonte (Prism) — todo DomainEvents.publish com nome
# "ombudsman.…" em app/ e lib/ usa um dos sete do contrato, com nome literal e
# só as chaves de id e o outcome; nos arquivos do módulo, nenhum nome dinâmico.
RSpec.describe "Sigilo da ouvidoria (33) — DomainEvents.publish na fonte" do
  def publish_calls
    Dir[Rails.root.join("{app,lib}/**/*.rb").to_s].flat_map do |file|
      found = []
      walk = lambda do |node|
        if node.is_a?(Prism::CallNode) && node.name == :publish && node.receiver.respond_to?(:full_name) &&
           node.receiver.full_name.delete_prefix("::") == "DomainEvents"
          found << [ file, node ]
        end
        node.compact_child_nodes.each { |child| walk.call(child) }
      end
      walk.call(Prism.parse_file(file).value)
      found
    end
  end

  it "só os sete nomes do contrato, com payload só de ids e outcome literal" do
    calls = publish_calls
    expect(calls.size).to be > 100 # controle: a varredura achou as chamadas do app
    module_calls = calls.select { |file, _| file.include?("ombudsman") }
    names = []
    calls.each do |file, call|
      where = "#{file.delete_prefix("#{Rails.root}/")}:#{call.location.start_line}"
      args = call.arguments&.arguments || []
      event = args.first
      if module_calls.any? { |_, c| c.equal?(call) }
        expect(event).to be_a(Prism::StringNode), "#{where}: o nome do evento deve ser literal"
      end
      next unless event.is_a?(Prism::StringNode) && event.unescaped.start_with?("ombudsman.")

      names << event.unescaped
      expect(Ombudsman::Catalog::DOMAIN_EVENTS).to include(event.unescaped), "#{where}: #{event.unescaped} fora do contrato"
      pairs = args.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode)
      keys = pairs.map { |assoc| assoc.key.respond_to?(:unescaped) ? assoc.key.unescaped : assoc.key.slice }
      expect(keys - OmbudsmanSecrecy::PAYLOAD_KEYS).to be_empty, "#{where}: chaves #{keys}"
      outcome = pairs.find { |assoc| assoc.key.respond_to?(:unescaped) && assoc.key.unescaped == "outcome" }
      expect(outcome.value).to be_a(Prism::StringNode).and(have_attributes(unescaped: be_in(%w[answered archived]))), where if outcome
    end
    expect(names.uniq).to match_array(Ombudsman::Catalog::DOMAIN_EVENTS)
    expect(module_calls.map { |_, call| call.arguments.arguments.first.unescaped }.uniq).to match_array(Ombudsman::Catalog::DOMAIN_EVENTS)
  end
end

# §13 (Todo Platform.audit novo entra em R18): o módulo não audita na
# plataforma. Platform.audit( é multilinha: procura-se o nome da chamada,
# que não quebra linha, em todo arquivo do módulo.
RSpec.describe "Sigilo da ouvidoria (33) — sem Platform.audit novo" do
  it "nenhum arquivo do módulo chama Platform.audit e R18 segue sem nome da ouvidoria" do
    files = OmbudsmanSecrecy::MODULE_GLOBS.flat_map { |glob| Dir[Rails.root.join(glob).to_s] }.uniq
    expect(files.size).to be >= 90
    %w[app/commands/ombudsman/register.rb app/services/ombudsman/json.rb app/jobs/ombudsman/mail_job.rb
       app/controllers/citizen_api/ombudsman/anonymous_reports_controller.rb app/views/ombudsman_mailer/daily_summary.text.erb
       lib/ombudsman_crew.rb app/controllers/departments_controller.rb].each do |path|
      expect(files).to include(Rails.root.join(path).to_s), "#{path} fora das globs"
    end
    offenders = files.select { |file| File.read(file).match?(/Platform\s*\.\s*audit\b/) }
    expect(offenders).to be_empty

    guard = File.read(Rails.root.join("spec/events/platform_event_payload_guard_spec.rb"))
    r18 = guard[/R18_PLATFORM_EVENT_NAMES = %w\[(.*?)\]\.freeze/m, 1].to_s.split
    expect(r18).to include("city.feature_changed")
    expect(r18.grep(/ombudsman|department/)).to be_empty
    expect(Platform::Features::KEYS).to include(Ombudsman::Gate::KEY, Ombudsman::AnonymousGate::KEY)
  end
end

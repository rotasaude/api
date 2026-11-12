require "zlib"
require_relative "signature_crew"
require_relative "screening_crew"
require_relative "care_lines_crew"

# Semente de dev do módulo 33 (ADR 0051), para a prova no navegador. Dev é
# fictício mas imita o real: em Curitiba, `ombudsman` e `ombudsman_anonymous_web`
# LIGADOS pelo mantenedor de dev; prazos padrão e assuntos semeados; os quatro
# setores da secretaria; a equipe pelo mesmo caminho das outras sementes
# (papéis privilegiados incluídos), todos com TOTP fixo:
#
#   e-mail                       papel                 onde responde
#   ouvidor@curitiba.dev         ombudsman             -
#   ouvidoria@curitiba.dev       ombudsman_staff       -
#   farmacia.resp@curitiba.dev   ombudsman_responder   setor "Assistência Farmacêutica"
#   ubs.resp@curitiba.dev        ombudsman_responder   UBS Vila Esperança (do ProfessionalCrew)
#
# Cenário, TUDO pelos comandos do app (Ombudsman::Register, RegisterAnonymous,
# Classify, Forward, ReplyForwarding, RequestComplement, RecordComplement,
# Extend, InterimResponse, FinalResponse, Archive, RecordSatisfaction,
# SaveAnnualReport), com as datas escalonadas por `now:`. As pessoas são as do
# wpda (CareLinesCrew, CPF fictício com dígito válido):
#
#   quem            o quê                                             cor / estado
#   José            reclamação web, anexo "anexo-1.pdf", farmácia     amarela, encaminhada (27 dias)
#   Ana             solicitação web, identidade preservada            pausada, aguardando complemento
#   Maria           elogio web, respondido, pesquisa de satisfação    respondida
#   (anônima)       denúncia anônima web                              verde, recebida
#   (sem cidadão)   reclamação por telefone (nome só declarado)       vermelha, em análise (35 dias)
#   José            a mesma reclamação, arquivada por duplicidade     arquivada
#   Rafael          reclamação web, resposta provisória e prorrogação verde, em análise
#   Antônio         solicitação web, complemento pedido e recebido    verde, em análise
#   Juliana         reclamação web, UBS responde, resposta conclusiva respondida (sem pesquisa)
#   Sebastião       reclamação web encaminhada à UBS (sem resposta)   encaminhada
#   Sandra          reclamação web pelo par {cpf, nome} declarado     verde, recebida
#   Osvaldo         sugestão no balcão (in_person)                    verde, em análise
#
# Mais um histórico de registros da equipe e do web, concluídos nos últimos
# meses, para o painel passar da supressão de células pequenas, e o relatório
# de 2025 em rascunho. Idempotente: cada manifestação é achada pelo texto que
# gravou e cada passo só roda se o evento dele ainda não existe.
#
# Só e-mail, papel e otpauth na saída: nunca protocolo, texto nem nome.
class OmbudsmanCrew
  # UBS do ProfessionalCrew diferente da da ESF (CareLinesCrew::UNIT).
  RESPONDER_UNIT = "UBS Vila Esperança".freeze
  DEV_MAINTAINER = "dev@local".freeze
  EMAIL_DOMAIN = "dev".freeze
  FEATURES = %w[ombudsman ombudsman_anonymous_web].freeze
  ANNUAL_REPORT_YEAR = 2025
  DEPARTMENTS = [ "Assistência Farmacêutica", "Regulação", "Atenção Primária", "Vigilância Sanitária" ].freeze

  STAFF = {
    ombudsman: { email: "ouvidor", role: "ombudsman",
                 secret_env: "DEV_OMBUDSMAN_OTP_SECRET", default_secret: "OUVIDORCHEFESEMENTEDEVCURITIBA22" },
    technician: { email: "ouvidoria", role: "ombudsman_staff",
                  secret_env: "DEV_OMBUDSMAN_STAFF_OTP_SECRET", default_secret: "OUVIDORIATECNICOSEMENTEDEVCWB234" },
    pharmacy: { email: "farmacia.resp", role: "ombudsman_responder", department: "Assistência Farmacêutica",
                secret_env: "DEV_OMBUDSMAN_PHARMACY_OTP_SECRET", default_secret: "RESPONDENTEFARMACIASEMENTEDEVCW2" },
    unit: { email: "ubs.resp", role: "ombudsman_responder", unit: RESPONDER_UNIT,
            secret_env: "DEV_OMBUDSMAN_UNIT_OTP_SECRET", default_secret: "RESPONDENTEUBSSEMENTEDEVCURITIB2" }
  }.freeze

  # O que o wpda manda no upload: um PDF mínimo, com o nome "anexo-1.pdf".
  PDF = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".freeze
  ATTACHMENT_NAME = "anexo-1.pdf".freeze

  # Os cenários nomeados (texto = a chave de idempotência; tudo fictício).
  BODIES = {
    jose: "A farmácia da unidade está sem a insulina que uso todos os meses. Já voltei três vezes e só ouço que ainda não chegou.",
    ana: "Preciso de uma consulta com especialista e não consigo saber em que posição da fila estou. Peço que a minha identidade seja preservada.",
    maria: "Quero elogiar a equipe de enfermagem da unidade, que me atendeu com muito cuidado e paciência durante a vacina da minha mãe.",
    anonymous: "Vi, mais de uma vez, funcionário vendendo vaga de consulta na porta da unidade de saúde do bairro.",
    phone: "Moro na região do Sítio Cercado e a unidade fica sem médico duas manhãs por semana. Liguei para registrar a reclamação.",
    duplicate: "Repito minha reclamação: a farmácia da unidade continua sem insulina e ninguém me dá previsão de chegada.",
    rafael: "A marcação do exame de ultrassom está demorando demais e já passaram dois meses desde o pedido da minha médica.",
    antonio: "Solicito a segunda via do meu encaminhamento para ortopedia, que ficou perdido na unidade.",
    juliana: "A sala de espera da unidade está sempre lotada e sem ventilação, o que preocupa quem está com sintomas respiratórios.",
    sebastiao: "A agente de saúde não passa na minha rua há meses e a minha mãe, acamada, está sem acompanhamento.",
    sandra: "Fui mal atendida na recepção da unidade ontem, a atendente foi grosseira diante de outras pessoas.",
    osvaldo: "Sugiro colocar bancos e cobertura na fila externa da unidade, para os idosos esperarem sentados e protegidos da chuva."
  }.freeze

  EXTRACTS = {
    jose: "Usuário relata falta de insulina na dispensação da unidade, com três idas sem sucesso. Pede previsão de reposição.",
    sebastiao: "Familiar de paciente acamada relata que a agente de saúde não visita a residência há meses. Pede retomada da visita."
  }.freeze

  # Histórico: tipo => quantidade. O texto leva o número do registro.
  HISTORY_KINDS = { "complaint" => 8, "praise" => 6, "report" => 5, "suggestion" => 6, "request" => 6 }.freeze
  HISTORY_CHANNELS = %w[phone in_person ouvidorsus].freeze
  HISTORY_TEXT = {
    "complaint" => "Reclamo da demora no atendimento da unidade de saúde do meu bairro",
    "praise" => "Elogio o atendimento recebido da equipe da unidade de saúde",
    "report" => "Registro uma denúncia sobre irregularidade observada na unidade de saúde",
    "suggestion" => "Sugiro melhorar a sinalização e o conforto da unidade de saúde",
    "request" => "Solicito informação sobre o andamento do meu pedido na unidade de saúde"
  }.freeze
  NAMES = [ "Cláudia Regina Matos", "Eduardo Henrique Pinto", "Fátima Aparecida Lopes", "Gilberto Souza Neto", "Helena Cristina Dias",
            "Ivan Rodrigo Teixeira", "Jussara Mendes Prado", "Leandro Augusto Freitas", "Marta Lúcia Barbosa", "Nelson Ricardo Campos",
            "Olívia Fernandes Ramos", "Paulo Sérgio Andrade" ].freeze
  HISTORY_WEB = %i[rafael juliana osvaldo sebastiao antonio].freeze
  HISTORY_WEB_COUNT = 6

  class << self
    def seed_current_city(slug:, ddd: nil, password: ENV.fetch(SignatureCrew::PASSWORD_ENV, "dev-password"))
      guard_environment!
      return off("fora") unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      unless maintainer
        warn "[seeds] ouvidoria: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptores não ligados"
        return off("desligado (sem mantenedor #{DEV_MAINTAINER})")
      end

      city = City.find(Current.city.id)
      admin = User.find_by!(email_address: "admin@#{slug}.demo")
      FEATURES.each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer) }
      Ombudsman::Settings.ensure_defaults!
      CityCatalog.reset_cache!

      staff = staff!(slug, password)
      departments = departments!(staff.fetch(:ombudsman))
      responders!(staff, departments)
      context = context(slug, ddd, staff, departments)
      scenarios!(context)
      history!(context)
      annual_report!(context)

      { switch: Ombudsman::Gate.usable?(city) && Ombudsman::AnonymousGate.usable?(city) ? "ligado (#{FEATURES.join(' e ')})" : "ligado, não utilizável",
        departments: departments.size, manifestations: OmbudsmanManifestation.count, admin: admin.email_address,
        users: staff.map { |key, user| { email: user.email_address, role: STAFF.fetch(key).fetch(:role), otpauth_uri: SignatureCrew.otpauth_uri(user) } } }
    end

    # Só e-mail, papel e otpauth (nunca protocolo, texto nem nome).
    def summary_lines(result, password:)
      head = "[seeds] ouvidoria #{result[:switch]}"
      head += "; #{result[:departments]} setores; #{result[:manifestations]} manifestações" if result[:departments].to_i.positive?
      [ head ] + result[:users].map { |u| "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }
    end

    private

    def guard_environment!
      raise "semente da ouvidoria: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def off(switch) = { switch: switch, departments: 0, manifestations: 0, users: [] }

    # Nunca com texto nem nome: só o motivo e os paths da recusa.
    def check!(result, what)
      if result.failure?
        problems = Array(result.details[:problems]).map { |p| "#{p[:error]}@#{p[:path]}" }.join(",")
        raise "semente da ouvidoria: #{what} recusado (#{result.reason} #{result.details[:path]} #{problems})"
      end

      result
    end

    # --- equipe, setores e respondentes ------------------------------------------

    # Mesmo caminho das outras sementes: a membership entra direto (a semente é o
    # administrador de dev) e o TOTP é fixo.
    def staff!(slug, password)
      STAFF.to_h do |key, spec|
        user = User.find_or_initialize_by(email_address: "#{spec[:email]}@#{slug}.#{EMAIL_DOMAIN}")
        user.password = password
        user.save!
        Membership.find_or_create_by!(user: user, role: spec[:role]) { |m| m.granted_at = Time.current }
        SignatureCrew.ensure_totp(user, secret_env: spec[:secret_env], default_secret: spec[:default_secret])
        [ key, user.reload ]
      end
    end

    def departments!(ombudsman)
      DEPARTMENTS.to_h do |name|
        department = Department.where("lower(name) = ?", name.downcase).first
        department ||= check!(Ombudsman::SaveDepartment.call(department: nil, attrs: { "name" => name }, by: ombudsman), "setor").payload.fetch(:department)
        [ name, department ]
      end
    end

    def responders!(staff, departments)
      STAFF.each do |key, spec|
        next unless spec[:role] == "ombudsman_responder"

        user = staff.fetch(key)
        destination = spec[:department] ? { "department_id" => departments.fetch(spec[:department]).id } : { "health_unit_id" => unit!(spec[:unit]).id }
        next if OmbudsmanResponder.exists?(destination.transform_keys(&:to_sym).merge(user_id: user.id))

        check!(Ombudsman::SaveResponder.call(responder: nil, attrs: destination.merge("user_id" => user.id), by: staff.fetch(:ombudsman)), "respondente")
      end
    end

    def unit!(name) = HealthUnit.find_by(name: name) || raise("semente da ouvidoria: #{name} ausente — rode o db:seed inteiro (ProfessionalCrew) antes")

    def context(slug, ddd, staff, departments)
      leaves = OmbudsmanSubject.active.where.not(parent_id: nil).order(:position, :id).to_a
      { slug: slug, ddd: ddd, staff: staff, departments: departments, clock: Time.current, leaves: leaves,
        index: OmbudsmanManifestation.all.index_by(&:body), responder_unit: unit!(RESPONDER_UNIT), unit_one: unit!(CareLinesCrew::UNIT),
        citizens: {}, sessions: {} }
    end

    def ago(context, days, hours = 0) = context.fetch(:clock) - days.days - hours.hours

    def leaf(context, name) = context.fetch(:leaves).find { |s| s.name == name } || raise("semente da ouvidoria: assunto #{name} ausente")

    def citizen(context, key)
      context.fetch(:citizens)[key] ||= Citizen.find_by(cpf: CareLinesCrew.cpf_for(context.fetch(:slug), key)) ||
                                        raise("semente da ouvidoria: pessoa #{key} ausente — rode o CareLinesCrew (db:seed inteiro) antes")
    end

    # A sessão do telefone da pessoa (uma por execução; o token nunca sai).
    def session(context, key)
      context.fetch(:sessions)[key] ||= CitizenSession.start!(phone: citizen(context, key).phone).first
    end

    def remember(context, manifestation) = (context.fetch(:index)[manifestation.body] = manifestation)

    def found(context, body) = context.fetch(:index)[body]&.reload

    # --- passos idempotentes -------------------------------------------------------

    # Roda o bloco só se o evento do passo ainda não existe na manifestação.
    def once(manifestation, kind)
      return if OmbudsmanEvent.exists?(ombudsman_manifestation_id: manifestation.id, kind: kind)

      yield
      manifestation.reload
    end

    def classify!(context, manifestation, subject, at, health_unit: nil, urgent: false)
      once(manifestation, "classified") do
        attrs = { "subject_id" => subject.id, "urgent" => urgent }
        attrs["health_unit_id"] = health_unit.id if health_unit
        check!(Ombudsman::Classify.call(manifestation_id: manifestation.id, expected_state: manifestation.state, attrs: attrs,
                                        by: context.dig(:staff, :technician), now: at), "classificação")
      end
    end

    def final!(context, manifestation, text, resolution, at)
      once(manifestation, "final_response") do
        check!(Ombudsman::FinalResponse.call(manifestation_id: manifestation.id, expected_state: manifestation.state, text: text,
                                             resolution: resolution, by: context.dig(:staff, :technician), now: at), "resposta conclusiva")
      end
    end

    def interim!(context, manifestation, text, at)
      once(manifestation, "interim_response") do
        check!(Ombudsman::InterimResponse.call(manifestation_id: manifestation.id, expected_state: manifestation.state, text: text,
                                               by: context.dig(:staff, :technician), now: at), "resposta provisória")
      end
    end

    def forward!(context, manifestation, destination, extract, at)
      once(manifestation, "forwarded") do
        key = destination.is_a?(Department) ? :department_id : :health_unit_id
        check!(Ombudsman::Forward.call(manifestation_id: manifestation.id, expected_state: manifestation.state,
                                       department_id: (destination.id if key == :department_id),
                                       health_unit_id: (destination.id if key == :health_unit_id),
                                       extract: extract, by: context.dig(:staff, :technician), now: at), "encaminhamento")
      end
    end

    def satisfaction!(manifestation, met, clear, score, at)
      return if OmbudsmanSatisfactionResponse.exists?(ombudsman_manifestation_id: manifestation.id)

      check!(Ombudsman::RecordSatisfaction.call(manifestation: manifestation, met: met, clear: clear, score: score, now: at), "pesquisa")
    end

    # --- registros -----------------------------------------------------------------

    # Web pela sessão do cidadão (ou o par declarado, `declared:`), com os anexos.
    def web!(context, key, body, kind:, mode:, at:, declared: nil, health_unit: nil, attach: false)
      return found(context, body) if context.fetch(:index).key?(body)

      session = session(context, key)
      attrs = { "kind" => kind, "identification_mode" => mode, "body" => body }
      attrs["health_unit_id"] = health_unit.id if health_unit
      if declared
        attrs.merge!("cpf" => CareLinesCrew.cpf_for(context.fetch(:slug), key), "full_name" => declared)
        citizen = nil
      else
        citizen = citizen(context, key)
      end
      if attach
        upload = check!(Ombudsman::Attachments.upload(data: Base64.strict_encode64(PDF), content_type: "application/pdf",
                                                      filename: ATTACHMENT_NAME, citizen_session: session), "anexo")
        attrs["attachment_ids"] = [ upload.payload.fetch(:attachment).id ]
      end
      registered = check!(Ombudsman::Register.call(attrs: attrs, channel: "web", citizen: citizen, citizen_session: session, now: at), "registro web")
      remember(context, registered.payload.fetch(:manifestation))
    end

    def staff_register!(context, body, channel:, kind:, mode:, at:, extra: {})
      return found(context, body) if context.fetch(:index).key?(body)

      attrs = { "kind" => kind, "identification_mode" => mode, "body" => body }.merge(extra)
      registered = check!(Ombudsman::Register.call(attrs: attrs, channel: channel, by: context.dig(:staff, :technician), now: at), "registro da equipe")
      remember(context, registered.payload.fetch(:manifestation))
    end

    # --- cenário -------------------------------------------------------------------

    def scenarios!(context)
      jose!(context)
      ana!(context)
      maria!(context)
      anonymous!(context)
      phone!(context)
      duplicate!(context)
      rafael!(context)
      antonio!(context)
      juliana!(context)
      sebastiao!(context)
      sandra!(context)
      osvaldo!(context)
    end

    # Amarela: 27 dias desde o recebimento (vence em 3); encaminhada à farmácia.
    def jose!(context)
      m = web!(context, :jose, BODIES[:jose], kind: "complaint", mode: "identified", at: ago(context, 27), attach: true, health_unit: context[:unit_one])
      classify!(context, m, leaf(context, "Falta"), ago(context, 26))
      forward!(context, m, context.dig(:departments, "Assistência Farmacêutica"), EXTRACTS[:jose], ago(context, 10))
    end

    # Pausada: complemento pedido há 3 dias.
    def ana!(context)
      m = web!(context, :ana, BODIES[:ana], kind: "request", mode: "preserved", at: ago(context, 10))
      classify!(context, m, leaf(context, "Fila"), ago(context, 9))
      once(m, "complement_requested") do
        check!(Ombudsman::RequestComplement.call(manifestation_id: m.id, expected_state: m.state, by: context.dig(:staff, :technician), now: ago(context, 3),
                                                 text: "Informe a especialidade do encaminhamento e a unidade que fez o pedido."), "pedido de complemento")
      end
    end

    def maria!(context)
      m = web!(context, :maria, BODIES[:maria], kind: "praise", mode: "identified", at: ago(context, 9))
      classify!(context, m, leaf(context, "Acolhimento"), ago(context, 8))
      final!(context, m, "Agradecemos o elogio. Ele foi repassado à equipe de enfermagem da unidade.", nil, ago(context, 4))
      satisfaction!(m, "yes", true, 5, ago(context, 3))
    end

    # Verde: recebida hoje, sem pessoa.
    def anonymous!(context)
      return if context.fetch(:index).key?(BODIES[:anonymous])

      result = check!(Ombudsman::RegisterAnonymous.call(body: BODIES[:anonymous], health_unit_id: context[:unit_one].id, now: ago(context, 0, 2)), "denúncia anônima")
      remember(context, result.payload.fetch(:manifestation))
    end

    # Vermelha: 35 dias, sem cidadão (nome e contato só declarados pela equipe).
    def phone!(context)
      m = staff_register!(context, BODIES[:phone], channel: "phone", kind: "complaint", mode: "identified", at: ago(context, 35),
                          extra: { "manifestant_name" => "Valdir Antunes de Oliveira", "manifestant_contact" => "(41) 99877-0142",
                                   "manifestant_cpf" => ScreeningCrew.cpf_for("#{context.fetch(:slug)}:ombudsman:phone") })
      classify!(context, m, leaf(context, "Falta de profissional"), ago(context, 34))
    end

    def duplicate!(context)
      original = found(context, BODIES[:jose])
      m = web!(context, :jose, BODIES[:duplicate], kind: "complaint", mode: "identified", at: ago(context, 6))
      once(m, "archived") do
        check!(Ombudsman::Archive.call(manifestation_id: m.id, expected_state: m.state, reason: "duplicate", duplicate_of_id: original.id,
                                       external_body_name: nil, by: context.dig(:staff, :technician), now: ago(context, 5)), "arquivamento")
      end
    end

    # Verde: resposta provisória e prorrogação.
    def rafael!(context)
      m = web!(context, :rafael, BODIES[:rafael], kind: "complaint", mode: "identified", at: ago(context, 16))
      classify!(context, m, leaf(context, "Agendamento"), ago(context, 15))
      interim!(context, m, "Sua manifestação está em análise na regulação de exames.", ago(context, 8))
      once(m, "extended") do
        check!(Ombudsman::Extend.call(manifestation_id: m.id, expected_state: m.state, by: context.dig(:staff, :technician), now: ago(context, 7),
                                      text: "Prorrogado: o pedido depende de resposta da central de regulação."), "prorrogação")
      end
    end

    # Complemento pedido e recebido: volta a em análise.
    def antonio!(context)
      m = web!(context, :antonio, BODIES[:antonio], kind: "request", mode: "identified", at: ago(context, 12))
      classify!(context, m, leaf(context, "Agendamento"), ago(context, 11))
      once(m, "complement_requested") do
        check!(Ombudsman::RequestComplement.call(manifestation_id: m.id, expected_state: m.state, by: context.dig(:staff, :technician), now: ago(context, 9),
                                                 text: "Informe em que unidade o encaminhamento foi emitido e a data aproximada."), "pedido de complemento")
      end
      once(m, "complement_received") do
        check!(Ombudsman::RecordComplement.call(manifestation: m, expected_state: m.state, text: "Foi na UBS Jardim das Flores, em março deste ano.",
                                                attachment_ids: [], actor: "citizen", by: nil, owner: session(context, :antonio), field: "body",
                                                now: ago(context, 7)), "complemento")
      end
    end

    # Encaminhada à UBS, respondida, conclusiva "resolvida"; sem pesquisa (o cidadão responde na prova).
    def juliana!(context)
      m = web!(context, :juliana, BODIES[:juliana], kind: "complaint", mode: "identified", at: ago(context, 18), health_unit: context[:responder_unit])
      classify!(context, m, leaf(context, "Instalações"), ago(context, 17), health_unit: context[:responder_unit])
      forward!(context, m, context[:responder_unit],
               "Usuária relata sala de espera lotada e sem ventilação na unidade. Pede providências sobre o espaço.", ago(context, 15))
      forwarding = m.forwardings.find_by!(health_unit_id: context[:responder_unit].id)
      once(m, "forwarding_replied") do
        check!(Ombudsman::ReplyForwarding.call(forwarding_id: forwarding.id, expected_state: forwarding.state, by: context.dig(:staff, :unit), now: ago(context, 12),
                                               body: "Instalamos dois ventiladores e reorganizamos as cadeiras; a fila agora usa senha."), "resposta do respondente")
      end
      final!(context, m, "A unidade reorganizou a sala de espera e instalou ventilação. Obrigado por avisar.", "resolved", ago(context, 10))
    end

    # Ainda pendente na UBS: o respondente tem item para responder.
    def sebastiao!(context)
      m = web!(context, :sebastiao, BODIES[:sebastiao], kind: "complaint", mode: "identified", at: ago(context, 8), health_unit: context[:responder_unit])
      classify!(context, m, leaf(context, "Falta de profissional"), ago(context, 7), health_unit: context[:responder_unit])
      forward!(context, m, context[:responder_unit], EXTRACTS[:sebastiao], ago(context, 4))
    end

    # O par {cpf, nome} declarado, sem triagem (U1): a pessoa é a Sandra do wpda.
    def sandra!(context)
      web!(context, :sandra, BODIES[:sandra], kind: "complaint", mode: "identified", at: ago(context, 2), declared: "Sandra Regina Pereira")
    end

    def osvaldo!(context)
      m = staff_register!(context, BODIES[:osvaldo], channel: "in_person", kind: "suggestion", mode: "identified", at: ago(context, 3),
                          extra: { "citizen_id" => citizen(context, :osvaldo).id })
      classify!(context, m, leaf(context, "Instalações"), ago(context, 2))
    end

    # --- histórico para o painel ---------------------------------------------------

    def history!(context)
      index = 0
      HISTORY_KINDS.each do |kind, quantity|
        quantity.times do
          history_staff!(context, index, kind)
          index += 1
        end
      end
      HISTORY_WEB_COUNT.times { |n| history_web!(context, n) }
    end

    def history_body(kind, number) = format("%<text>s (registro de histórico %<n>02d).", text: HISTORY_TEXT.fetch(kind), n: number)

    def history_staff!(context, index, kind)
      body = history_body(kind, index)
      channel = HISTORY_CHANNELS[index % HISTORY_CHANNELS.size]
      received = ago(context, 40 + index * 8)
      extra = {}
      extra["ouvidorsus_number"] = format("OUV-%05d", 41_000 + index) if channel == "ouvidorsus"
      if kind == "report"
        mode = "anonymous"
      else
        mode = "identified"
        extra.merge!("manifestant_name" => NAMES[index % NAMES.size], "manifestant_contact" => format("(41) 99%03d-%04d", 100 + index, 2000 + index))
      end
      m = staff_register!(context, body, channel: channel, kind: kind, mode: mode, at: received, extra: extra)
      classify!(context, m, history_leaf(context, index), received + 1.day)
      return archive_history!(context, m, received + 5.days) if index % 6 == 5

      resolution = Ombudsman::Catalog::RESOLUTION_KINDS.include?(kind) ? Ombudsman::Catalog::RESOLUTIONS[index % 4 == 3 ? 1 : 0] : nil
      final!(context, m, "Manifestação analisada e respondida pela Ouvidoria da Saúde.", resolution, received + 12.days)
    end

    def history_leaf(context, index) = context.fetch(:leaves)[(index * 3) % 4]

    def archive_history!(context, manifestation, at)
      once(manifestation, "archived") do
        check!(Ombudsman::Archive.call(manifestation_id: manifestation.id, expected_state: manifestation.state, reason: "improper", duplicate_of_id: nil,
                                       external_body_name: nil, by: context.dig(:staff, :technician), now: at), "arquivamento")
      end
    end

    # Web respondida, com a pesquisa de satisfação (a média do painel sai da supressão).
    def history_web!(context, number)
      key = HISTORY_WEB[number % HISTORY_WEB.size]
      body = history_body(number.even? ? "complaint" : "praise", 100 + number)
      received = ago(context, 60 + number * 9)
      m = web!(context, key, body, kind: number.even? ? "complaint" : "praise", mode: "identified", at: received)
      classify!(context, m, history_leaf(context, number + 1), received + 1.day)
      final!(context, m, "Manifestação analisada e respondida pela Ouvidoria da Saúde.", (number.even? ? "resolved" : nil), received + 10.days)
      satisfaction!(m, %w[yes partly no yes yes yes][number % 6], number % 3 != 2, [ 5, 4, 2, 5, 4, 5 ][number % 6], received + 12.days)
    end

    # --- relatório de gestão -------------------------------------------------------

    def annual_report!(context)
      report = OmbudsmanAnnualReport.find_by(year: ANNUAL_REPORT_YEAR)
      return if report&.published?

      check!(Ombudsman::SaveAnnualReport.call(year: ANNUAL_REPORT_YEAR, now: ago(context, 0, 1), attrs: {
        "recurring_problems" => "Demora na marcação de exames e consultas especializadas; falta de medicamento na dispensação das unidades.",
        "actions_taken" => "Reunião mensal com a regulação e com a assistência farmacêutica; revisão do fluxo de reposição.",
        "notes" => "Rascunho de dev: números do ano saem do painel ao publicar."
      }), "relatório de #{ANNUAL_REPORT_YEAR}")
    end
  end
end

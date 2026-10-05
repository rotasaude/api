# lib/triage_catalog_crew.rb
require_relative "signature_crew"
require_relative "campaign_history"

# Semente de dev do módulo 15 (spec 2026-10-05 §10). Dev é fictício mas imita
# o real: três protocolos passam pelo ciclo assinado de verdade (SaveDraft →
# SubmitForReview → 2 assinaturas → Publish → 2 assinaturas → Activate), o
# aprofundamento primeiro (é o alvo da sugestão da saúde mental); avó (62) e
# neto (8) no mesmo celular, CPF com dígito válido; em Curitiba, o idoso fica
# restrito a dois bairros e a avó mora num deles. Todo protocolo da semente tem
# offer.eligibility, e protocolo com elegibilidade sem linha em triage_offers
# não é oferecido (spec §5.1, regra 1): por isso cada cidade ganha as linhas do
# catálogo (idoso, saúde mental e aprofundamento), o idoso sem restrição fora
# de Curitiba. Idempotente.
class TriageCatalogCrew
  PHONE_PREFIX = "94444"
  DEEP = "saude-mental-aprofundada"
  ELDERLY = "saude-do-idoso"
  MENTAL = "saude-mental"

  def self.boolean_step(id, prompt, next_id, weight)
    { "id" => id, "prompt" => prompt, "answer_type" => "boolean",
      "branches" => { "true" => next_id, "false" => next_id }, "weights" => { "true" => weight, "false" => 0 } }
  end

  SCORING = { "type" => "weighted", "thresholds" => { "baixa" => 0, "media" => 3, "alta" => 6 },
              "priority_map" => { "baixa" => 9, "media" => 5, "alta" => 3 } }.freeze
  RECOMMENDATIONS = {
    "alta" => { "title" => "Procure sua unidade de saúde", "body" => "Agende uma consulta na sua UBS nos próximos dias." },
    "media" => { "title" => "Converse com a equipe", "body" => "Na próxima ida à UBS, conte o que respondeu aqui." },
    "baixa" => { "title" => "Continue se cuidando", "body" => "Mantenha as consultas de rotina em dia." }
  }.freeze

  PROTOCOLS = {
    DEEP => {
      "name" => DEEP, "version" => 1, "start_step_id" => "desesperanca",
      "steps" => [ boolean_step("desesperanca", "Nas últimas duas semanas, sentiu-se sem esperança na maior parte dos dias?", "isolamento", 3),
                   boolean_step("isolamento", "Tem evitado ver amigos e família?", "rotina", 2),
                   boolean_step("rotina", "Tem deixado de fazer tarefas do dia a dia?", nil, 2) ],
      "scoring" => SCORING, "recommendations" => RECOMMENDATIONS,
      "offer" => { "title" => "Saúde mental — aprofundamento",
                   "summary" => "Perguntas a mais para a equipe entender melhor como você está.",
                   "eligibility" => { "gte" => ["profile.age", 18] } }
    },
    ELDERLY => {
      "name" => ELDERLY, "version" => 1, "start_step_id" => "quedas",
      "steps" => [ boolean_step("quedas", "Caiu alguma vez nos últimos 12 meses?", "memoria", 3),
                   boolean_step("memoria", "Tem esquecido compromissos ou recados com frequência?", "remedios", 2),
                   boolean_step("remedios", "Usa cinco ou mais remédios todos os dias?", nil, 2) ],
      "scoring" => SCORING, "recommendations" => RECOMMENDATIONS,
      "offer" => { "title" => "Saúde do idoso", "summary" => "Avaliação anual de quedas, memória e medicamentos.",
                   "eligibility" => { "gte" => ["profile.age", 60] }, "retake_after_days" => 365 }
    },
    MENTAL => {
      "name" => MENTAL, "version" => 1, "start_step_id" => "humor",
      "steps" => [ boolean_step("humor", "Nas últimas duas semanas, sentiu-se para baixo ou deprimido?", "interesse", 3),
                   boolean_step("interesse", "Perdeu o interesse por coisas de que gostava?", "sono", 3),
                   boolean_step("sono", "Tem dormido mal quase todas as noites?", nil, 2) ],
      "scoring" => SCORING, "recommendations" => RECOMMENDATIONS,
      "offer" => { "title" => "Saúde mental", "summary" => "Três perguntas sobre humor, interesse e sono.",
                   "eligibility" => { "gte" => ["profile.age", 18] }, "retake_after_days" => 30 },
      "suggestions" => [ { "protocol" => DEEP, "when" => { "gte" => ["outcome.score", 6] } } ]
    }
  }.freeze

  # Protocolos anteriores ao módulo 15, sem bloco `offer`: sem título, o cidadão
  # vê o nome técnico. Sem elegibilidade, seguem "para todos".
  LEGACY_TITLES = {
    "triage-respiratoria" => { "title" => "Sintomas respiratórios", "summary" => "Perguntas sobre tosse e febre." },
    "triagem-arbovirose" => { "title" => "Dengue, zika e chikungunya",
                              "summary" => "Febre, manchas na pele e dores no corpo." },
    "triagem-dengue" => { "title" => "Dengue", "summary" => "Perguntas sobre febre e outros sintomas." }
  }.freeze

  # Ordem no catálogo da cidade.
  POSITIONS = { ELDERLY => 1, MENTAL => 2, DEEP => 3 }.freeze

  FAMILY = [ { key: "avo", age: 62, extra_days: 40, sex: "female" }, { key: "neto", age: 8, extra_days: 100, sex: "male" } ].freeze

  class << self
    def seed_current_city(slug:, ddd:)
      PROTOCOLS.each_key { |name| ensure_protocol!(slug, name) }
      titled = LEGACY_TITLES.keys.select { |name| title_legacy!(slug, name) }
      restricted = slug == "curitiba" ? elderly_neighborhoods : []
      enable_catalog!(slug, restricted)
      family = ensure_family!(slug, ddd, restricted.first)
      { protocols: PROTOCOLS.keys, titled: titled, restricted_neighborhoods: restricted.map(&:name), family: family }
    end

    private

    def ensure_protocol!(slug, name)
      active = ProtocolDefinition.find_by(name: name, status: "active")
      return active if active

      run_cycle!(slug, name, 1, PROTOCOLS.fetch(name))
    end

    # Versão nova = a ativa + o título; a versão sai da que já leva o título
    # (retomada) ou da próxima livre, sem tocar nos rascunhos da demo.
    def title_legacy!(slug, name)
      offer = LEGACY_TITLES.fetch(name)
      active = ProtocolDefinition.find_by(name: name, status: "active")
      return false if active.nil? || active.definition["offer"].present?

      versions = ProtocolDefinition.where(name: name)
      pending = versions.where.not(status: %w[active retired]).find { |v| v.definition["offer"] == offer }
      version = pending&.version || (versions.maximum(:version) + 1)
      run_cycle!(slug, name, version, active.definition.merge("version" => version, "offer" => offer))
      true
    end

    # Retoma de onde parou: cada passo só roda se a versão estiver no estado dele.
    def run_cycle!(slug, name, version, definition)
      record = ProtocolDefinition.find_by(name: name, version: version)
      return record if record&.status == "active"

      author, first, second, publisher = %w[autor revisora1 revisora2 publisher]
                                         .map { |prefix| User.find_by!(email_address: "#{prefix}@#{slug}.demo") }
      status = -> { ProtocolDefinition.find_by!(name: name, version: version).status }
      check!(Protocols::SaveDraft.call(definition: definition.deep_dup, by: author), name, "rascunho") if record.nil?
      check!(Protocols::SubmitForReview.call(name: name, version: version, by: author), name, "revisão") if status.call == "draft"
      if status.call == "in_review"
        [ first, second ].each { |reviewer| sign!(reviewer, name, version, "publication") }
        check!(Protocols::Publish.call(name: name, version: version, by: publisher), name, "publicação")
      end
      if status.call == "published"
        [ first, second ].each { |reviewer| sign!(reviewer, name, version, "activation") }
        check!(Protocols::Activate.call(name: name, version: version, by: publisher), name, "ativação")
      end
      ProtocolDefinition.find_by!(name: name, version: version)
    end

    def sign!(reviewer, name, version, purpose)
      result = Protocols::Sign.call(name: name, version: version, purpose: purpose, by: reviewer)
      check!(result, name, "assinatura de #{purpose}") unless result.reason == :already_signed
    end

    def check!(result, name, step)
      return result if result.ok?

      raise "semente do catálogo: #{step} de #{name} falhou — #{result.reason}: #{result.message}"
    end

    # Curitiba: o idoso só nos dois primeiros bairros ativos (por nome).
    def elderly_neighborhoods
      neighborhoods = Neighborhood.where(active: true).order(:name).first(2)
      raise "semente do catálogo: nenhum bairro (rode a Territory::Seed antes)" if neighborhoods.empty?

      neighborhoods
    end

    # Uma linha habilitada por protocolo; o idoso restrito aos bairros quando há.
    def enable_catalog!(slug, restricted)
      admin = User.find_by!(email_address: "admin@#{slug}.demo")
      POSITIONS.each do |name, position|
        restriction = name == ELDERLY && restricted.any? ? { "in" => [ "citizen.neighborhood_id", restricted.map(&:id) ] } : nil
        attributes = { "enabled" => true, "position" => position, "available_from" => nil, "available_until" => nil,
                       "restriction" => restriction }
        check!(Triages::SetOffer.call(protocol_name: name, attributes: attributes, by: admin), name, "linha do catálogo")
      end
    end

    def ensure_family!(slug, ddd, neighborhood)
      phone = format("+55%s#{PHONE_PREFIX}0001", ddd)
      FAMILY.map do |member|
        born = Time.zone.today - member[:age].years - member[:extra_days].days
        result = Citizens::RegisterPerson.call(
          phone: phone, cpf: CampaignHistory.cpf_for("#{slug}:catalogo:#{member[:key]}"),
          profile: { birth_date: born.iso8601, sex: member[:sex], gender_identity: nil }
        )
        citizen = check!(result, "família", member[:key]).payload[:citizen]
        if neighborhood && citizen.neighborhood_id.nil?
          Citizens::SetNeighborhood.call(citizen: citizen, neighborhood_id: neighborhood.id)
        end
        { cpf_masked: citizen.cpf_masked, age: citizen.age, sex: citizen.sex }
      end
    end
  end
end

# Relatórios do centro de zoonoses (módulo 35b, ADR 0054; contrato §8, Q5,
# Q19, Q25). A mesma forma do VectorControl::Reports, e o CSV é o dele
# (VectorControl::Csv.build): { name, columns: [{ key, label, kind }], rows,
# notes? }, `kind` ∈ text count percent. Percentual é texto com uma casa; nil
# sem denominador.
#
# Filtros (`filters` = a query, chaves em texto; quem chama já recusou chave
# fora de FILTERS): inválido → Result.fail(:invalid_request, details: { path: }).
# Todos pedem `from` e `to` (dias da cidade, os dois inclusive, até MAX_DAYS):
# ausente, malformado, invertido ou longo demais → path `from` (quando o
# defeito é só do `to`, path `to`). `campaign_id` (rabies_weekly,
# rabies_modalities) e `survey_id` (leish) são opcionais; id que não existe é
# filtro inválido.
#   - rabies_weekly: as linhas do WeeklyResult (Task 7) da campanha (a pedida;
#     senão a aberta; senão a mais recente), das semanas que tocam o período,
#     com as duas coberturas (Q19). A semana depois do fim previsto da campanha
#     (ela seguiu aberta) é MARCADA: `after_planned_end: true` na linha, a
#     coluna "Observação" no CSV e uma nota. Sem supressão (Q5);
#   - rabies_modalities: doses não anuladas do período por modalidade × espécie;
#     sem supressão;
#   - demands: demandas criadas no período por subtipo × estado × cor do prazo;
#     cada célula passa por Admin::SmallCount.wrap (1–4 suprimido), sem linha de
#     total (o total menos as linhas revelaria a célula suprimida);
#   - observations: observações com exposição no período por desfecho (aberta =
#     "Em observação") × espécie; mesma supressão, sem total;
#   - leish: por inquérito que toca o período, a prevalência do
#     Zoonoses::Prevalence (por cão); coleiras colocadas = as dos cães dos
#     domicílios dos quarteirões do inquérito (SurveyArea.household_ids, com ou
#     sem exame), colocadas de starts_on a ends_on (até hoje se ele está
#     aberto); a trocar = as ativas dos cães `active` deles com due_on até hoje +
#     COLLAR_DUE_WINDOW;
#   - shelter: lotação atual (estadas abertas hoje), entradas e saídas por
#     tipo, castrações e eutanásias por motivo, no período.
# Agregado no banco; só o `demands` carrega as linhas do período para calcular
# a cor do prazo (Ombudsman::Deadlines). Só contagens: nenhum tutor, nome, CPF, CNS, telefone,
# endereço nem microchip. Sem trilha.
module Zoonoses
  module Reports
    FILTERS = {
      "rabies_weekly" => %w[from to campaign_id],
      "rabies_modalities" => %w[from to campaign_id],
      "demands" => %w[from to],
      "observations" => %w[from to],
      "leish" => %w[from to survey_id],
      "shelter" => %w[from to]
    }.freeze
    MAX_DAYS = 366
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    DOMAINS = YAML.load_file(Rails.root.join("config/zoonoses/domains.yml")).freeze
    AFTER_END_NOTE = "após o fim previsto da campanha".freeze
    COLORS = %w[green yellow red none].freeze
    OBSERVATION_OUTCOMES = (%w[open] + Catalog::OBSERVATION_OUTCOMES).freeze

    class Invalid < StandardError
      attr_reader :path

      def initialize(path)
        @path = path
        super("invalid filter")
      end
    end

    module_function

    # -> Result.ok(report:) | Result.fail(:invalid_request, details: { path: })
    def build(name, filters:)
      raise ArgumentError, "report #{name}" unless Catalog::REPORTS.include?(name)

      Result.ok(report: public_send(name, filters.to_h.stringify_keys))
    rescue Invalid => e
      Result.fail(:invalid_request, details: { path: e.path })
    end

    def rabies_weekly(filters)
      range = period!(filters)
      campaign = campaign!(filters)
      rows = []
      notes = []
      if campaign
        first = Surveillance::EpiWeek.for(range.begin).to_s
        last = Surveillance::EpiWeek.for(range.end).to_s
        planned_last = Surveillance::EpiWeek.for(campaign.ends_on).to_s
        rows = WeeklyResult.for(campaign: campaign, today: Time.zone.today).select { |row| row[:epi_week].between?(first, last) }.map do |row|
          late = row[:epi_week] > planned_last
          { "epi_week" => row[:epi_week], "dogs" => row[:dogs], "cats" => row[:cats], "dogs_total" => row[:dogs_total],
            "cats_total" => row[:cats_total], "goal_dogs" => row[:goal_dogs], "goal_cats" => row[:goal_cats],
            "dog_coverage" => one(row[:dog_coverage]), "cat_coverage" => one(row[:cat_coverage]),
            "dog_coverage_estimate" => one(row[:dog_coverage_estimate]), "cat_coverage_estimate" => one(row[:cat_coverage_estimate]),
            "after_planned_end" => late, "remark" => (AFTER_END_NOTE if late) }
        end
        notes << "Campanha: #{campaign.name} (#{campaign.starts_on.iso8601} a #{campaign.ends_on.iso8601})."
        notes << "Semanas #{AFTER_END_NOTE}: a campanha seguiu aberta depois de #{campaign.ends_on.iso8601}." if rows.any? { _1["after_planned_end"] }
      else
        notes << "Nenhuma campanha."
      end
      notes << "Cobertura sobre a estimativa só quando há estimativa de população nos parâmetros."
      report("rabies_weekly",
             [ column("epi_week", "Semana epidemiológica", "text"), column("dogs", "Cães na semana", "count"),
               column("cats", "Gatos na semana", "count"), column("dogs_total", "Cães acumulado", "count"),
               column("cats_total", "Gatos acumulado", "count"), column("goal_dogs", "Meta de cães", "count"),
               column("goal_cats", "Meta de gatos", "count"), column("dog_coverage", "Cobertura de cães sobre a meta %", "percent"),
               column("cat_coverage", "Cobertura de gatos sobre a meta %", "percent"),
               column("dog_coverage_estimate", "Cobertura de cães sobre a estimativa %", "percent"),
               column("cat_coverage_estimate", "Cobertura de gatos sobre a estimativa %", "percent"),
               column("remark", "Observação", "text") ],
             rows, notes: notes)
    end

    def rabies_modalities(filters)
      range = period!(filters)
      campaign = campaign!(filters, default: false)
      scope = RabiesVaccination.active.where(vaccinated_on: range)
      scope = scope.where(campaign_id: campaign.id) if campaign
      counts = scope.group(:modality, :species).count
      rows = Catalog::MODALITIES.product(Catalog::VACCINE_SPECIES).map do |modality, species|
        { "modality" => label("modalities", modality), "species" => label("species", species), "doses" => counts.fetch([ modality, species ], 0) }
      end
      report("rabies_modalities",
             [ column("modality", "Modalidade", "text"), column("species", "Espécie", "text"), column("doses", "Doses", "count") ],
             rows, notes: [ "Doses anuladas não contam." ])
    end

    def demands(filters)
      range = period!(filters)
      settings = OmbudsmanSetting.current
      today = Time.zone.today
      counts = Hash.new(0)
      ZoonosesDemand.where(created_at: time_range(range)).preload(:ombudsman_forwarding).find_each do |demand|
        color = Ombudsman::Deadlines.forwarding_color(demand.ombudsman_forwarding, settings, today: today) || "none"
        counts[[ demand.subtype, demand.state, color ]] += 1
      end
      rows = Catalog::SUBTYPES.product(Catalog::DEMAND_STATES, COLORS).filter_map do |subtype, state, color|
        count = counts[[ subtype, state, color ]]
        next if count.zero?

        { "subtype" => label("subtypes", subtype), "state" => label("demand_states", state), "color" => label("deadline_colors", color),
          "count" => Admin::SmallCount.wrap(count) }
      end
      report("demands",
             [ column("subtype", "Subtipo", "text"), column("state", "Estado", "text"), column("color", "Prazo", "text"),
               column("count", "Demandas", "count") ],
             rows, notes: [ "Contagens de 1 a 4 saem suprimidas.", "Sem linha de total." ])
    end

    def observations(filters)
      range = period!(filters)
      counts = BiteObservation.where(exposure_on: range).group(:outcome, :species).count
      rows = OBSERVATION_OUTCOMES.product(Catalog::VACCINE_SPECIES).filter_map do |outcome, species|
        count = counts.fetch([ (outcome unless outcome == "open"), species ], 0)
        next if count.zero?

        { "outcome" => label("observation_outcomes", outcome), "species" => label("species", species),
          "count" => Admin::SmallCount.wrap(count) }
      end
      report("observations",
             [ column("outcome", "Desfecho", "text"), column("species", "Espécie", "text"), column("count", "Observações", "count") ],
             rows, notes: [ "Contagens de 1 a 4 saem suprimidas.", "Sem linha de total.", "Período: data da exposição." ])
    end

    def leish(filters)
      range = period!(filters)
      surveys = survey!(filters)
      surveys = LeishSurvey.where("starts_on <= ? AND ends_on >= ?", range.end, range.begin).order(:starts_on, :id).to_a if surveys.nil?
      today = Time.zone.today
      due_limit = today + Catalog::COLLAR_DUE_WINDOW
      rows = surveys.map do |survey|
        stats = Prevalence.for(survey)
        animals = Animal.where(species: "dog", household_id: SurveyArea.household_ids(survey.city_block_ids)).select(:id)
        last_day = survey.stage == "open" ? [ survey.ends_on, today ].min : survey.ends_on
        placed = Collar.where(animal_id: animals, placed_on: survey.starts_on..last_day).count
        due = Collar.active.where(animal_id: animals.merge(Animal.active), due_on: ..due_limit).count
        { "survey" => survey.name, "kind" => label("leish_survey_kinds", survey.kind), "examined" => stats[:examined],
          "reactive" => stats[:reactive], "prevalence" => one(stats[:prevalence]), "collars_placed" => placed, "collars_due" => due }
      end
      report("leish",
             [ column("survey", "Inquérito", "text"), column("kind", "Tipo", "text"), column("examined", "Examinados", "count"),
               column("reactive", "Reagentes", "count"), column("prevalence", "Prevalência %", "percent"),
               column("collars_placed", "Coleiras colocadas", "count"), column("collars_due", "Coleiras a trocar", "count") ],
             rows,
             notes: [ "Prevalência por cão: o último resultado final de cada cão no inquérito.",
                      "Coleiras: dos cães dos domicílios dos quarteirões do inquérito (examinados ou não); a trocar = ativas dos cães ativos com vencimento em até #{Catalog::COLLAR_DUE_WINDOW} dias." ])
    end

    def shelter(filters)
      range = period!(filters)
      entries = ShelterStay.where(entered_on: range).group(:entry_kind).count
      exits = ShelterStay.where(exited_on: range).group(:exit_kind).count
      reasons = Euthanasia.where(performed_on: range).group(:reason).count
      rows = [ { "section" => "Lotação atual", "kind" => "Estadas abertas hoje", "count" => ShelterStay.open_stays.count } ]
      rows += Catalog::ENTRY_KINDS.map { |kind| { "section" => "Entradas", "kind" => label("entry_kinds", kind), "count" => entries.fetch(kind, 0) } }
      rows += Catalog::EXIT_KINDS.map { |kind| { "section" => "Saídas", "kind" => label("exit_kinds", kind), "count" => exits.fetch(kind, 0) } }
      rows << { "section" => "Castrações", "kind" => "Castrações no período", "count" => Neutering.where(performed_on: range).count }
      rows += Catalog::EUTHANASIA_REASONS.map do |reason|
        { "section" => "Eutanásias", "kind" => label("euthanasia_reasons", reason), "count" => reasons.fetch(reason, 0) }
      end
      report("shelter",
             [ column("section", "Grupo", "text"), column("kind", "Tipo", "text"), column("count", "Quantidade", "count") ],
             rows, notes: [ "A lotação é a de hoje; o resto é do período." ])
    end

    # --- formas ---

    def report(name, columns, rows, notes: nil)
      shaped = { name: name, columns: columns, rows: rows }
      shaped[:notes] = notes if notes.present?
      shaped
    end

    def column(key, label, kind) = { key: key, label: label, kind: kind }

    def one(value) = value.nil? ? nil : format("%.1f", value)

    def label(domain, code) = DOMAINS.fetch(domain).find { |entry| entry["code"] == code }.fetch("label")

    # --- filtros ---

    # from..to como Range de datas (os dois inclusive).
    def period!(filters)
      from = date!(filters, "from")
      to = date!(filters, "to")
      raise Invalid, "from" if to < from || (to - from).to_i >= MAX_DAYS

      from..to
    end

    def date!(filters, key)
      raw = filters[key]
      raise Invalid, key unless raw.is_a?(String) && raw.match?(DATE)

      Date.strptime(raw, "%Y-%m-%d")
    rescue Date::Error
      raise Invalid, key
    end

    def time_range(range) = range.begin.beginning_of_day...(range.end + 1).beginning_of_day

    # A campanha pedida; sem `campaign_id`: a aberta e, com `default`, a mais recente.
    def campaign!(filters, default: true)
      return record!(RabiesCampaign, filters, "campaign_id") if filters.key?("campaign_id")
      return nil unless default

      RabiesCampaign.find_by(stage: "open") || RabiesCampaign.order(starts_on: :desc, id: :desc).first
    end

    # -> [LeishSurvey] do pedido, ou nil sem `survey_id`.
    def survey!(filters)
      filters.key?("survey_id") ? [ record!(LeishSurvey, filters, "survey_id") ] : nil
    end

    def record!(model, filters, key)
      raw = filters[key]
      raise Invalid, key unless raw.is_a?(String) && raw.match?(UUID)

      model.find_by(id: raw) || raise(Invalid, key)
    end

    private_class_method :report, :column, :one, :label, :period!, :date!, :time_range, :campaign!, :survey!, :record!
  end
end

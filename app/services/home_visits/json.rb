# Formas JSON da visita domiciliar (módulo 24b, ADR 0052; contrato §6, §7). Só
# o que a rota mostra: profissional por id, nome e CBO; nunca CNS.
module HomeVisits
  module Json
    DICTIONARIES = YAML.load_file(Rails.root.join("config/ledi/visit_activity_dictionaries.yml")).fetch("home_visit").freeze

    module_function

    def professional(professional, cbo) = { id: professional.id, name: professional.professional_name, cbo: cbo }

    def micro_area(area) = { id: area.id, code: area.code, name: area.name }

    # <assignment> do GET /home_visits/assignments (§6). cbo: o do vínculo
    # ativo do profissional na equipe (nil se o vínculo acabou).
    def assignment(assignment, cbo:)
      json = { id: assignment.id, micro_area: micro_area(assignment.micro_area), professional: professional(assignment.professional, cbo),
               assigned_at: assignment.created_at.iso8601, assigned_by: { name: assignment.assigned_by_user.professional&.professional_name } }
      json[:ended_at] = assignment.ended_at.iso8601 if assignment.ended_at
      json
    end

    def candidate(member)
      { professional_id: member.professional.id, name: member.professional.professional_name, cbo: member.cbo_code }
    end

    # <home_visit_day> do §6, sem `visits` (quem lista acrescenta). Sem pessoa:
    # nunca grava trilha. visits_count = visitas não retiradas; own = a folha é
    # de `viewer` (Q14); blockers só com a folha aberta (HomeVisits::Blockers);
    # ledi_export_enabled = a exportação LEDI da cidade está ligada (Q50; os
    # blockers continuam listados, e o fechamento sai not_exported).
    def day(day, viewer: nil) = days([ day ], viewer: viewer).first

    # A mesma forma para uma lista, com um número fixo de consultas (nenhuma
    # por folha): contagens agrupadas, "não geradas" e outbox das fechadas
    # numa consulta cada, e as visitas válidas das abertas carregadas juntas
    # para os blockers.
    def days(days, viewer: nil)
      return [] if days.empty?

      ActiveRecord::Associations::Preloader.new(records: days, associations: [ :professional, { team: :health_unit } ]).call
      export = Ledi::HomeVisitDayFicha.export_enabled?(Current.city)
      counts = HomeVisit.where(home_visit_day_id: days.map(&:id)).group(:home_visit_day_id, Arel.sql("withdrawn_at IS NULL")).count
      fichas = fichas(days.reject(&:open?), counts)
      blockers = open_blockers(days.select(&:open?))
      days.map do |day|
        {
          id: day.id, professional: { id: day.professional.id, name: day.professional.professional_name },
          team: { id: day.team.id, ine: day.team.ine, name: day.team.name }, day: day.day.iso8601, sequence: day.sequence,
          state: day.state, closed_at: day.closed_at&.iso8601, closed_by: day.closed_by,
          visits_count: counts.fetch([ day.id, true ], 0), withdrawn_count: counts.fetch([ day.id, false ], 0),
          own: !viewer.nil? && day.user_id == viewer.id, ficha: fichas.fetch(day.id) { { status: "open", reasons: [] } },
          blockers: blockers.fetch(day.id, []), ledi_export_enabled: export
        }
      end
    end

    # Situação da ficha das folhas fechadas (§6; Desvio 3, Q5): o motivo da
    # "não gerada" ainda não resolvida (not_generated, com os códigos) | o
    # status do ledi_outbox mais recente da fonte (a regerada pelo "Reenviar"
    # substitui a recusada) | empty (sem visita válida) | not_exported (com
    # visita válida, sem ficha e sem falha: a exportação não estava utilizável).
    # A aberta é `open` (quem chama). -> { day_id => { status:, reasons: } }
    def fichas(closed, counts)
      return {} if closed.empty?

      source = { source_type: Ledi::HomeVisitDayFicha::SOURCE_TYPE, source_id: closed.map(&:id) }
      failures = LediGenerationFailure.unresolved.where(source).index_by(&:source_id)
      statuses = LediOutboxEntry.where(source).order(created_at: :desc, id: :desc).pluck(:source_id, :status)
                                .each_with_object({}) { |(id, status), latest| latest[id] ||= status }
      closed.to_h do |day|
        ficha = if (failure = failures[day.id]) then { status: "not_generated", reasons: failure.reason_codes }
                elsif (status = statuses[day.id]) then { status: status, reasons: [] }
                else { status: counts.fetch([ day.id, true ], 0).positive? ? "not_exported" : "empty", reasons: [] }
                end
        [ day.id, ficha ]
      end
    end

    # { day_id => blockers } das abertas: as visitas válidas de todas numa
    # consulta (com paciente e microárea), o perfil da cidade uma vez.
    def open_blockers(open)
      return {} if open.empty?

      visits = HomeVisit.valid.where(home_visit_day_id: open.map(&:id)).includes(:patient, :micro_area).order(:occurred_at, :id)
                        .group_by(&:home_visit_day_id)
      incomplete = Ledi::HomeVisitDayFicha.profile_incomplete?
      open.to_h { |day| [ day.id, Blockers.for(day, visits: visits.fetch(day.id, []), profile_incomplete: incomplete) ] }
    end

    # <home_visit> do §6 (nominal: quem mostra grava a trilha). `note` só no
    # GET /home_visits/:id (note: true); withdrawn.reason só para o dono da
    # folha e o enfermeiro/médico da equipe, nulo para os outros (Q17);
    # can_withdraw = dono, não retirada e folha aberta (Q14). Visitas com
    # home_visit_day (e equipe), micro_area, patient, recorded_by_user e
    # withdrawn_by_user (com :professional) carregados por quem chama.
    def visits(visits, viewer:, note: false)
      addresses = addresses(visits.map(&:household_id))
      readers = visits.map { |visit| visit.home_visit_day.team }.uniq(&:id).to_h { |team| [ team.id, Access.reads_team?(viewer, team) ] }
      visits.map do |visit|
        owner = visit.home_visit_day.user_id == viewer.id
        visit(visit, address: addresses[visit.household_id], owner: owner,
                     reason_visible: owner || readers[visit.home_visit_day.team_id], note: note)
      end
    end

    def visit(visit, address:, owner:, reason_visible:, note:)
      area = visit.micro_area
      patient = visit.patient
      json = {
        id: visit.id, client_uuid: visit.client_uuid, day_id: visit.home_visit_day_id, occurred_at: visit.occurred_at.iso8601,
        shift: visit.shift, origin: visit.origin, property_type: visit.property_type, micro_area: area && { id: area.id, code: area.code },
        out_of_area: visit.out_of_area, household: visit.household_id && { id: visit.household_id, address_short: address },
        family_id: visit.family_id, subject: visit.subject,
        patient: patient && { id: patient.id, display_name: patient.display_name }.merge(Patients::IdentifierJson.call(patient)),
        outcome: visit.outcome, reasons: Array(visit.reasons).map(&:to_i), shared: visit.shared, measurements: visit.measurements.presence,
        state: visit.withdrawn? ? "withdrawn" : "recorded", withdrawn: withdrawn(visit, reason_visible),
        recorded_by: { name: visit.recorded_by_user.professional&.professional_name },
        can_withdraw: owner && visit.recorded? && visit.home_visit_day.open?
      }
      json[:note] = visit.note if note
      json
    end

    def withdrawn(visit, reason_visible)
      return nil unless visit.withdrawn?

      { at: visit.withdrawn_at.iso8601, reason: (visit.withdrawal_reason if reason_visible),
        by: { name: visit.withdrawn_by_user.professional&.professional_name } }
    end

    # { household_id => "Rua das Flores, 120" } pela versão atual de cada
    # domicílio (tipo DNE + logradouro, número ou S/N), numa consulta.
    def addresses(household_ids)
      ids = household_ids.compact.uniq
      return {} if ids.empty?

      HouseholdVersion.joins(:household).where(household_id: ids).where("household_versions.version = households.version")
                      .to_h { |version| [ version.household_id, address_short(version.address) ] }
    end

    # Sem endereço (domicílio com recusa) → "Sem endereço" (o contrato pede texto).
    def address_short(values)
      values = values.to_h.stringify_keys
      street = [ STREET_TYPES[values["street_type"]]&.capitalize, values["street"] ].compact.join(" ").presence
      number = values["no_number"] ? "S/N" : values["number"]
      [ street, (number if street) ].compact.join(", ").presence || "Sem endereço"
    end

    # `context.domains` (§7, Q13): a forma `home_visit`, lida do YAML da task 1
    # (o mesmo que preenche o domains-v1.json do app). Códigos LEDI inteiros;
    # tipo de imóvel em texto, como o 24a grava (Q26).
    def domains = DOMAINS

    def build_domains
      domains = DICTIONARIES.fetch("domains")
      rules = DICTIONARIES.fetch("rules")
      groups = domains.fetch("motivo_visita_groups")
      {
        motivo_visita: domains.fetch("motivo_visita").map do |code, row|
          { code: code, label: row.fetch("label"), group: row.fetch("group"), group_label: groups.fetch(row.fetch("group")).fetch("group_label") }
        end,
        desfecho: labels(domains.fetch("desfecho")),
        turno: labels(domains.fetch("turno")),
        tipo_glicemia: labels(domains.fetch("tipo_glicemia")),
        tipo_de_imovel: TerritoryRegistry::Dictionary.domain("tipo_de_imovel").map { |code, label| { code: code.to_s, label: label } },
        non_residential_property_types: rules.fetch("non_residential_property_types"),
        non_residential_reasons: rules.fetch("non_residential_reasons"),
        male_forbidden_reasons: rules.fetch("male_forbidden_reasons"),
        without_person_allowed_reasons: rules.fetch("without_person_allowed_reasons"),
        responsible_document_reasons: rules.fetch("responsible_document_reasons"),
        reasons_max: rules.fetch("reasons_max"),
        measurement_ranges: DICTIONARIES.fetch("measurements").select { |_, row| row.key?("min") }.to_h do |key, row|
          [ key.to_sym, { min: row.fetch("min"), max: row.fetch("max"), decimals: row.fetch("decimals") } ]
        end
      }.freeze
    end

    def labels(rows) = rows.map { |code, label| { code: code, label: label } }

    STREET_TYPES = TerritoryRegistry::Dictionary.string_domain("tipo_logradouro")
    DOMAINS = build_domains
    private_class_method :build_domains, :labels, :fichas, :open_blockers, :visit, :withdrawn, :address_short
  end
end

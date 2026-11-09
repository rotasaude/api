# Atendimentos de urgência da UPA (ADR 0050; contrato §10 e §14 Q13, Q25): um
# por encontro do paciente da pessoa (attendances.patient_id: depois da
# identificação, o do real), na chegada (attendances.checked_in_at). Vazio sem
# paciente. A entrada representa a visita inteira: o atendimento walk_in
# (AttendanceSource) e a consulta de urgência (ConsultationSource) não saem.
#
# Profissional, em qualquer estado: título "Atendimento de urgência — <UPA>";
# resumo com a cor vigente, o 1º CID-10 avaliado na consulta finalizada, o
# desfecho e a orientação de retorno com o motivo; situação = estado do
# encontro; profissional = autor da consulta (ou nulo).
#
# Cidadão (`citizen: true`): só encontros FECHADOS de paciente identificado,
# com desfecho da tabela W3 (Labels::CITIZEN_URGENCY_OUTCOMES) — o óbito e o
# registro por engano nunca aparecem. Título igual, resumo = o desfecho em
# texto simples, `return_guidance` = "Procure a sua UBS em até N dias" (sem o
# motivo); profissional, situação e documento nulos. Nunca CID, cor, queixa,
# critério, sinais, destino nem motivo. A trilha é do controlador.
module Timeline
  module Sources
    module UrgencySource
      KIND = "urgency".freeze

      module_function

      def entries(person:, before:, limit:, from:, to:, citizen: false)
        return [] unless person.patient_id

        scope = ::UrgencyEncounter.joins(:attendance).where(attendances: { patient_id: person.patient_id })
                                  .preload(:outcome, :current_classification, attendance: :health_unit,
                                                                              consultation: [ :problem_items, { author_user: :professional } ])
        scope = citizen_scope(scope) if citizen
        # preload (não includes): o where em attendances levaria ao eager_load com limite e ORDER BY cru.
        rows = Window.apply(scope, kind: KIND, column: "attendances.checked_in_at", id_column: "urgency_encounters.id",
                                   before: before, from: from, to: to).limit(limit).to_a
        labels = {} # memo da chamada: um rótulo por (release, código)
        rows.map { |encounter| entry(encounter, labels) }
      end

      def citizen_scope(scope)
        scope.where(state: "closed").joins(:outcome).where(urgency_outcomes: { kind: Labels::CITIZEN_URGENCY_OUTCOMES.keys })
             .joins(attendance: :patient).where(patients: { unidentified: false })
      end

      def entry(encounter, labels)
        unit = encounter.attendance.health_unit
        outcome = encounter.outcome
        consultation = encounter.consultation&.then { |c| c.status == "finalized" ? c : nil }
        title = "Atendimento de urgência — #{Labels.unit_name(unit)}"
        guidance = outcome&.return_days
        summary = [ Labels::URGENCY_COLORS[encounter.color], cid(consultation, labels), outcome && Labels::URGENCY_OUTCOMES[outcome.kind],
                    guidance && "Retorno à UBS em até #{Labels.days(guidance)}: #{outcome.return_reason}" ].compact.join(" · ")
        citizen = { title: title, summary: outcome && Labels::CITIZEN_URGENCY_OUTCOMES[outcome.kind], status: nil, professional_name: nil }
        citizen[:return_guidance] = "Procure a sua UBS em até #{Labels.days(guidance)}" if guidance
        Entry.new(kind: KIND, source_id: encounter.id, occurred_at: encounter.attendance.checked_in_at, unit: Labels.unit(unit),
                  professional: consultation && { name: Screenings::Json.staff_name(consultation.author_user), cbo_code: consultation.cbo_code },
                  title: title, summary: summary.presence, status: encounter.state,
                  detail_ref: { type: "urgency_encounter", id: encounter.id }, citizen: citizen, document: nil)
      end

      # O 1º CID-10 avaliado na consulta (sem os de adendo), "CÓDIGO nome" pela release gravada.
      def cid(consultation, labels)
        return nil unless consultation

        item = consultation.problem_items.select { |p| p.addendum_id.nil? && p.terminology == "cid10" }.min_by { |p| [ p.created_at, p.id ] }
        return nil unless item

        key = [ item.terminology_release_id, item.code ]
        label = labels.fetch(key) { labels[key] = ClinicalTerms.label("cid10", item.code, item.terminology_release_id) }
        "#{item.code} #{label}".strip
      end
      private_class_method :citizen_scope, :entry, :cid
    end
  end
end
